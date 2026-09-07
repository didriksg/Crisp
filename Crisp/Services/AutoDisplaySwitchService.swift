import Foundation
import CoreGraphics
import AppKit
import os

/// Auto dock switching: keeps the built-in panel's connected state a function of whether an
/// external display is attached, and rescues the machine when every screen ends up dark.
///
/// Two independent parts, on purpose:
///
/// 1. **The rule** (opt-in, `SettingsService.autoBuiltinFollowsExternal`): an external is
///    online -> disconnect the built-in, so a docked laptop drives the monitor alone; the last
///    external goes away -> reconnect the built-in. Doing it by hand through the menu is the
///    same two calls, so this only removes the two clicks per dock/undock. Reconnecting the
///    panel by hand hands it back to the user until the next dock (see `userOwnsBuiltin`):
///    the rule automates the dock, it does not police the panel.
///
/// 2. **The rescue** (always on): re-enables window-server-disabled displays when nothing
///    viewable is left. `PhysicalDisplayToggleService.restoreIfNoActiveDisplay` already does
///    this, but only for displays still in the `disconnected` record set, which a multi-day
///    standby can outlive. This one works from remembered display IDs instead.
///
///    It is armed by an evaluation, never by a standing timer: the only thing it polls is a
///    desk that is already dark, where no further reconfiguration callback need arrive to say
///    whether it got better, and that watch is bounded at both ends. Sleep is excluded outright
///    — a sleeping Mac has no active displays by definition, and rescuing into that state
///    switched the built-in back on mid-sleep, so it was already lit at the next wake with
///    nothing left for the rule to disconnect (observed live).
///
/// Everything here is a no-op on Intel, where the underlying disconnect API does not perform a
/// true disconnect (see PhysicalDisplayToggleService.isSupported).
@MainActor
final class AutoDisplaySwitchService: ObservableObject {
    static let shared = AutoDisplaySwitchService()
    // Deliberately touches nothing: SettingsService's own loadAll() reaches this singleton
    // through its didSet, so an init that read SettingsService.shared back would deadlock on
    // its half-built instance. The setting is read inside evaluate(), which always runs later.
    private init() {}

    /// Every state change this service makes is logged: dock switching and the rescue act on
    /// their own, usually while nobody is watching, so the unified log is the only way to see
    /// afterwards what happened and why (the capture the project asks for in bug reports).
    private static let log = Logger(subsystem: "com.crisp.app", category: "autoswitch")

    private var toggle: PhysicalDisplayToggleService { .shared }

    // MARK: - Tuning

    /// Debounce after a display change. A dock plug produces a burst of reconfigurations and
    /// the arrangement keeps moving for a second or two; acting on the first event disconnects
    /// the built-in while the external is still training its link.
    private static let settleDelay: TimeInterval = 2.5
    /// How long the desk must stay dark, awake, before a rescue. Displays leave the active list
    /// during ordinary transitions (a mode switch, a dock renegotiating, a softReconnect blink),
    /// so a moment of "nothing viewable" is not yet a blackout.
    private static let blackoutConfirm: TimeInterval = 4
    /// Cadence and lifetime of the blackout watch. It only ever runs while the desk is dark, and
    /// gives up on its own: nothing here is a standing timer.
    private static let blackoutPoll: TimeInterval = 1
    private static let blackoutWatchLimit: TimeInterval = 30
    /// Displays come back over several seconds after a wake, in whatever order the hardware
    /// manages. Nothing is judged inside this window.
    private static let wakeGrace: TimeInterval = 6
    /// After a rescue the rule stands down this long, then re-evaluates by itself.
    private static let rescueCooloff: TimeInterval = 30
    /// A rescue this soon after the rule's own disconnect means the disconnect is what darkened
    /// the desk: the external enumerates but shows no picture (a half-dead dock link), which is
    /// indistinguishable from a working one on this side. A clock is the wrong guard for that,
    /// since it comes back to the same conclusion; the rule waits for the displays to change.
    private static let ruleCausedWindow: TimeInterval = 90

    // MARK: - State

