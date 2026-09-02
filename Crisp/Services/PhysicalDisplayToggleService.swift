import Foundation
import CoreGraphics
import ColorSync
import IOKit

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
            // Once the last real display is gone macOS spawns a placeholder
            // display (vendor 'unkn' 0x756E6B6E, model 'virt' 0x76697274,
            // fingerprinted live on macOS 26). It is not a viewable screen, and
            // counting it kept restoreIfNoActiveDisplay from ever firing in the
            // all-screens-black state it exists to fix.
            let isPlaceholder = CGDisplayVendorNumber(id) == 0x756E6B6E
                && CGDisplayModelNumber(id) == 0x76697274
            return !isPlaceholder
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
            height: display.pixelHeight
        )

        let result = await setEnabled(false, displayID: displayID)
        if case .success = result {
            disconnected.removeAll { $0.uuid == snapshot.uuid }
            disconnected.append(snapshot)
            saveDesired()
        }
        return result
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
        reconnectInFlight.insert(uuid)
        defer { reconnectInFlight.remove(uuid) }
        let result = await setEnabled(true, displayID: targetID)
        if case .success = result {
            disconnected.removeAll { $0.uuid == uuid }
            saveDesired()
        }
        return result
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
        await CGHelpers.runWithTimeout(seconds: 10, fallback: .failure(.configurationFailed(.failure))) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
                return .failure(.configurationFailed(.failure))
            }
            let setErr = SLSConfigureDisplayEnabled(cfg, displayID, enabled)
            guard setErr == .success else {
                CGCancelDisplayConfiguration(cfg)
                return .failure(.configurationFailed(setErr))
            }
            let complete = CGCompleteDisplayConfiguration(cfg, .permanently)
            guard complete == .success else {
                CGCancelDisplayConfiguration(cfg)
                return .failure(.configurationFailed(complete))
            }
            return .success(())
        }
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
        if !wouldLeaveNoActiveDisplay(liveID) {
            _ = await setEnabled(false, displayID: liveID)
            // The API's own answer is not proof, in either direction (see verifyBackOnline),
            // so the record's fate is settled by enumeration below, not by the result.
            for _ in 0..<10 {
                if !onlineDisplayIDs().contains(liveID) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard let idx = disconnected.firstIndex(where: { $0.uuid == recordUUID }) else { return }
        if onlineDisplayIDs().contains(liveID) {
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
        guard isSupported, !disconnected.isEmpty, !restoreInFlight else { return }
        guard physicalActiveDisplayCount() == 0 else { return }
        restoreInFlight = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            defer { self.restoreInFlight = false }
            guard self.physicalActiveDisplayCount() == 0 else { return }
            // In the placeholder-display state SLSGetDisplayList shrinks to just
            // the placeholder (verified live), so records that fail to resolve
            // must fall back to their last-known ID rather than being dropped:
            // SLSConfigureDisplayEnabled still honors a stale ID for attached
            // hardware, while detached hardware fails at
            // CGCompleteDisplayConfiguration (error 1001) and the loop moves on.
            // Prefer the built-in panel when the ID still classifies; stale IDs
            // answer CGDisplayIsBuiltin with garbage, which sorts as non-builtin.
            let candidates = self.disconnected
                .map { record in (record, self.resolveCurrentID(for: record) ?? record.displayID) }
                .sorted { CGDisplayIsBuiltin($0.1) == 1 && CGDisplayIsBuiltin($1.1) != 1 }
            for (record, _) in candidates {
                if case .success = await self.reconnect(uuid: record.uuid) { return }
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
