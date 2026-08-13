import Foundation
import CoreGraphics
import ColorSync

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
    /// untouched: this is a re-enumeration blip, not a user-visible disconnect. Refuses (false)
    /// if it would leave no active display, or on Intel.
    @discardableResult
    func softReconnect(_ display: DisplayInfo) async -> Bool {
        guard isSupported else { return false }
        let startID = display.displayID
        guard !wouldLeaveNoActiveDisplay(startID) else { return false }
        guard case .success = await setEnabled(false, displayID: startID) else { return false }
        // Wait for the framebuffer to actually drop (removeFlag) before re-enabling;
        // the 0.9s ceiling matches the old fixed sleep if the event never comes.
        await ReconfigEvents.shared.next(for: startID, matching: .removeFlag, timeout: 0.9)
        for _ in 0..<3 {
            let targetID = allDisplaysIncludingDisabled().first { uuid(for: $0) == display.displayUUID } ?? startID
            if case .success = await setEnabled(true, displayID: targetID) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
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

    // MARK: - Reconcile / Wake restore

    /// Drops records for displays that are back online (e.g. physically re-plugged, or macOS
    /// re-enabled them). Called from DisplayManager.refreshDisplays so the UI stays honest.
    func reconcile() {
        guard !disconnected.isEmpty else { return }
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)
        let onlineUUIDs = Set(onlineIDs.prefix(Int(onlineCount)).map { uuid(for: $0) })

        let before = disconnected.count
        disconnected.removeAll { onlineUUIDs.contains($0.uuid) }
        if disconnected.count != before { saveDesired() }
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

    /// Re-applies disconnect for displays macOS re-enabled after wake-from-sleep. Called from
    /// AppDelegate.onWake after WindowServer settles.
    func reapplyOnWake() async {
        guard isSupported, !disconnected.isEmpty else { return }
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)
        let onlineByUUID = Dictionary(uniqueKeysWithValues:
            onlineIDs.prefix(Int(onlineCount)).map { (uuid(for: $0), $0) })

        for record in disconnected {
            // Only re-disconnect ones macOS brought back online, and never the last screen.
            guard let liveID = onlineByUUID[record.uuid] else { continue }
            guard !wouldLeaveNoActiveDisplay(liveID) else { continue }
            _ = await setEnabled(false, displayID: liveID)
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
        // By design we do NOT auto-disconnect on launch, restarting the app must never
        // black out a screen on its own. The loaded list only populates the "Disconnected"
        // UI so the user can reconnect (or ignore) at their choice. Only the sleep/wake path
        // re-applies disconnect, via reapplyOnWake().
    }
}
