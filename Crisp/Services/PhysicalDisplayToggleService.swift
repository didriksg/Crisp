import Foundation
import CoreGraphics
import ColorSync
import IOKit
import os.log

/// Disconnects / reconnects REAL (physical) displays via the private SkyLight API
/// `SLSConfigureDisplayEnabled`, the way BetterDisplay's "Disconnect Display" works.
/// Apple Silicon only (`isSupported`); on Intel the API doesn't perform a true disconnect.
/// A disabled display drops out of CGGetOnlineDisplayList/CGGetActiveDisplayList but still
/// enumerates via SLSGetDisplayList, so `disconnected` keeps its own snapshot for the UI.
/// See docs/display-notes.md (PhysicalDisplayToggleService).
@MainActor
final class PhysicalDisplayToggleService: ObservableObject {
    static let shared = PhysicalDisplayToggleService()
    private init() {
        loadDesired()
    }

    /// Set by DisplayManager at launch. The restore below needs a DisplayInfo to read and put
    /// back a display's HDR switch, and this service otherwise works from CGDirectDisplayIDs.
    weak var displayManager: DisplayManager?

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
        /// The 10s wrapper only stops waiting; it can't cancel CGCompleteDisplayConfiguration,
        /// so this is not proof the change didn't take.
        case timedOut

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
            case .timedOut:
                return String(localized: "Display configuration timed out.")
            }
        }
    }

    // MARK: - State

    /// Displays the user has disconnected and can reconnect. Persisted (by UUID) so wake and
    /// relaunch can restore the intended state.
    @Published private(set) var disconnected: [DisconnectedDisplay] = []

    private let desiredKey = "crisp.PhysicalDisconnectedUUIDs"
    /// Dead-man markers for displays softReconnect is (or was, if the app died) mid-toggle on.
    /// A list: two displays can blink at once. See softReconnect / recoverStrandedSoftReconnect.
    private let softReconnectPendingKey = "crisp.PhysicalDisplayToggleService.softReconnectPending"
    /// Displays whose softReconnect is mid-blink right now, so recovery and the disabled-display
    /// sweep don't re-enable one out from under its own retry loop.
    private var softReconnectInFlight: Set<String> = []
    /// UUIDs mid-reconnect right now. reconcile() must not read `disconnected` for these: a
    /// reconfig callback firing before setEnabled(true) returns would see the record still in
    /// place and switch the display straight back off.
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

    /// Every step here logs: issue #33 (a whole-machine freeze on reconnect) had only
    /// WindowServer's side of the story. See docs/display-notes.md (PhysicalDisplayToggleService).
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

    func isDisconnected(uuid: String) -> Bool {
        disconnected.contains { $0.uuid == uuid }
    }

    /// True if disconnecting `display` now would leave no *viewable* screen. Virtual displays
    /// don't count: a headless virtual left alone still blacks out the physical machine.
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

    /// Active physical (non-virtual) screens. Used by the Disconnect row and the launch
    /// re-apply; the blackout rescue uses phantomAwareActiveDisplayCount instead.
    private func physicalActiveDisplayCount() -> Int {
        viewableActiveDisplays().count
    }

    private func viewableActiveDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let virtual = VirtualDisplayService.shared
        return ids.prefix(Int(count)).filter { id in
            guard !virtual.isVirtualDisplay(id) else { return false }
            // Filters out entries with no real panel behind them (macOS's post-blackout
            // placeholder, or a re-enabled record whose hardware left). Issue #91.
            // See docs/display-notes.md (phantomAwareActiveDisplayCount).
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
            let hasNoPanel = vendor == 0 || model == 0 || vendor > 0xFFFF || model > 0xFFFF
            return !hasNoPanel
        }
    }

    /// physicalActiveDisplayCount with the #112 phantoms (stale post-wake externals) filtered
    /// by port presence. Read only by restoreIfNoActiveDisplay: a wrong answer here can only
    /// make the rescue fire, never hide a row or refuse a remembered disconnect.
    /// See docs/display-notes.md (phantomAwareActiveDisplayCount).
    private func phantomAwareActiveDisplayCount() -> Int {
        let viewable = viewableActiveDisplays()
        let externals = viewable.filter { CGDisplayIsBuiltin($0) != 1 }
        let portCap = liveDisplayPortCount()
        var onPort = externals.count
        if let portCap, portCap < externals.count {
            onPort = externals.filter { !Self.hasProductName($0) }.count
        }
        return PhantomPortCap.activeCount(offPort: viewable.count - onPort, onPort: onPort, portCap: portCap)
    }

    /// Whether CoreDisplay still knows the display by name; empty for a #112 phantom or a
    /// display WindowServer is mid-re-enumerating. See docs/display-notes.md
    /// (phantomAwareActiveDisplayCount).
    private static func hasProductName(_ id: CGDirectDisplayID) -> Bool {
        guard let info = _CoreDisplayCreateInfoDictionary?(id)?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        if let names = info["DisplayProductName"] as? [String: Any] {
            return names.values.contains { ($0 as? String)?.isEmpty == false }
        }
        return (info["DisplayProductName"] as? String)?.isEmpty == false
    }

    /// Ports that can have a display behind them right now (DisplayPort/Thunderbolt hot-plug
    /// detect or sink count). nil, not 0, when the machine exposes no such nodes: that means
    /// the signal is unavailable, not that nothing is plugged in.
    /// See docs/display-notes.md (liveDisplayPortCount).
    private func liveDisplayPortCount() -> Int? {
        var nodes = 0, asserted = 0
        for cls in ["IOPortTransportStateDisplayPort", "IOPortTransportStateCIO"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while case let node = IOIteratorNext(it), node != 0 {
                defer { IOObjectRelease(node) }
                nodes += 1
                let hpd = IORegistryEntryCreateCFProperty(node, "HPD_StateDescription" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                let sinks = IORegistryEntryCreateCFProperty(node, "SinkCount" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int ?? 0
                if hpd == "High" || sinks > 0 { asserted += 1 }
            }
        }
        return nodes == 0 ? nil : asserted
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
        let otherStates = currentStates(excluding: [displayID])
        let result = await setEnabled(false, displayID: displayID)
        if case .success = result {
            disconnected.removeAll { $0.uuid == snapshot.uuid }
            disconnected.append(snapshot)
            saveDesired()
            Task { [weak self] in await self?.restoreStates(otherStates) }
        }
        return result
    }

    /// What an arrangement decides for one display: its mode, its rotation, and whether it is
    /// in HDR. `hdr` is nil for a display that has no HDR switch to put back.
    struct DisplayState {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        let rotation: Double
        let hdr: Bool?
    }

    /// Every online display's mode/rotation/HDR except the ones about to be taken off, so
    /// they can be restored after WindowServer re-applies its per-arrangement state (issue
    /// #108). See docs/display-notes.md (restoreStates).
    private func currentStates(excluding displayIDs: Set<CGDirectDisplayID> = []) -> [DisplayState] {
        onlineDisplayIDs().filter { !displayIDs.contains($0) }.compactMap { id in
            CGDisplayCopyDisplayMode(id).map {
                DisplayState(id: id, mode: $0, rotation: CGDisplayRotation(id), hdr: liveHDR(id))
            }
        }
    }

    /// The HDR switch as it stands, or nil if this display has none. Read through
    /// DisplayManager for the DisplayInfo the HDR API needs.
    private func liveHDR(_ displayID: CGDirectDisplayID) -> Bool? {
        guard let display = displayManager?.displays.first(where: { $0.displayID == displayID }),
              BrightnessBoostService.shared.isEligibleForHDRToggle(display) else { return nil }
        return BrightnessBoostService.shared.isHDREnabled(for: display)
    }

    private func restoreStates(_ states: [DisplayState]) async {
        // A mirror target's mode is driven by its source (see ResolutionService).
        let moved = {
            states.filter { state in
                guard self.onlineDisplayIDs().contains(state.id),
                      !MirroredModeService.shared.isActive(for: state.id) else { return false }
                if let current = CGDisplayCopyDisplayMode(state.id),
                   current.ioDisplayModeID != state.mode.ioDisplayModeID { return true }
                if CGDisplayRotation(state.id) != state.rotation { return true }
                if let hdr = state.hdr, self.liveHDR(state.id) != hdr { return true }
                return false
            }
        }
        // Poll for the re-arrangement (lands ~1s after commit) instead of a fixed sleep, so
        // the user-visible flip stays short.
        var changed = moved()
        for _ in 0..<30 where changed.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
            changed = moved()
        }
        guard !changed.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for state in moved() {
            let id = state.id
            if let current = CGDisplayCopyDisplayMode(id),
               current.ioDisplayModeID != state.mode.ioDisplayModeID {
                let restored = await ResolutionService.applyModeSync(state.mode, on: id)
                Self.log.notice("display \(id, privacy: .public) moved to \(current.width, privacy: .public)x\(current.height, privacy: .public) after the disconnect, restoring \(state.mode.width, privacy: .public)x\(state.mode.height, privacy: .public) @\(Int(state.mode.refreshRate), privacy: .public): \(restored ? "ok" : "failed", privacy: .public)")
            }
            let rotation = CGDisplayRotation(id)
            if rotation != state.rotation {
                let err = SLSSetDisplayRotation(id, Int32(state.rotation))
                Self.log.notice("display \(id, privacy: .public) turned to \(Int(rotation), privacy: .public) degrees after the disconnect, restoring \(Int(state.rotation), privacy: .public): \(err == .success ? "ok" : "failed", privacy: .public)")
            }
            if let hdr = state.hdr, liveHDR(id) != hdr,
               let display = displayManager?.displays.first(where: { $0.displayID == id }) {
                let restored = await BrightnessBoostService.shared.setHDRPreference(hdr, for: display)
                Self.log.notice("display \(id, privacy: .public) switched \(hdr ? "out of" : "into", privacy: .public) HDR after the disconnect, restoring: \(restored ? "ok" : "failed", privacy: .public)")
            }
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
            // Not proof of recovery (see verifyBackOnline); record drops either way, since
            // keeping it would have reconcile switch the display back off the moment it appears.
            if !(await verifyBackOnline(uuid: uuid, timeout: 2.0)) {
                Self.log.notice("reconnect of \(uuid, privacy: .public) reported success but the display is not back online after 2 s, record dropped")
            }
            disconnected.removeAll { $0.uuid == uuid }
            saveDesired()
        }
        return result
    }

    /// Prefers the flag captured at disconnect time: in the all-black state, SLSGetDisplayList
    /// has collapsed to a placeholder and CGDisplayIsBuiltin answers garbage for stale IDs.
    private func wasBuiltin(_ record: DisconnectedDisplay, id: CGDirectDisplayID) -> Bool {
        record.isBuiltin ?? (CGDisplayIsBuiltin(id) == 1)
    }

    /// Finds the current CGDirectDisplayID for a disconnected record by matching its UUID
    /// across the full (incl. disabled) display list.
    private func resolveCurrentID(for record: DisconnectedDisplay) -> CGDirectDisplayID? {
        allDisplaysIncludingDisabled().first { uuid(for: $0) == record.uuid }
    }

    /// Disables then re-enables a display's framebuffer to force macOS to re-read a freshly
    /// written HiDPI override and re-enumerate modes, without a physical unplug. Leaves
    /// `disconnected` untouched (a re-enumeration blip, not a user disconnect); blinks even
    /// the sole active display, using a throwaway virtual display to block Clamshell Sleep on
    /// portables. See docs/display-notes.md (softReconnect).
    @discardableResult
    func softReconnect(_ display: DisplayInfo) async -> Bool {
        guard isSupported else { return false }
        let blinkUUID = display.displayUUID
        // Two callers can race the same display; a fixed virtual-display identity can't be
        // created twice, so the first blink wins and the rest adopt its result.
        guard !softReconnectInFlight.contains(blinkUUID) else { return false }
        let startID = display.displayID
        // Captured before the sleep guard exists: re-enumeration can land on macOS's default
        // mode, and the guard's own arrival can itself knock the panel to a lower refresh rate.
        let previousMode = CGDisplayCopyDisplayMode(startID)
        // A lid-closed portable sleeps the instant its sole active display goes away, even
        // under a PreventSystemSleep assertion; a live virtual display blocks it. Desktops and
        // lid-open laptops never need the guard. See docs/display-notes.md (softReconnect).
        var sleepGuard: CGVirtualDisplay?
        if Self.hasBattery && wouldLeaveNoActiveDisplay(startID) {
            // Reuse a guard parked by a previous unresolved blink; the fixed identity can't exist twice.
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
        // Persisted before disabling: if the app dies mid-toggle, recoverStrandedSoftReconnect
        // finds this at the next launch and finishes the job.
        addPendingSoftReconnect(blinkUUID)
        guard case .success = await setEnabled(false, displayID: startID) else {
            removePendingSoftReconnect(blinkUUID)
            return false
        }
        // Wait for the framebuffer to actually drop before re-enabling (0.9s ceiling if the event never comes).
        await ReconfigEvents.shared.next(for: startID, matching: .removeFlag, timeout: 0.9)
        var backOnline = false
        for _ in 0..<3 {
            let targetID = allDisplaysIncludingDisabled().first { uuid(for: $0) == blinkUUID } ?? startID
            // Fired without awaiting: the result is untrustworthy either way (see
            // verifyBackOnline), and the commit can block ~10s after the display is actually
            // back. Enumeration is the only proof. See docs/display-notes.md (softReconnect).
            Task { _ = await setEnabled(true, displayID: targetID) }
            // Must outlast a display link handshake (2-4s), or re-issuing enable mid-sync restarts it.
            if await verifyBackOnline(uuid: blinkUUID, timeout: 4.0) { backOnline = true; break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !backOnline {
            // Don't leave a display our own disable may have stranded; drop the in-flight claim
            // first so the sweep below doesn't skip the very display it's here to rescue.
            softReconnectInFlight.remove(blinkUUID)
            await reenableUnintentionallyDisabled()
            // One more look before declaring failure: slow re-enumeration must still land in
            // the success path below (mode restore, guard release timing).
            backOnline = await verifyBackOnline(uuid: blinkUUID, timeout: 2.0)
        }
        guard backOnline else {
            // Marker stays so refresh/relaunch keeps retrying; the sleep guard is parked
            // (not released) or a lid-closed portable would sleep with the display stranded.
            if sleepGuard != nil { lingeringSleepGuard = sleepGuard }
            return false
        }
        removePendingSoftReconnect(blinkUUID)
        if let previousMode,
           let backID = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == blinkUUID }) {
            // Re-enumeration renumbers every mode ID, so the captured mode can't be re-applied
            // directly; re-find its equivalent by parameters. No match means it no longer
            // enumerates (e.g. smooth scaling was toggled off); macOS's fallback stands.
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(backID, options) as? [CGDisplayMode] ?? []
            if let target = modes.first(where: {
                $0.width == previousMode.width && $0.height == previousMode.height
                    && $0.pixelWidth == previousMode.pixelWidth
                    && $0.pixelHeight == previousMode.pixelHeight
                    && abs($0.refreshRate - previousMode.refreshRate) < 1
            }) {
                // A set issued mid-retrain can fail silently; verify and retry briefly.
                for _ in 0..<4 {
                    if CGDisplayCopyDisplayMode(backID)?.ioDisplayModeID == target.ioDisplayModeID { break }
                    _ = await ResolutionService.applyModeSync(target, on: backID)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        return true
    }

    /// Runs SLSConfigureDisplayEnabled inside a CG transaction with `.permanently` (matching
    /// Lunar BlackOut, screen_tune, BetterDisplay), which is what makes the disconnect stick.
    private func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) async -> Result<Void, ToggleError> {
        let action = enabled ? "enable" : "disable"
        let waited = DispatchTime.now()
        // No DDC traffic while this transaction runs: WindowServer's enable can wait behind an
        // in-flight I2C read and freeze the whole machine with it (issue #33).
        // See docs/display-notes.md (PhysicalDisplayToggleService).
        let releaseDDC = await DDCService.shared.hold()
        defer { releaseDDC() }
        let heldMs = Self.millisSince(waited)
        if heldMs > Self.slowOpThresholdMs {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): waited \(Int(heldMs), privacy: .public) ms for DDC to go idle")
        }
        let result: Result<Void, ToggleError> = await CGHelpers.runWithTimeout(
            seconds: 10, fallback: .failure(.timedOut)
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
            // The call that can block: keeps running after the 10s wrapper gives up (it can
            // only stop waiting, not cancel), and WindowServer holding it can stall the whole
            // machine, not just Crisp (issue #33). Timed unconditionally for captures.
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
        // Not the same as what WindowServer will actually do: on a wrapper timeout this
        // reports failure at ~10000ms while the commit keeps running.
        let waitedMs = Self.millisSince(waited)
        if case .failure = result {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): reported failure after \(Int(waitedMs), privacy: .public) ms")
        } else {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): reported success after \(Int(waitedMs), privacy: .public) ms")
        }
        return result
    }

    /// Safety net for softReconnect's re-enable retries all failing: sweeps every SLS-disabled
    /// display Crisp didn't disconnect on purpose, so a transient failure can't leave a screen
    /// stuck black. Leaves other apps' intentional disables alone.
    private func reenableUnintentionallyDisabled() async {
        let onlineSet = onlineDisplayIDs()
        let intentionalUUIDs = Set(disconnected.map { $0.uuid })
        for id in allDisplaysIncludingDisabled() where !onlineSet.contains(id) {
            let displayUUID = uuid(for: id)
            guard !intentionalUUIDs.contains(displayUUID) else { continue }
            // A display mid-blink is off on purpose; racing it here would fight its own retry loop.
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

    /// True once the display is back in the online list. A successful setEnabled transaction
    /// is NOT proof: around sleep transitions it reports success while still disabled
    /// (verified live). Only enumeration counts.
    private func verifyBackOnline(uuid displayUUID: String, timeout: TimeInterval = 1.0) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if let id = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == displayUUID }),
               onlineDisplayIDs().contains(id) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// The disable half of verifyBackOnline, untrustworthy the same way: the transaction
    /// reports what was asked, not what took.
    private func verifyOffline(displayID: CGDirectDisplayID, timeout: TimeInterval) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if !onlineDisplayIDs().contains(displayID) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Battery presence is the lid-independent laptop test for Clamshell Sleep: the built-in
    /// panel can vanish from the display list entirely while the lid is closed.
    private static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()

    /// Throwaway virtual display held while blinking a portable's sole active display, to
    /// block Clamshell Sleep (see softReconnect). Fixed product/serial so macOS doesn't
    /// re-prompt "what to show" on every blink. nil unless it verifiably comes online.
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

    /// Re-applies a remembered disconnect once its display is back online (reboot, replug, or
    /// macOS re-enabling it) so it doesn't have to be redone by hand every boot (issue #93);
    /// drops the record if it can't take, so the list never claims a lit display is
    /// disconnected. See docs/display-notes.md (reconcile).
    func reconcile() {
        guard !disconnected.isEmpty else { return }
        let onlineIDs = onlineDisplayIDs()
        let onlineUUIDs = Set(onlineIDs.map { uuid(for: $0) })
        let resurfaced = disconnected.filter { onlineUUIDs.contains($0.uuid) }
        guard !resurfaced.isEmpty else {
            // Baseline for restoreStates: a resolution picked in between is what goes back, not a stale one.
            baselineModes = currentStates()
            return
        }
        // Intel has no working disconnect to re-apply; forget the record and keep the UI honest.
        guard isSupported else {
            disconnected.removeAll { onlineUUIDs.contains($0.uuid) }
            saveDesired()
            return
        }
        // A live blink or reconnect is already putting this display back online on purpose.
        let pending = resurfaced.filter {
            !reapplyInFlight.contains($0.uuid)
                && !softReconnectInFlight.contains($0.uuid)
                && !reconnectInFlight.contains($0.uuid)
        }
        guard !pending.isEmpty else { return }
        let leaving = Set(onlineIDs.filter { id in
            let displayUUID = uuid(for: id)
            return pending.contains { $0.uuid == displayUUID }
        })
        pendingPassModes = (baselineModes.isEmpty ? currentStates() : baselineModes)
            .filter { !leaving.contains($0.id) }
        for record in pending {
            reapplyInFlight.insert(record.uuid)
            Task { [weak self] in
                guard let self else { return }
                await self.reapplyRemembered(record.uuid)
                self.reapplyInFlight.remove(record.uuid)
            }
        }
    }

    /// Displays whose remembered disconnect is mid-reapply, so a reconfiguration burst can't
    /// stack a second attempt on the same display.
    private var reapplyInFlight: Set<String> = []

    /// The other displays' modes as of the last refresh with no remembered display online:
    /// the arrangement WindowServer puts back once the remembered display goes off again.
    /// Must be captured before the reapply, not live inside it (measured, not reasoned: #101).
    /// See docs/display-notes.md (restoreStates).
    private var baselineModes: [DisplayState] = []

    /// One restore snapshot per reconcile pass, not one per record (two records each taking
    /// their own landed the same restore twice, 19ms apart).
    private var pendingPassModes: [DisplayState]?

    /// Starts this pass's one restore, once a disable has actually moved things (restoreStates'
    /// window is finite).
    private func startPassRestoreIfNeeded() {
        guard let states = pendingPassModes else { return }
        pendingPassModes = nil
        Task { [weak self] in await self?.restoreStates(states) }
    }

    /// One display's half of reconcile: put it back the way the user left it, or forget it.
    private func reapplyRemembered(_ recordUUID: String) async {
        guard !reconnectInFlight.contains(recordUUID) else { return }
        guard let liveID = onlineDisplayIDs().first(where: { uuid(for: $0) == recordUUID })
        else { return }  // gone again by itself; the record still stands for next time
        let refused = wouldLeaveNoActiveDisplay(liveID)
        Self.log.notice("remembered disconnect for \(recordUUID, privacy: .public) id \(liveID, privacy: .public): \(refused ? "refused, it is the last active display" : "re-applying", privacy: .public)")
        var stillOnline = true
        var timedOut = false
        if !refused {
            // Same arrangement-move risk as disconnect() (#108); restore targets the modes
            // from before the display resurfaced (baselineModes), not the ones its own enable produced.
            if case .failure(.timedOut) = await setEnabled(false, displayID: liveID) {
                timedOut = true
            }
            // Started before the verify below (which can hold for seconds) so the visible flip
            // stays short; a no-op if nothing actually moved.
            startPassRestoreIfNeeded()
            // Settled by enumeration, not the transaction's result (see verifyBackOnline). 4s
            // window matches softReconnect's, for the same display-link-handshake reason.
            stillOnline = !(await verifyOffline(displayID: liveID, timeout: 4.0))
            if stillOnline {
                // Confirmed with a second, longer look before letting the record go: #33 had
                // WindowServer hold a commit for 29.5s after a reported failure.
                stillOnline = !(await verifyOffline(displayID: liveID, timeout: 2.0))
            }
        }
        guard let idx = disconnected.firstIndex(where: { $0.uuid == recordUUID }) else { return }
        if stillOnline, !timedOut, onlineDisplayIDs().contains(liveID) {
            // Still lit: forget the record, so the list never claims a display is disconnected
            // while the user is looking at it. Exception: after a timeout (not evidence the
            // change failed, see ToggleError.timedOut) the record stays for the next refresh to
            // decide, since #33 shows a commit can still land 29.5s later.
            Self.log.notice("record dropped for \(recordUUID, privacy: .public) id \(liveID, privacy: .public): still lit")
            disconnected.remove(at: idx)
        } else {
            // Off (regardless of what the transaction reported) is decided the same way:
            // dropping the record here would strand the display with no way back through the UI.
            disconnected[idx].displayID = liveID
        }
        saveDesired()
    }

    /// Guards against overlapping recovery runs from reconfiguration-callback bursts, same
    /// as restoreInFlight below for restoreIfNoActiveDisplay.
    private var strandedRecoveryInFlight = false

    /// Sleep guard parked by a softReconnect whose display never verifiably returned, keeping a
    /// lid-closed portable awake so recovery can keep retrying. Released once every marked
    /// display resolves, or adopted by the next blink.
    private var lingeringSleepGuard: CGVirtualDisplay?

    /// Recovery for a softReconnect the app died mid-toggle on (crash, force-quit): the
    /// dead-man markers name exactly the stranded displays. Cheap no-op unless a marker is
    /// set; skips any display whose blink is live right now. See docs/display-notes.md
    /// (softReconnect).
    func recoverStrandedSoftReconnect() async {
        // Also runs with only a parked guard left; the release at the bottom is its only way out.
        guard isSupported, !strandedRecoveryInFlight,
              !pendingSoftReconnectUUIDs().isEmpty || lingeringSleepGuard != nil
        else { return }
        strandedRecoveryInFlight = true
        defer { strandedRecoveryInFlight = false }
        for markedUUID in pendingSoftReconnectUUIDs() {
            // Re-checked per iteration: a blink can start for this display while we're awaiting.
            guard !softReconnectInFlight.contains(markedUUID) else { continue }
            guard let targetID = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == markedUUID }) else {
                // Gone entirely: a physical replug brings it back on its own.
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
                // Never trust the API result alone (see verifyBackOnline): a lying "success" is
                // exactly how a clamshell-sleep interruption erased a marker while still disabled.
                if case .success = await setEnabled(true, displayID: targetID),
                   await verifyBackOnline(uuid: markedUUID) {
                    recovered = true
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if !recovered { await reenableUnintentionallyDisabled() }
            // Cleared only if verifiably back; otherwise the marker stays for the next retry.
            if recovered || onlineDisplayIDs().contains(targetID) {
                removePendingSoftReconnect(markedUUID)
            }
        }
        // Released once no marker remains: every marked display is back online or gone.
        if lingeringSleepGuard != nil, pendingSoftReconnectUUIDs().isEmpty {
            lingeringSleepGuard = nil
        }
    }

    /// Re-poll count/interval before committing to a restore: the count is per-process and can
    /// trail reality by up to ~150ms (issue #117), so a single sample is unreliable.
    /// See docs/display-notes.md (restoreIfNoActiveDisplay).
    private static let settleRepolls = 10
    private static let settleRepollInterval: UInt64 = 100_000_000

    /// Guards against overlapping restore attempts from reconfiguration-callback bursts.
    private var restoreInFlight = false

    /// The blackout rescue: a physical unplug bypasses disconnect()'s last-screen guard
    /// entirely (built-in disabled via Crisp + cable pulled = zero active, and macOS won't
    /// re-enable it), so this brings back a still-attached disconnected display, built-in
    /// first. Grew a layer per desk shape (#91, #99, #106, #117, #112).
    /// See docs/display-notes.md (restoreIfNoActiveDisplay).
    func restoreIfNoActiveDisplay() {
        guard isSupported, !disconnected.isEmpty else { return }
        // Every stand-down is logged: a dark-desk capture otherwise can't tell "never asked"
        // from "asked and refused" (issue #92).
        let active = phantomAwareActiveDisplayCount()
        guard !restoreInFlight, active == 0 else {
            Self.log.notice("restore asked with \(self.disconnected.count, privacy: .public) record(s): \(active, privacy: .public) active display(s), in flight \(self.restoreInFlight, privacy: .public), standing down")
            return
        }
        restoreInFlight = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            defer { self.restoreInFlight = false }
            // One sample isn't enough: the count can trail reality by up to ~150ms (issue #117).
            // Re-polled (not watched) since the count during a display sleep isn't reliable
            // either. See docs/display-notes.md (restoreIfNoActiveDisplay).
            var settled = self.phantomAwareActiveDisplayCount()
            var repolls = 0
            while settled == 0, repolls < Self.settleRepolls {
                try? await Task.sleep(nanoseconds: Self.settleRepollInterval)
                guard !Task.isCancelled else { return }
                settled = self.phantomAwareActiveDisplayCount()
                repolls += 1
            }
            guard settled == 0 else {
                Self.log.notice("restore settled: \(settled, privacy: .public) active display(s) after 2 s and \(repolls, privacy: .public) re-poll(s), standing down")
                return
            }
            // Logged because every screen is black here: distinguishes a Crisp restore from
            // macOS re-probing on its own (#91).
            Self.log.notice("no active display, restoring from \(self.disconnected.count, privacy: .public) record(s)")
            // Records that fail to re-resolve fall back to their last-known ID rather than
            // being dropped: SLSConfigureDisplayEnabled still honors a stale ID for attached
            // hardware in this state. Built-in tried first (flag from disconnect time; a live
            // query is unreliable here).
            let candidates = self.disconnected
                .map { record in (record, self.resolveCurrentID(for: record) ?? record.displayID) }
                .sorted { self.wasBuiltin($0.0, id: $0.1) && !self.wasBuiltin($1.0, id: $1.1) }
            for (record, _) in candidates {
                // macOS re-probes on its own and often wins the race; stop as soon as anything's back.
                guard self.phantomAwareActiveDisplayCount() == 0 else { return }
                guard case .success = await self.reconnect(uuid: record.uuid) else { continue }
                // Not proof of recovery (see verifyBackOnline): only enumeration ends the
                // restore; otherwise move to the next record.
                for _ in 0..<20 {
                    if self.phantomAwareActiveDisplayCount() > 0 { return }
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
        // Nothing is disconnected yet; this only seeds the "Disconnected" UI. The first
        // refresh after launch re-applies it through reconcile(), where the safety rails are.
    }
}