    private var pending: Task<Void, Never>?
    private var blackoutWatch: Task<Void, Never>?
    /// Tells one watch from the next, so a watch that ends while a later one is already running
    /// clears only its own handle.
    private var blackoutWatchGeneration = 0
    private var running = false
    private var suppressRuleUntil: Date = .distantPast
    /// Set between a sleep notification and the next wake. Rescuing in this window is what put
    /// the built-in back on mid-sleep; see the type doc.
    private var displaysAsleep = false
    private var wakeGraceUntil: Date = .distantPast
    /// When the rule last took the built-in out of the layout, to tell a blackout it caused from
    /// one it merely walked into.
    private var lastRuleDisconnect: Date = .distantPast
    /// External topology the rule stands down for because disconnecting the built-in against it
    /// ended in a rescue. Cleared when the externals change, which is the only evidence that the
    /// situation is different.
    private var blockedExternalsSignature: String?
    /// The displays that were on the desk the last time it was demonstrably lit. What makes a
    /// display believable afterwards: see `hasTrustedDisplay`.
    private var lastHealthyDisplayIDs: Set<CGDirectDisplayID> = []
    /// Displays that turned up while the desk was dark and were never part of a lit desk. macOS
    /// re-probes when the last display leaves and can bring a long-detached monitor back by
    /// itself (observed live), and such a display is indistinguishable from a real one through
    /// CoreGraphics: EDID, a full mode list, an NSScreen with a name. The rule must not treat
    /// one as the external it is docking to, or it disconnects the built-in against a screen
    /// that does not exist. Dropped as soon as the display leaves the online list.
    private var suspectDisplayIDs: Set<CGDirectDisplayID> = []
    /// Set when the user reconnects the built-in panel themselves while docked: from then on
    /// their choice owns the panel and the rule stands down, so a deliberate "no, I want both
    /// screens" is not undone two seconds later. Cleared by an actual dock event — the externals
    /// going away and coming back — or by the user disconnecting the panel again.
    ///
    /// Deliberately not keyed on which externals are attached, which is what it used to be:
    /// plugging a second monitor into a desk you are already docked to is not a new decision to
    /// make, but keying on the set made it one, and connecting that monitor took away a panel
    /// the user had just asked for.
    private var userOwnsBuiltin = false
    /// Whether the last evaluation found an external attached. The override above is dropped on
    /// the transition out of that state, not while it holds: an undock is an event, and
    /// re-deciding the panel every time the display list is re-read is how a standing choice
    /// gets undone by something that never happened.
    private var wasDocked = false
    /// Set when the user disconnects an external through Crisp's own menu, and consumed by the
    /// next evaluation. That empties the external set exactly as unplugging the dock does, and
    /// the rule cannot tell the two apart from the display list alone — but Crisp was told, so
    /// it does not have to guess.
    private var userRemovedExternal = false

    /// Last-known IDs of real displays, and whether each was the built-in. The rescue's only
    /// usable input in a full blackout: verified live on macOS 26.6 that once the last real
    /// display leaves, SLSGetDisplayList shrinks to the placeholder alone, so at the exact
    /// moment the rescue is needed the window server can no longer name the display to switch
    /// back on. A stale ID still works (SLSConfigureDisplayEnabled honours it for attached
    /// hardware; detached hardware just fails the transaction and the loop moves on), so
    /// remember them while the lists are still honest. Persisted, so a relaunch into the dark
    /// has them too.
    private var knownDisplays: [CGDirectDisplayID: Bool] = [:]
    private static let knownDisplaysKey = "crisp.autoswitch.knownDisplays"

    var isRuleEnabled: Bool { toggle.isSupported && SettingsService.shared.autoBuiltinFollowsExternal }

