import Foundation
import CoreGraphics
import ColorSync
import IOKit
import os.log

/// Disconnects / reconnects REAL (physical) displays on the fly, the way BetterDisplay's
/// "Disconnect Display" works. This is fundamentally different from VirtualDisplayService:
/// there we create/destroy a CGVirtualDisplay object; here we toggle an existing hardware
/// display in/out of the layout via the private SkyLight API `SLSConfigureDisplayEnabled`.
///
/// PLATFORM: Apple Silicon + macOS 13+ ONLY. On Intel the API does not perform a true
/// disconnect. Everything is gated behind `isSupported`.
///
/// KEY QUIRK: once a display is disabled it disappears from `CGGetOnlineDisplayList`
/// (and `CGGetActiveDisplayList`). To reconnect it we must find it again via
/// `SLSGetDisplayList`, which still enumerates disabled displays. Because the disconnected
/// display is also gone from DisplayManager's list, this service keeps its own snapshot
/// (`disconnected`) of what we turned off so the UI can still offer a Reconnect action.
@MainActor
final class PhysicalDisplayToggleService: ObservableObject {
    static let shared = PhysicalDisplayToggleService()
    private init() {
        loadDesired()
    }

    /// Snapshot of a display we disconnected, kept because a disconnected display no longer
    /// appears in DisplayManager.displays, so we need its metadata to render a Reconnect row.
    struct DisconnectedDisplay: Identifiable, Codable, Sendable, Equatable {
        let uuid: String            // stable identity across CGDirectDisplayID reassignment
        var displayID: CGDirectDisplayID  // last-known ID (used to reconnect)
        var name: String
        var width: Int
        var height: Int
        /// Whether this was the built-in panel, captured at disconnect time. Optional so
        /// records written before this field decode instead of throwing away the whole list.
        var isBuiltin: Bool?
        var id: String { uuid }
    }

    enum ToggleError: Error, Sendable, CustomStringConvertible {
        case unsupportedPlatform
        case wouldLeaveNoActiveDisplay
        case configurationFailed(CGError)
        case displayNotFound

        var description: String {
            switch self {
            case .unsupportedPlatform:
                return String(localized: "Physical display disconnect requires Apple Silicon (macOS 13+).")
            case .wouldLeaveNoActiveDisplay:
                return String(localized: "Refusing to disconnect: it would leave no active display.")
            case .configurationFailed(let err):
                return String(localized: "Display configuration failed (CGError \(String(err.rawValue))).")
            case .displayNotFound:
                return String(localized: "Display not found.")
            }
        }
    }

    // MARK: - State

    /// Displays the user has disconnected and can reconnect. Persisted (by UUID) so wake and
    /// relaunch can restore the intended state.
    @Published private(set) var disconnected: [DisconnectedDisplay] = []

    private let desiredKey = "crisp.PhysicalDisconnectedUUIDs"
    /// Dead-man markers: the UUIDs of displays a softReconnect is (or was, if the app died)
    /// mid-toggle on. A list, not a single slot: a manual smooth-scaling toggle and the
    /// auto-HiDPI path (autoEnableHiDPIIfNeeded) can blink two different displays at once,
    /// and each needs its own marker. See softReconnect / recoverStrandedSoftReconnect.
    private let softReconnectPendingKey = "crisp.PhysicalDisplayToggleService.softReconnectPending"
    /// UUIDs of displays whose softReconnect is mid-blink right now. Their markers above are
    /// legitimately set for that whole window, and the blink's own removeFlag event fires
    /// refreshDisplays (and thus recoverStrandedSoftReconnect) before the toggle finishes;
    /// this keeps the recovery path and the sweep from re-enabling a display out from under
    /// its own retry loop. Per-display, so concurrent blinks don't mask each other.
    private var softReconnectInFlight: Set<String> = []
    /// UUIDs whose reconnect is running right now. `reconnect` only clears the record once
    /// `setEnabled(true)` returns, and a reconfiguration callback inside that window runs
    /// `refreshDisplays`, and therefore `reconcile`, which would find the display online with
    /// its record still in place and switch it straight back off: the user clicks Reconnect
    /// and nothing happens. The record is the wrong thing to read there, so read this instead.
    private var reconnectInFlight: Set<String> = []

    private func pendingSoftReconnectUUIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: softReconnectPendingKey) ?? []
    }

    private func addPendingSoftReconnect(_ displayUUID: String) {
        var pending = pendingSoftReconnectUUIDs()
        guard !pending.contains(displayUUID) else { return }
        pending.append(displayUUID)
        UserDefaults.standard.set(pending, forKey: softReconnectPendingKey)
    }

    private func removePendingSoftReconnect(_ displayUUID: String) {
        let pending = pendingSoftReconnectUUIDs().filter { $0 != displayUUID }
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: softReconnectPendingKey)
        } else {
            UserDefaults.standard.set(pending, forKey: softReconnectPendingKey)
        }
    }

    // MARK: - Logging

    /// The disconnect path was the one display capability with no unified-log presence, which
    /// left issue #33 (a whole-machine freeze on reconnect through a Lenovo hub) with only
    /// WindowServer's half of the story: a 29.5 s silence in the reporter's capture and
    /// nothing from us to say what we had asked for, or how long the ask took.
    private nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "display")

    /// Matches DDCService's threshold so slow operations read the same across categories.
    private nonisolated static let slowOpThresholdMs = 500.0

    private nonisolated static func millisSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Support gate

    /// True only on Apple Silicon. The disconnect API is a no-op / misbehaves on Intel.
    let isSupported: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Queries

    /// True if the display is currently in our disconnected set.
    func isDisconnected(uuid: String) -> Bool {
        disconnected.contains { $0.uuid == uuid }
    }

    /// True if disconnecting `display` right now would leave no *viewable* screen.
    /// Virtual displays are excluded from the count on purpose: they are headless,
    /// so leaving only a virtual display still blacks out the physical machine.
    func wouldLeaveNoActiveDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(displayID) != 0 && physicalActiveDisplayCount() <= 1
    }

    /// All display IDs known to the window server, INCLUDING ones disabled via
    /// `SLSConfigureDisplayEnabled` (which `CGGetOnlineDisplayList` omits).
    private func allDisplaysIncludingDisabled() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard SLSGetDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard SLSGetDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Count of active displays that are real physical screens, excluding virtual
    /// displays managed by VirtualDisplayService (a virtual display is active in
    /// CGGetActiveDisplayList but is not a viewable screen).
    private func physicalActiveDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return 0 }
        let virtual = VirtualDisplayService.shared
        return ids.prefix(Int(count)).filter { id in
            guard !virtual.isVirtualDisplay(id) else { return false }
            // Real panels carry 16-bit EDID vendor and product codes. Two kinds of
            // entry enumerate as active without a screen behind them, and both fail
            // that shape: the placeholder macOS spawns once the last real display is
            // gone (vendor 'unkn' 0x756E6B6E, model 'virt' 0x76697274, four-character
            // tags that cannot fit in 16 bits; fingerprinted live on macOS 26), and the
            // stub a re-enabled record leaves when its hardware is no longer attached
            // (vendor 0, model 0; observed live by @ncchen99 on #91, online and active,
            // showing nothing). Counting either kept restoreIfNoActiveDisplay from
            // firing, or let it stop, in the all-screens-black state it exists to fix.
            // Matching by shape rather than by the one fingerprint also survives a
            // future macOS renaming the placeholder.
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
            let hasNoPanel = vendor == 0 || model == 0 || vendor > 0xFFFF || model > 0xFFFF
            return !hasNoPanel
        }.count
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String {
        if let cf = CGDisplayCreateUUIDFromDisplayID(displayID),
           let s = CFUUIDCreateString(nil, cf.takeRetainedValue()) {
            return s as String
        }
        return "id-\(displayID)"
    }

    // MARK: - Disconnect / Reconnect

    /// Disconnects a physical display and records a snapshot for later reconnect. Refuses if it
    /// would leave zero active displays, so the user can never black out their only screen.
    @discardableResult
    func disconnect(_ display: DisplayInfo) async -> Result<Void, ToggleError> {
        guard isSupported else { return .failure(.unsupportedPlatform) }
        let displayID = display.displayID
        if wouldLeaveNoActiveDisplay(displayID) { return .failure(.wouldLeaveNoActiveDisplay) }

        // Snapshot BEFORE disabling, afterwards the display is gone from the normal APIs.
        let snapshot = DisconnectedDisplay(
            uuid: display.displayUUID,
            displayID: displayID,
            name: display.name,
            width: display.pixelWidth,
            height: display.pixelHeight,
            isBuiltin: display.isBuiltin
        )

        Self.log.notice("disconnect requested: \(display.displayUUID, privacy: .public) id \(displayID, privacy: .public)")
        let otherModes = currentModes(excluding: displayID)
        let result = await setEnabled(false, displayID: displayID)
        if case .success = result {
            disconnected.removeAll { $0.uuid == snapshot.uuid }
            disconnected.append(snapshot)
            saveDesired()
            Task { [weak self] in await self?.restoreModes(otherModes) }
        }
        return result
    }

    /// The mode of every other online display, taken before a disconnect so it can be put
    /// back afterwards. macOS keeps an arrangement per set of attached displays and applies
    /// it whenever the set changes, so taking one display away can move the others to
    /// whatever they last ran at in the smaller set: on this Mac a 1440p 165 Hz panel dropped
    /// to 1080p 60 Hz and the built-in changed scale (issue #108). It is WindowServer's doing,
    /// not Crisp's: the same SkyLight disable from a bare probe with Crisp quit does it too,
    /// and pinning the other modes inside the disable transaction is accepted and ignored.
    /// The user asked for one display to go, not for the rest to change, so the modes they
    /// had go back in a second transaction once the arrangement has landed.
    private func currentModes(excluding displayID: CGDirectDisplayID) -> [(CGDirectDisplayID, CGDisplayMode)] {
        onlineDisplayIDs().filter { $0 != displayID }.compactMap { id in
            CGDisplayCopyDisplayMode(id).map { (id, $0) }
        }
    }

    private func restoreModes(_ modes: [(CGDirectDisplayID, CGDisplayMode)]) async {
        // A mirror target's mode is driven by its source (see ResolutionService).
        let moved = {
            modes.compactMap { id, mode -> (CGDirectDisplayID, CGDisplayMode, CGDisplayMode)? in
                guard self.onlineDisplayIDs().contains(id), !MirroredModeService.shared.isActive(for: id),
                      let current = CGDisplayCopyDisplayMode(id),
                      current.ioDisplayModeID != mode.ioDisplayModeID else { return nil }
                return (id, current, mode)
            }
        }
        // The re-arrangement landed about a second after the commit here. Poll for it rather
        // than wait a fixed time, so the flip the user sees is as short as it can be; the
        // extra tick after the first move catches a second display changing in the same breath.
        var changed = moved()
        for _ in 0..<30 where changed.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
            changed = moved()
        }
        guard !changed.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for (id, current, mode) in moved() {
            let restored = await ResolutionService.applyModeSync(mode, on: id)
            Self.log.notice("display \(id, privacy: .public) moved to \(current.width, privacy: .public)x\(current.height, privacy: .public) after the disconnect, restoring \(mode.width, privacy: .public)x\(mode.height, privacy: .public) @\(Int(mode.refreshRate), privacy: .public): \(restored ? "ok" : "failed", privacy: .public)")
        }
    }

    /// Reconnects a previously disconnected display and drops it from the disconnected set.
    @discardableResult
    func reconnect(uuid: String) async -> Result<Void, ToggleError> {
        guard isSupported else { return .failure(.unsupportedPlatform) }
        guard let record = disconnected.first(where: { $0.uuid == uuid }) else {
            return .failure(.displayNotFound)
        }
        // The CGDirectDisplayID can be reassigned; re-resolve by UUID against the full list.
        let targetID = resolveCurrentID(for: record) ?? record.displayID
        Self.log.notice("reconnect requested: \(uuid, privacy: .public) id \(targetID, privacy: .public)")
        reconnectInFlight.insert(uuid)
        defer { reconnectInFlight.remove(uuid) }
        let result = await setEnabled(true, displayID: targetID)
        if case .success = result {
            disconnected.removeAll { $0.uuid == uuid }
            saveDesired()
        }
        return result
    }

    /// Built-in test for a disconnect record. Prefers the flag captured at disconnect time,
    /// while the ID still answered truthfully: in the all-black state this matters in,
    /// SLSGetDisplayList has collapsed to the placeholder display and CGDisplayIsBuiltin
    /// answers with garbage for the stale IDs left over. Records written before that flag
    /// existed fall back to the live query, which is no worse than before.
    private func wasBuiltin(_ record: DisconnectedDisplay, id: CGDirectDisplayID) -> Bool {
        record.isBuiltin ?? (CGDisplayIsBuiltin(id) == 1)
    }

    /// Finds the current CGDirectDisplayID for a disconnected record by matching its UUID
    /// across the full (incl. disabled) display list.
    private func resolveCurrentID(for record: DisconnectedDisplay) -> CGDirectDisplayID? {
        allDisplaysIncludingDisabled().first { uuid(for: $0) == record.uuid }
    }

    /// Soft-reconnects a display (disable then re-enable its framebuffer) to force macOS to
    /// re-read a freshly written EDID override and re-enumerate its modes. This is what lets
    /// smooth-scaling / HiDPI injection take effect without the user physically unplugging the
    /// cable: IOServiceRequestProbe and SLSDetectDisplays are both too weak (verified no-ops),
    /// but the off→on framebuffer toggle re-reads the override (verified live: an external's
    /// mode count went 149→113 when its override was removed and 113→149 when restored, each
    /// time via this toggle). The screen blanks ~1s. Re-resolves the ID by UUID before
    /// re-enabling since the disconnect can reassign it, and retries the re-enable so a transient
    /// failure can't strand a black screen. Unlike disconnect() it leaves the `disconnected` set
    /// untouched: this is a re-enumeration blip, not a user-visible disconnect.
    ///
    /// Unlike disconnect(), this blinks even the sole active display: refusing just makes
    /// the override a silent no-op until the next reboot or replug (issue #58), which is
    /// worse than a ~1s blank the retry loop below is built to recover from. On portables a
    /// throwaway virtual display is held for the blink's duration so Clamshell Sleep never
    /// fires mid-toggle (see makeBlinkSleepGuard). Two safety nets back the blink up: a
    /// dead-man marker in case the app dies mid-toggle (recoverStrandedSoftReconnect), and a
    /// full disabled-display sweep if every re-enable retry fails outright
    /// (reenableUnintentionallyDisabled). Refuses (false) on Intel, when the portable sleep
    /// guard can't be created, or if the disable/verified re-enable never lands.
    @discardableResult
    func softReconnect(_ display: DisplayInfo) async -> Bool {
        guard isSupported else { return false }
        let blinkUUID = display.displayUUID
        // Two callers can race on the same display (manual toggle + auto-HiDPI on a fresh
        // connect): a second blink mid-blink would double-toggle the framebuffer and try to
        // create a second sleep guard with the same fixed identity, which WindowServer
        // rejects (see VirtualDisplayService.create). First one wins; the caller's settle
        // re-read adopts whatever it produced.
        guard !softReconnectInFlight.contains(blinkUUID) else { return false }
        let startID = display.displayID
        // The re-enumeration can come back on macOS's default mode instead of the one the
        // user was running (refresh-rate reset observed live on a 180Hz panel); capture the
        // exact mode so a verified re-enable can restore it. Must be captured before the
        // sleep guard below exists: the guard's arrival alone knocked this panel from 165Hz
        // to 144Hz (observed live), so capturing after it memorizes the knocked-down mode.
        let previousMode = CGDisplayCopyDisplayMode(startID)
        // A lid-closed portable sleeps the instant its sole active display goes away
        // (Clamshell Sleep; verified live: the blink's disable triggered it mid-toggle, the
        // wake left the display SLS-disabled behind a lying re-enable "success", and a
        // PreventSystemSleep assertion does NOT stop it). A live virtual display keeps the
        // display count above zero, which verifiably does prevent it (probed on the same
        // hardware), so hold a throwaway one for the blink's duration. Lid-open laptops
        // never get here (the built-in keeps the count above one); desktops need no guard
        // (no clamshell rule). Refuse only if the guard can't be created: blinking into a
        // guaranteed mid-toggle sleep is how displays get stranded.
        var sleepGuard: CGVirtualDisplay?
        if Self.hasBattery && wouldLeaveNoActiveDisplay(startID) {
            // Reuse a guard parked by a previous unresolved blink first: the fixed identity
            // can't exist twice, so creating a fresh one alongside it would just fail.
            sleepGuard = lingeringSleepGuard
            lingeringSleepGuard = nil
            if sleepGuard == nil { sleepGuard = await makeBlinkSleepGuard() }
            if sleepGuard == nil { return false }
        }
        // Held (released) at every exit below; releasing it is what removes the display.
        defer { withExtendedLifetime(sleepGuard) {} }
        // Logged so a capture can tell a blink's disable/enable pair from a user's own
        // disconnect and reconnect, which look identical at the transaction level.
        Self.log.notice("soft reconnect blink: \(blinkUUID, privacy: .public) id \(startID, privacy: .public)")
        softReconnectInFlight.insert(blinkUUID)
        defer { softReconnectInFlight.remove(blinkUUID) }
        // Persist before disabling: if the app dies between here and a verified re-enable
        // below (crash, force-quit), the display would otherwise be stuck SLS-disabled with
        // nothing left to bring it back. recoverStrandedSoftReconnect checks this at the next
        // launch. Cleared as soon as the display is verifiably back online, or immediately
        // below if the disable itself never happened.
        addPendingSoftReconnect(blinkUUID)
        guard case .success = await setEnabled(false, displayID: startID) else {
            removePendingSoftReconnect(blinkUUID)
            return false
        }
        // Wait for the framebuffer to actually drop (removeFlag) before re-enabling;
        // the 0.9s ceiling matches the old fixed sleep if the event never comes.
        await ReconfigEvents.shared.next(for: startID, matching: .removeFlag, timeout: 0.9)
        var backOnline = false
        for _ in 0..<3 {
            let targetID = allDisplaysIncludingDisabled().first { uuid(for: $0) == blinkUUID } ?? startID
            // Fire the enable without awaiting its result. The result is untrustworthy in
            // both directions (successes can lie, see verifyBackOnline; failures can mask a
            // display already coming up), and CGCompleteDisplayConfiguration can block ~10s
            // past the display's actual return while the link retrains after an override
            // rebuild (observed live), which would hold the mode restore below hostage
            // behind a blocked call and turn it into a second visible blink ~10s after the
            // toggle. Enumeration is the only proof either way.
            Task { _ = await setEnabled(true, displayID: targetID) }
            // The verify window must outlast a display link handshake (2-4s): re-issuing
            // enable while the display is mid-sync restarts the link and blinks it again.
            if await verifyBackOnline(uuid: blinkUUID, timeout: 4.0) { backOnline = true; break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !backOnline {
            // The target never came back under its own re-enables: don't leave any display
            // our own disable may have stranded off. Drop the in-flight claim first: the
            // sweep skips displays with a live claim, which would otherwise make it ignore
            // the very display it's here to rescue.
            softReconnectInFlight.remove(blinkUUID)
            await reenableUnintentionallyDisabled()
            // One longer last look before declaring failure: slow re-enumeration must land
            // in the success epilogue below. Treating it as failure skips the mode restore
            // (refresh-rate reset observed live) and parks the guard, whose later release
            // reshuffles the windows a second time, seconds after the toggle.
            backOnline = await verifyBackOnline(uuid: blinkUUID, timeout: 2.0)
        }
        guard backOnline else {
            // Genuinely still down. The marker stays on purpose so refresh/relaunch keeps
            // retrying, and the sleep guard is parked: releasing it now would hand a
            // lid-closed portable straight to Clamshell Sleep with the display stranded,
            // the exact state the guard exists to prevent. Recovery releases it once every
            // marked display is resolved.
            if sleepGuard != nil { lingeringSleepGuard = sleepGuard }
            return false
        }
        removePendingSoftReconnect(blinkUUID)
        if let previousMode,
           let backID = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == blinkUUID }) {
            // The blink re-reads override plists, which rebuilds the mode list and renumbers
            // every mode ID (observed live: the same timing went 130 -> 683), so the captured
            // object cannot be applied directly; re-find the equivalent mode in the fresh
            // list by parameters. No match means the mode no longer enumerates (toggling
            // smooth OFF removes the dense mode the user may have been running): macOS's
            // fallback stands, same as pre-fix.
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(backID, options) as? [CGDisplayMode] ?? []
            if let target = modes.first(where: {
                $0.width == previousMode.width && $0.height == previousMode.height
                    && $0.pixelWidth == previousMode.pixelWidth
                    && $0.pixelHeight == previousMode.pixelHeight
                    && abs($0.refreshRate - previousMode.refreshRate) < 1
            }) {
                // A set issued while the link is still retraining can fail silently; verify
                // it stuck and retry briefly instead of trusting one shot.
                for _ in 0..<4 {
                    if CGDisplayCopyDisplayMode(backID)?.ioDisplayModeID == target.ioDisplayModeID { break }
                    _ = await ResolutionService.applyModeSync(target, on: backID)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        return true
    }

    /// Runs SLSConfigureDisplayEnabled inside a CG configuration transaction.
    /// `.permanently` is the flag the proven implementations (Lunar BlackOut, screen_tune,
    /// BetterDisplay) use, it commits the change so the disconnect actually takes effect.
    private func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) async -> Result<Void, ToggleError> {
        let action = enabled ? "enable" : "disable"
        let waited = DispatchTime.now()
        // No DDC traffic while the transaction runs. WindowServer's enable waits behind an
        // in-flight I2C read on the DCP and the whole machine freezes with it: a 6 s volume
        // read on the display Crisp had just disconnected gave a 6 s freeze on its reconnect,
        // the commit completing within 60 ms of the read giving up, three times in a row.
        let releaseDDC = await DDCService.shared.hold()
        defer { releaseDDC() }
        let heldMs = Self.millisSince(waited)
        if heldMs > Self.slowOpThresholdMs {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): waited \(Int(heldMs), privacy: .public) ms for DDC to go idle")
        }
        let result: Result<Void, ToggleError> = await CGHelpers.runWithTimeout(
            seconds: 10, fallback: .failure(.configurationFailed(.failure))
        ) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
                Self.log.error("\(action, privacy: .public) \(displayID, privacy: .public): CGBeginDisplayConfiguration failed")
                return .failure(.configurationFailed(.failure))
            }
            let setErr = SLSConfigureDisplayEnabled(cfg, displayID, enabled)
            guard setErr == .success else {
                CGCancelDisplayConfiguration(cfg)
                Self.log.error("\(action, privacy: .public) \(displayID, privacy: .public): SLSConfigureDisplayEnabled failed \(setErr.rawValue, privacy: .public)")
                return .failure(.configurationFailed(setErr))
            }
            // The commit, and the call that can block. It runs on a background queue and
            // keeps running after the 10 s wrapper above gives up, because the wrapper only
            // stops waiting, it cannot cancel this. While WindowServer holds it the whole
            // machine can stall rather than just Crisp, which is what issue #33 reports.
            // Timed unconditionally so a capture states the real duration instead of
            // leaving a silence to be guessed at.
            let committing = DispatchTime.now()
            let complete = CGCompleteDisplayConfiguration(cfg, .permanently)
            let commitMs = Self.millisSince(committing)
            guard complete == .success else {
                CGCancelDisplayConfiguration(cfg)
                Self.log.error("\(action, privacy: .public) \(displayID, privacy: .public): commit failed \(complete.rawValue, privacy: .public) after \(Int(commitMs), privacy: .public) ms")
                return .failure(.configurationFailed(complete))
            }
            if commitMs > Self.slowOpThresholdMs {
                Self.log.notice("slow \(action, privacy: .public) \(displayID, privacy: .public): commit took \(Int(commitMs), privacy: .public) ms")
            }
            return .success(())
        }
        // What Crisp actually acted on, which is not the same thing: on a wrapper timeout
        // this reports a failure at ~10000 ms while the commit above is still running.
        let waitedMs = Self.millisSince(waited)
        if case .failure = result {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): reported failure after \(Int(waitedMs), privacy: .public) ms")
        } else {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): reported success after \(Int(waitedMs), privacy: .public) ms")
        }
        return result
    }

    /// Safety net for softReconnect's re-enable retries all failing: sweeps every SLS-disabled
    /// display that isn't one we disconnected on purpose (`disconnected`), so a transient
    /// re-enable failure can never leave a screen stuck black. Other apps (Lunar and friends)
    /// disable displays intentionally; those are left alone.
    private func reenableUnintentionallyDisabled() async {
        let onlineSet = onlineDisplayIDs()
        let intentionalUUIDs = Set(disconnected.map { $0.uuid })
        for id in allDisplaysIncludingDisabled() where !onlineSet.contains(id) {
            let displayUUID = uuid(for: id)
            guard !intentionalUUIDs.contains(displayUUID) else { continue }
            // A display mid-blink in a live softReconnect is off on purpose for ~1s; its own
            // retry loop owns bringing it back, and racing it here would reintroduce the
            // recovery-vs-toggle conflict this file just fixed, one display over.
            guard !softReconnectInFlight.contains(displayUUID) else { continue }
            _ = await setEnabled(true, displayID: id)
        }
    }

    /// Display IDs currently online. SLS-disabled displays are omitted here (see
    /// allDisplaysIncludingDisabled), so "online" doubles as the enabled check.
    private func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// True once the display with this UUID is back in the online list, polling up to
    /// `timeout` seconds. A successful SLSConfigureDisplayEnabled transaction is NOT proof
    /// of recovery: around sleep transitions it reports success while the display stays
    /// disabled (verified live in clamshell). Only enumeration counts.
    private func verifyBackOnline(uuid displayUUID: String, timeout: TimeInterval = 1.0) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if let id = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == displayUUID }),
               onlineDisplayIDs().contains(id) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// True once this display has left the online list, polling up to `timeout` seconds.
    /// The disable half of verifyBackOnline, untrustworthy in the same way for the same
    /// reason: the transaction reports what was asked, not what took.
    private func verifyOffline(displayID: CGDirectDisplayID, timeout: TimeInterval) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if !onlineDisplayIDs().contains(displayID) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Portables enforce Clamshell Sleep the moment no display is active; desktops don't.
    /// Battery presence is the lid-independent laptop test (the built-in panel can vanish
    /// from the display lists entirely while the lid is closed, so it can't be the signal).
    private static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()

    /// Throwaway virtual display held while blinking a portable's sole active display, so
    /// Clamshell Sleep never sees a zero-display moment (see softReconnect). Registered but
    /// deliberately minimal: 1080p, no HiDPI ladder. Stamped with the shared virtual vendor
    /// ID so DisplayManager filters it from the UI like any managed virtual display, and
    /// with a FIXED product/serial so macOS keys its per-display settings (including the
    /// "what to show" choice) on a stable identity instead of re-prompting every blink.
    /// Returns nil unless the display verifiably comes online; a registered-but-offline
    /// guard protects nothing.
    private func makeBlinkSleepGuard() async -> CGVirtualDisplay? {
        let w = 1920, h = 1080
        let ppi = 110.0
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.sizeInMillimeters = CGSize(width: Double(w) / ppi * 25.4,
                                              height: Double(h) / ppi * 25.4)
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = "Crisp Blink Guard"
        descriptor.vendorID = VirtualDisplayService.crispVirtualVendorID
        descriptor.productID = 0xB11C
        descriptor.serialNum = 0xB11C
        // DO NOT set queue or color primaries (see VirtualDisplayService.create).
        guard let vd = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = false
        let mode: CGVirtualDisplayMode = CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60.0)
        settings.modes = [mode]
        let applied: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(settings)
        }
        guard applied, vd.displayID != kCGNullDirectDisplay else { return nil }
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(vd.displayID) { return vd }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Reconcile / Wake restore

    /// Re-applies the disconnect for records whose display is back online (a reboot, a
    /// relaunch, a replug, or macOS re-enabling it), and drops the record when that does not
    /// take. Called from DisplayManager.refreshDisplays.
    ///
    /// A disconnect is a choice about one specific display, already stored by UUID, and it
    /// used to last only until that display next showed up. A monitor kept switched off but
    /// still cabled enumerates as an ordinary display at every boot, so the same disconnect
    /// had to be redone by hand every time (issue #93); re-applying it here is what makes
    /// the choice stick. It only ever touches displays the user disconnected themselves, and
    /// only while it is safe to: `wouldLeaveNoActiveDisplay` refuses to take the last screen
    /// and `restoreIfNoActiveDisplay` stays underneath as the backstop. A display still lit
    /// after the attempt drops its record exactly as before, so the list never claims a
    /// display is disconnected while it is on screen.
    ///
    /// That invariant is chosen over the memory, deliberately, and it has a cost worth
    /// stating: boot with the remembered display as the only screen attached and the refusal
    /// is what happens, so the choice is forgotten by a single boot in that configuration —
    /// the complaint #93 opened with, in the one arrangement where honouring it would mean
    /// booting to a black machine. A list that can name a display the user is looking at is
    /// the worse failure, so the trade stands rather than being an oversight.
    func reconcile() {
        guard !disconnected.isEmpty else { return }
        let onlineUUIDs = Set(onlineDisplayIDs().map { uuid(for: $0) })
        let resurfaced = disconnected.filter { onlineUUIDs.contains($0.uuid) }
        guard !resurfaced.isEmpty else { return }
        // Intel has no working disconnect to re-apply, so there the old behaviour is all
        // that is available: forget the record and keep the UI honest.
        guard isSupported else {
            disconnected.removeAll { onlineUUIDs.contains($0.uuid) }
            saveDesired()
            return
        }
        for record in resurfaced {
            // A blink (softReconnect) puts its own display back online on purpose, and a
            // reconnect in flight is the user (or the restore path) asking for exactly that.
            guard !reapplyInFlight.contains(record.uuid),
                  !softReconnectInFlight.contains(record.uuid),
                  !reconnectInFlight.contains(record.uuid) else { continue }
            reapplyInFlight.insert(record.uuid)
            Task { [weak self] in
                guard let self else { return }
                await self.reapplyRemembered(record.uuid)
                self.reapplyInFlight.remove(record.uuid)
            }
        }
    }

    /// Displays whose remembered disconnect is being re-applied right now. A reconfiguration
    /// burst refreshes the display list several times over, and each refresh must not stack
    /// another attempt on the same display.
    private var reapplyInFlight: Set<String> = []

    /// One display's half of reconcile: put it back the way the user left it, or forget it.
    private func reapplyRemembered(_ recordUUID: String) async {
        guard !reconnectInFlight.contains(recordUUID) else { return }
        guard let liveID = onlineDisplayIDs().first(where: { uuid(for: $0) == recordUUID })
        else { return }  // gone again by itself; the record still stands for next time
        var stillOnline = true
        if !wouldLeaveNoActiveDisplay(liveID) {
            _ = await setEnabled(false, displayID: liveID)
            // The API's own answer is not proof, in either direction (see verifyBackOnline),
            // so the record's fate is settled by enumeration below, not by the result. The
            // window matches softReconnect's for the same reason it uses 4s there: a display
            // link handshake runs 2-4s, and a second is most of one healthy transaction on
            // its own (a disable here reported success after 628ms on direct-attached
            // hardware). A short look calls slow hardware "still lit", which is the branch
            // that forgets the record.
            stillOnline = !(await verifyOffline(displayID: liveID, timeout: 4.0))
            if stillOnline {
                // Confirm before acting on it, because this is the branch that lets the
                // record go. setEnabled's wrapper stops waiting at 10s but cannot cancel the
                // commit underneath it, and #33 has WindowServer holding one for 29.5s: a
                // disable can report failure and still be on its way. Forgetting the record
                // on the first look hands that commit a display with nothing left to name it.
                stillOnline = !(await verifyOffline(displayID: liveID, timeout: 2.0))
            }
        }
        guard let idx = disconnected.firstIndex(where: { $0.uuid == recordUUID }) else { return }
        if stillOnline, onlineDisplayIDs().contains(liveID) {
            // Still lit and we could not take it off, a refusal included: forget it, so the
            // list never claims a display is disconnected while the user is looking at it.
            disconnected.remove(at: idx)
        } else {
            // Off, whether or not the transaction said so — and that difference is the whole
            // reason this is decided by enumeration. A disable that reports an error and takes
            // anyway leaves the display switched off at the window server, where the record is
            // the only handle the Reconnect row has on it. Dropping it there strands the
            // display with no way back through the UI, and replugging cannot undo it because
            // the window server holds the state, not the cable.
            disconnected[idx].displayID = liveID
        }
        saveDesired()
    }

    /// Guards against overlapping recovery runs from reconfiguration-callback bursts, same
    /// as restoreInFlight below for restoreIfNoActiveDisplay.
    private var strandedRecoveryInFlight = false

    /// Sleep guard parked by a softReconnect whose display never verifiably returned (see
    /// its retry-exhausted path): holding it keeps a lid-closed portable awake so the
    /// marker/recovery cadence can keep retrying instead of the machine sleeping on a
    /// stranded display. Released by recovery once every marked display is resolved, or
    /// adopted by the next blink (the fixed identity can't be created twice).
    private var lingeringSleepGuard: CGVirtualDisplay?

    /// Recovery for softReconnects that never finished: if the app died (crash, force-quit)
    /// between disabling a display and a successful re-enable, the markers softReconnect
    /// left behind name exactly the stranded displays. Called from
    /// DisplayManager.refreshDisplays; a cheap no-op unless a marker is set. Displays whose
    /// softReconnect is live right now are skipped per-UUID (their reconfig events fire
    /// refreshDisplays before the toggle finishes, and their retry loops must not be raced).
    /// Mirrors softReconnect's recovery ladder (3 re-enable tries, then the sweep), and
    /// clears each marker only once its display is verifiably back online or gone entirely,
    /// so a transient failure here leaves it set for the next refresh or launch to try
    /// again. Only ever re-enables marked displays directly, never any other disabled one
    /// (another app may have disabled those on purpose); the sweep it shares with
    /// softReconnect stays scoped to displays outside the intentional `disconnected` set
    /// and outside any live blink.
    func recoverStrandedSoftReconnect() async {
        // Also runs while only a parked guard is left (markers resolved by another path,
        // e.g. a later lid-open blink): the release at the bottom is its only way out.
        guard isSupported, !strandedRecoveryInFlight,
              !pendingSoftReconnectUUIDs().isEmpty || lingeringSleepGuard != nil
        else { return }
        strandedRecoveryInFlight = true
        defer { strandedRecoveryInFlight = false }
        for markedUUID in pendingSoftReconnectUUIDs() {
            // Re-checked per iteration: a blink can start for a marked display while an
            // earlier iteration was awaiting.
            guard !softReconnectInFlight.contains(markedUUID) else { continue }
            guard let targetID = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == markedUUID }) else {
                // Display gone entirely (unplugged while stranded): a physical replug brings
                // it back online by itself, so the marker has nothing left to do.
                removePendingSoftReconnect(markedUUID)
                continue
            }
            if onlineDisplayIDs().contains(targetID) {
                // Recovered normally (or a previous sweep already brought it back).
                removePendingSoftReconnect(markedUUID)
                continue
            }
            var recovered = false
            for _ in 0..<3 {
                // The API result alone is never trusted (see verifyBackOnline): a lying
                // "success" here is exactly how a clamshell-sleep interruption erased the
                // marker while the display stayed disabled.
                if case .success = await setEnabled(true, displayID: targetID),
                   await verifyBackOnline(uuid: markedUUID) {
                    recovered = true
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if !recovered { await reenableUnintentionallyDisabled() }
            // Clear only if the display verifiably came back; otherwise the marker stays set
            // and the addFlag/refresh cadence (or the next launch) retries.
            if recovered || onlineDisplayIDs().contains(targetID) {
                removePendingSoftReconnect(markedUUID)
            }
        }
        // A parked sleep guard has served its purpose once no marker remains unresolved:
        // every marked display is back online or gone. Until then it stays, keeping a
        // lid-closed portable awake for the next retry.
        if lingeringSleepGuard != nil, pendingSoftReconnectUUIDs().isEmpty {
            lingeringSleepGuard = nil
        }
    }

    /// Guards against overlapping restore attempts from reconfiguration-callback bursts.
    private var restoreInFlight = false

    /// Called on every display-list refresh. The guard in disconnect() can't stop a physical
    /// unplug: with the internal disabled via Crisp and the external cable pulled, zero active
    /// displays remain and macOS does NOT re-enable the disabled one, every screen stays black.
    /// Re-enable a still-attached disconnected display (built-in first) so the machine always
    /// has a live screen. The settle delay rides out transient empty display lists during
    /// wake/replug storms, so a monitor that comes right back keeps the disconnect intact.
    func restoreIfNoActiveDisplay() {
        guard isSupported, !disconnected.isEmpty else { return }
        // With records to act on, every stand-down is worth a line: a capture of a dark
        // desk otherwise cannot tell "never asked" from "asked and refused", and which guard
        // refused (issue #92: a dock pulled during sleep can keep its displays in the online
        // list until the link times out, and those count as active).
        let active = physicalActiveDisplayCount()
        guard !restoreInFlight, active == 0 else {
            Self.log.notice("restore asked with \(self.disconnected.count, privacy: .public) record(s): \(active, privacy: .public) active display(s), in flight \(self.restoreInFlight, privacy: .public), standing down")
            return
        }
        restoreInFlight = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            defer { self.restoreInFlight = false }
            let settled = self.physicalActiveDisplayCount()
            guard settled == 0 else {
                Self.log.notice("restore settled: \(settled, privacy: .public) active display(s) after 2 s, standing down")
                return
            }
            // This path acts with every screen black, so without a line here a capture
            // cannot tell a Crisp restore from macOS re-probing on its own (noted from
            // the outside in #91).
            Self.log.notice("no active display, restoring from \(self.disconnected.count, privacy: .public) record(s)")
            // In the placeholder-display state SLSGetDisplayList shrinks to just
            // the placeholder (verified live), so records that fail to resolve
            // must fall back to their last-known ID rather than being dropped:
            // SLSConfigureDisplayEnabled still honors a stale ID for attached
            // hardware, while detached hardware fails at
            // CGCompleteDisplayConfiguration (error 1001) and the loop moves on.
            // Prefer the built-in panel, from the flag captured at disconnect time
            // (see wasBuiltin): the IDs here are stale, so a live query is unreliable.
            let candidates = self.disconnected
                .map { record in (record, self.resolveCurrentID(for: record) ?? record.displayID) }
                .sorted { self.wasBuiltin($0.0, id: $0.1) && !self.wasBuiltin($1.0, id: $1.1) }
            for (record, _) in candidates {
                // macOS re-probes displays by itself in this state and often wins the race;
                // stop as soon as anything viewable is back, whoever brought it back.
                guard self.physicalActiveDisplayCount() == 0 else { return }
                guard case .success = await self.reconnect(uuid: record.uuid) else { continue }
                // A successful transaction is NOT proof of recovery (see verifyBackOnline):
                // around sleep transitions it reports success while the display stays
                // disabled, and that lie used to end the restore with every screen still
                // black. Only enumeration ends it; otherwise move on to the next record.
                for _ in 0..<20 {
                    if self.physicalActiveDisplayCount() > 0 { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    // MARK: - Persistence

    private func saveDesired() {
        guard let data = try? JSONEncoder().encode(disconnected) else { return }
        UserDefaults.standard.set(data, forKey: desiredKey)
    }

    private func loadDesired() {
        guard let data = UserDefaults.standard.data(forKey: desiredKey),
              let decoded = try? JSONDecoder().decode([DisconnectedDisplay].self, from: data)
        else { return }
        disconnected = decoded
        // Nothing is disconnected from here: the loaded list only populates the
        // "Disconnected" UI. The first display-list refresh after launch re-applies it
        // through reconcile(), which is where the safety rails are (it never takes the last
        // screen, and forgets any record it cannot honour). Wake goes through the same
        // path: the wake chain's refresh runs reconcile like any other.
    }
}