    /// Whether to offer the rule at all: Apple Silicon, and a Mac with a built-in panel to
    /// switch. Read from the full display list, so a built-in that is currently switched off
    /// still counts (that is the state the setting is most likely to be changed from).
    var isAvailable: Bool {
        toggle.isSupported
            && toggle.allDisplaysIncludingDisabled().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// True when the rule, not a stored record, decides whether the built-in is connected.
    /// `PhysicalDisplayToggleService.reconcile` checks this so it never re-applies a stale
    /// built-in disconnect to a Mac that woke up undocked.
    var ownsBuiltinState: Bool { isRuleEnabled }

    // MARK: - Entry points

    /// First evaluation of the session. Called once at launch.
    func start() {
        evaluateSoon()
    }

    /// Coalesces the reconfiguration burst a plug, unplug, wake or lid change produces into one
    /// evaluation, `settleDelay` after the last of them.
    func evaluateSoon() {
        // Live displays while we still believe the machine is asleep means a wake notification
        // never reached us; treat it as the wake rather than staying stood down on a stale flag.
        // Safe because system sleep empties the active list outright on this path (that is the
        // very state the sleep flag exists for), so this cannot fire mid-sleep.
        if displaysAsleep, !toggle.viewableActiveDisplays().isEmpty {
            displaysDidWake()
            return
        }
        scheduleEvaluate(after: Self.settleDelay)
    }

    /// One pending evaluation at a time, always the latest. Also how the rule comes back on its
    /// own after a stand-down: nothing else would necessarily wake it, since the display state
    /// it is waiting on is not changing.
    private func scheduleEvaluate(after delay: TimeInterval) {
        guard toggle.isSupported else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.1) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.evaluate()
        }
    }

    /// The machine or its screens are going to sleep: every display leaves the active list, and
    /// by enumeration alone that is indistinguishable from every screen having gone dark. Stop
    /// judging until they are back.
    func displaysWillSleep() {
        displaysAsleep = true
        pending?.cancel(); pending = nil
        blackoutWatch?.cancel(); blackoutWatch = nil
    }

    /// Woken: give the displays their grace window to arrive, then evaluate once.
    func displaysDidWake() {
        displaysAsleep = false
        wakeGraceUntil = Date().addingTimeInterval(Self.wakeGrace)
        scheduleEvaluate(after: Self.wakeGrace + Self.settleDelay)
    }

    /// The setting changed: apply it now rather than at the next display event, so switching it
    /// on while already docked disconnects the built-in there and then.
    func settingDidChange() {
        userOwnsBuiltin = false
        evaluateSoon()
    }

    /// The user reconnected a display from the menu. If that's the built-in, it is a deliberate
    /// override of the rule; respect it until the next dock event.
    func userDidReconnect(uuid: String) {
        guard isRuleEnabled, isBuiltin(uuid: uuid) else { return }
        userOwnsBuiltin = true
    }

    /// The user disconnected a display from the menu. The built-in: they have handed the panel
    /// back, so the rule takes it over from here. An external: this is not an undock, however
    /// much it looks like one from the display list, and the rule must not treat the display
    /// coming back as a fresh dock.
    func userDidDisconnect(uuid: String) {
        guard isBuiltin(uuid: uuid) else {
            userRemovedExternal = true
            return
        }
        userOwnsBuiltin = false
    }

    // MARK: - The rule

    func evaluate() async {
        guard toggle.isSupported, !running, !toggle.isBlinking, !displaysAsleep else { return }
        // Displays are still arriving after a wake; come back once they have settled.
        guard Date() >= wakeGraceUntil else {
            scheduleEvaluate(after: wakeGraceUntil.timeIntervalSinceNow + Self.settleDelay)
            return
        }
        running = true
        defer { running = false }

        rememberDisplays()

        // Nothing believable on the desk. Not acted on here: a display leaving is ordinary
        // mid-transition, and a blackout is only a blackout once it holds. The watch confirms it,
        // whatever the setting says, because no screen is never a state to leave a Mac in.
        if !hasTrustedDisplay() {
            startBlackoutWatch()
            return
        }
        blackoutWatch?.cancel()
        blackoutWatch = nil
        let usable = toggle.viewableActiveDisplays()
        lastHealthyDisplayIDs = Set(usable)
        suspectDisplayIDs.formIntersection(toggle.onlineDisplayIDs())

        guard isRuleEnabled else { return }
        guard Date() >= suppressRuleUntil else {
            // Standing down on a clock: come back when it runs out, since the display state the
            // rule is waiting on will not change by itself and nothing else would wake it.
            scheduleEvaluate(after: suppressRuleUntil.timeIntervalSinceNow + 0.5)
            return
        }

        let externals = currentExternals()
        let docked = !externals.isEmpty
        let undocked = wasDocked && !docked
        let byHand = userRemovedExternal
        userRemovedExternal = false
        wasDocked = docked
        if !docked {
            // Undocked. The panel must come back, whether it was this rule that took it away,
            // a manual disconnect, or a window-server state that outlived the last session.
            // The desk the user made their choice on is gone, so the rule takes the panel back
            // over at the next dock — but only for an undock that actually happened. Switching
            // the external off from Crisp's own menu empties this list identically, and taking
            // that as an undock is how connecting that display again took away a panel the user
            // had just asked for.
            if undocked, !byHand {
                userOwnsBuiltin = false
            }
            blockedExternalsSignature = nil
            if let builtin = disabledBuiltinID() {
                Self.log.notice("Undocked: bringing the built-in panel back")
                await bringBack(builtin)
            }
        } else {
            guard !userOwnsBuiltin else { return }
            guard blockedExternalsSignature != signature(of: externals) else { return }
            // Docked. Take the panel out of the layout, but never as the last screen standing.
            guard let builtin = onlineBuiltinID(),
                  !toggle.wouldLeaveNoActiveDisplay(builtin) else { return }
            let info = DisplayManagerAccessor.shared.displays.first { $0.displayID == builtin }
                ?? DisplayInfo(displayID: builtin)
            Self.log.notice("Docked (\(externals.count, privacy: .public) external(s)): disconnecting the built-in panel")
            lastRuleDisconnect = Date()
            let result = await toggle.disconnect(info)
            if case .failure(let error) = result {
                Self.log.error("Built-in disconnect failed: \(error.description, privacy: .public)")
            }
        }
    }

    // MARK: - Blackout watch

    /// Armed by an evaluation that found nothing viewable, and by nothing else. In the dark a
    /// further reconfiguration callback is exactly what cannot be relied on, so this is the one
    /// state worth polling for — and it is bounded at both ends: it stops the moment a screen is
    /// back, when the machine sleeps, once it has rescued, or after `blackoutWatchLimit`. The
    /// app holds no timer at any other time.
    private func startBlackoutWatch() {
        // Nothing to switch back on means nothing to watch for: a Mac genuinely running headless
        // (a virtual display only) must not be polled into a rescue loop.
        guard blackoutWatch == nil, !rescueCandidates().isEmpty else { return }
        blackoutWatchGeneration += 1
        let generation = blackoutWatchGeneration
        blackoutWatch = Task { [weak self] in
            var darkFor: TimeInterval = 0
            var elapsed: TimeInterval = 0
            while !Task.isCancelled, elapsed < Self.blackoutWatchLimit {
                try? await Task.sleep(nanoseconds: UInt64(Self.blackoutPoll * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                elapsed += Self.blackoutPoll
                // Asleep, or still inside the post-wake window: the display list means nothing
                // yet, so the confirmation starts over rather than counting this second.
                guard !self.displaysAsleep, Date() >= self.wakeGraceUntil else {
                    darkFor = 0
                    continue
                }
                guard !self.hasTrustedDisplay() else { break }
                darkFor += Self.blackoutPoll
                guard darkFor >= Self.blackoutConfirm, !self.running, !self.toggle.isBlinking
                else { continue }
                self.running = true
                await self.rescue()
                self.running = false
                break
            }
            if let self, self.blackoutWatchGeneration == generation { self.blackoutWatch = nil }
        }
    }

    /// Brings a screen back when nothing viewable is left: the built-in first, since it is the
    /// one display that is certainly attached, then every other switched-off display. Re-enabling
    /// fires a CG reconfiguration, so DisplayManager refreshes itself and
    /// `PhysicalDisplayToggleService.reconcile` drops the records that came back.
    private func rescue() async {
        let ruleCaused = Date().timeIntervalSince(lastRuleDisconnect) < Self.ruleCausedWindow
        Self.log.error("""
            Every screen dark for \(Self.blackoutConfirm, privacy: .public)s with \
            \(self.toggle.disabledDisplayIDs().count, privacy: .public) display(s) switched off \
            at the window server: re-enabling
            """)

        // On a Mac with a built-in panel, that panel is the whole rescue: it is the one display
        // certainly still attached, while re-enabling a remembered external can produce a screen
        // that is not physically there and hides the blackout behind it. Desktops have no such
        // anchor, so there the remembered IDs are all there is to try.
        let candidates = rescueCandidates()
        let builtins = candidates.filter { isKnownBuiltin($0) }
        let targets = builtins.isEmpty ? candidates : builtins

        for attempt in 0..<3 {
            for id in targets {
                await toggle.forceEnable(displayID: id)
                // Enumeration lags the transaction; a short wait here is what lets the loop
                // stop at the first display that actually comes back instead of switching
                // every remembered one on.
                for _ in 0..<10 where !hasTrustedDisplay() {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if hasTrustedDisplay() { break }
            }
            if hasTrustedDisplay() { break }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }

        // Whatever else is online now that was never part of a lit desk turned up during the
        // blackout on its own. Mark it, so the rule does not dock the built-in away against it.
        // The mark lasts until that display goes offline: a monitor genuinely plugged in during
        // a blackout gets caught by this too, and a replug is what clears it.
        suspectDisplayIDs.formUnion(toggle.viewableActiveDisplays().filter {
            CGDisplayIsBuiltin($0) == 0 && !lastHealthyDisplayIDs.contains($0) && !targets.contains($0)
        })

        toggle.reconcile()
        if hasTrustedDisplay() {
            Self.log.notice("""
                Rescue done: \(self.toggle.viewableActiveDisplays().count, privacy: .public) \
                display(s) online, \(self.suspectDisplayIDs.count, privacy: .public) of them unverifiable
                """)
        } else {
            Self.log.fault("Rescue could not bring a display the user can be shown back")
        }

        if ruleCaused {
            // The rule's own disconnect preceded this: whatever it left running shows no
            // picture. Waiting out a clock would only reach the same conclusion, so stand down
            // until the external displays themselves change.
            blockedExternalsSignature = signature(of: currentExternals())
            Self.log.notice("Blackout followed the rule's own disconnect: standing down until the displays change")
        } else {
            suppressRuleUntil = Date().addingTimeInterval(Self.rescueCooloff)
            scheduleEvaluate(after: Self.rescueCooloff + Self.settleDelay)
        }

        await restoreRememberedModes()
    }

    /// Reconnects the built-in through the normal path (so its record is dropped), falling back
    /// to a direct enable for a window-server state with no record behind it.
    private func bringBack(_ builtinID: CGDirectDisplayID) async {
        let builtinUUID = toggle.displayUUID(for: builtinID)
        if toggle.isDisconnected(uuid: builtinUUID) {
            _ = await toggle.reconnect(uuid: builtinUUID)
        } else {
            await toggle.forceEnable(displayID: builtinID)
        }
        _ = await toggle.verifyBackOnline(uuid: builtinUUID, timeout: 3.0)
        await restoreRememberedModes()
    }

    /// A display that has just been switched back on re-enumerates its modes and can land on the
    /// window server's default rather than the resolution the user chose (the HiDPI scaled mode
    /// they set up Crisp for in the first place). The saved-mode restore is the same one the
    /// wake path runs, and a no-op when the display is already where it belongs.
    private func restoreRememberedModes() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for id in toggle.viewableActiveDisplays() {
            ResolutionService.shared.reapplySavedModeIfNeeded(for: id)
        }
    }

    // MARK: - Topology helpers

    /// Whether anything on the desk can be believed to be showing a picture: the built-in panel,
    /// which is certainly attached, or a display that was already there when things last worked.
    /// A display that appears mid-blackout and matches neither is not evidence of recovery — it
    /// is the shape a resurrected detached monitor takes (see `suspectDisplayIDs`). With no
    /// history yet (a fresh launch), any usable display has to be taken at face value.
    private func hasTrustedDisplay() -> Bool {
        let usable = toggle.viewableActiveDisplays()
        guard !usable.isEmpty else { return false }
        guard !lastHealthyDisplayIDs.isEmpty else { return true }
        return usable.contains { CGDisplayIsBuiltin($0) != 0 || lastHealthyDisplayIDs.contains($0) }
    }

    /// Online, real external displays: what "docked" means here.
    private func currentExternals() -> [CGDirectDisplayID] {
        toggle.viewableActiveDisplays().filter {
            CGDisplayIsBuiltin($0) == 0 && !suspectDisplayIDs.contains($0)
        }
    }

    /// Order-independent identity for a set of externals, so a stand-down survives an ID
    /// reshuffle but not an actual change of desk.
    private func signature(of ids: [CGDirectDisplayID]) -> String {
        ids.map { toggle.displayUUID(for: $0) }.sorted().joined(separator: "|")
    }

    private func onlineBuiltinID() -> CGDirectDisplayID? {
        toggle.viewableActiveDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// The built-in panel while the window server has it switched off. Read from the full
    /// (including disabled) list rather than from the `disconnected` records: after a long
    /// standby, or a session that ended uncleanly, the window-server state can outlive them.
    private func disabledBuiltinID() -> CGDirectDisplayID? {
        toggle.disabledDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Whether an ID is the built-in panel, trusting the remembered flag when CoreGraphics can
    /// no longer say (it answers with garbage for an ID the window server has forgotten, which
    /// is the state a blackout leaves every real display in).
    private func isKnownBuiltin(_ id: CGDirectDisplayID) -> Bool {
        if knownDisplays.isEmpty { knownDisplays = loadKnownDisplays() }
        return CGDisplayIsBuiltin(id) != 0 || knownDisplays[id] == true
    }

    /// Records every real display the window server can currently name, so the rescue has
    /// something to aim at once it can no longer name any (see knownDisplays).
    private func rememberDisplays() {
        var known = knownDisplays.isEmpty ? loadKnownDisplays() : knownDisplays
        var changed = false
        for id in toggle.allDisplaysIncludingDisabled() {
            // Skip the placeholder and any virtual display: re-enabling those rescues nothing.
            guard CGDisplayVendorNumber(id) <= 0xFFFF, CGDisplayModelNumber(id) <= 0xFFFF,
                  !VirtualDisplayService.shared.isVirtualDisplay(id) else { continue }
            let builtin = CGDisplayIsBuiltin(id) != 0
            if known[id] != builtin { known[id] = builtin; changed = true }
        }
        knownDisplays = known
        if changed {
            UserDefaults.standard.set(
                Dictionary(uniqueKeysWithValues: known.map { (String($0.key), $0.value) }),
                forKey: Self.knownDisplaysKey)
        }
    }

    private func loadKnownDisplays() -> [CGDirectDisplayID: Bool] {
        let stored = UserDefaults.standard.dictionary(forKey: Self.knownDisplaysKey) as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            CGDirectDisplayID(key).map { ($0, value) }
        })
    }

    /// Displays worth switching back on, built-in first (it is the one display certainly still
    /// attached). Three sources, because in a blackout the first two can both come up empty:
    /// what the window server reports as off, the IDs stored in the disconnect records, and the
    /// remembered real displays. Anything already online is dropped; a stale ID for hardware
    /// that is genuinely gone simply fails its transaction.
    private func rescueCandidates() -> [CGDirectDisplayID] {
        if knownDisplays.isEmpty { knownDisplays = loadKnownDisplays() }
        let online = toggle.onlineDisplayIDs()
        var builtin: [CGDirectDisplayID] = []
        var rest: [CGDirectDisplayID] = []
        var seen: Set<CGDirectDisplayID> = []
        func add(_ id: CGDirectDisplayID, isBuiltin: Bool) {
            guard !online.contains(id), seen.insert(id).inserted else { return }
            if isBuiltin { builtin.append(id) } else { rest.append(id) }
        }
        for id in toggle.disabledDisplayIDs() {
            add(id, isBuiltin: CGDisplayIsBuiltin(id) != 0 || knownDisplays[id] == true)
        }
        for record in toggle.disconnected {
            // CGDisplayIsBuiltin answers with garbage for an ID the window server has forgotten,
            // so the remembered flag is what decides the order here.
            add(record.displayID, isBuiltin: knownDisplays[record.displayID] == true)
        }
        for (id, isBuiltin) in knownDisplays {
            add(id, isBuiltin: isBuiltin)
        }
        return builtin + rest
    }

    /// Whether a UUID names the built-in panel, resolved against the full display list so the
    /// answer does not depend on the display being online at this instant: a just-reconnected
    /// display takes a moment to appear in the online list, and the manual override has to be
    /// recorded before the next evaluation, not after.
    private func isBuiltin(uuid: String) -> Bool {
        guard let id = toggle.allDisplaysIncludingDisabled().first(where: {
            toggle.displayUUID(for: $0) == uuid
        }) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}
