import CoreGraphics
import Foundation
// CGVirtualDisplay and CGVirtualDisplaySettings are ObjC objects without Sendable
// conformance, but we only use them sequentially (create on main → pass to background
// for apply → use result on main), so @unchecked Sendable is safe here.
extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

/// Manages virtual display configurations and creates CGVirtualDisplay instances
/// using the private CGVirtualDisplay API declared in the bridging header.
@MainActor
final class VirtualDisplayService: ObservableObject, @unchecked Sendable {
    static let shared = VirtualDisplayService()
    private init() {
        loadConfigs()
    }

    // MARK: - Config Model

    typealias VirtualDisplayConfig = CrispControlVirtualDisplayConfig

    // MARK: - State

    @Published var configs: [VirtualDisplayConfig] = []

    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects; releasing an entry destroys it.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]

    private var creationGate = VirtualDisplayCreationGate()
    /// A timed-out CLI release still needs offline read-back on a later disable.
    private var pendingRemovals: [UUID: CGDirectDisplayID] = [:]
    private var enableRequests: [UUID: Bool] = [:]
    private var lastErrors: [UUID: String] = [:]

    private let configsKey = "crisp.VirtualDisplayConfigs"

    /// Vendor ID stamped on every Crisp virtual display's descriptor, and the race-free
    /// signature filtered on: CGDisplayVendorNumber reports it the instant the display is online.
    static let crispVirtualVendorID: UInt32 = 0xEEEE

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        // Vendor ID first: it's live the instant the display is online, so a freshly created
        // one is filtered on the first refresh. The object set below is a backstop.
        if CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID { return true }
        return activeDisplayObjects.values.contains { $0.displayID == displayID }
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the config. Descriptor build and CGVirtualDisplay init
    /// run on the main actor (the API requires it); only `apply` runs off-main, since it can
    /// block on WindowServer IPC. See docs/display-notes.md (VirtualDisplayService.create).
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        switch creationGate.begin(config.id, retained: activeDisplayObjects[config.id] != nil) {
        case .inProgress: return false
        case .retained:
            enableRequests[config.id] = true
            return controlSnapshot(config, online: onlineDisplayIDs()).ready
        case .create: break
        }
        defer { creationGate.finish(config.id) }
        return await createReserved(config)
    }

    /// The caller holds the config's reservation, including any preceding teardown.
    private func createReserved(_ config: VirtualDisplayConfig) async -> Bool {
        enableRequests[config.id] = true
        lastErrors.removeValue(forKey: config.id)
        guard creationPreflight(config) else { return false }

        // Registration pops macOS's own "what to show" picker, which steals key focus and
        // would trip the panel's auto-dismiss; harmless at launch since the panel isn't open then.
        PanelOpenGuard.suppressAutoDismiss = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PanelOpenGuard.suppressAutoDismiss = false
            }
        }

        let w = config.width
        let h = config.height
        let hiDPI = config.hiDPI

        // CGVirtualDisplay(descriptor:) requires the main thread (returns nil off it).
        let descriptor = CGVirtualDisplayDescriptor()
        // Size from a fixed PPI so macOS defaults to the native resolution instead of a
        // scaled Retina mode. See docs/display-notes.md (VirtualDisplayService.create).
        let ppi: Double = 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(w) / ppi * 25.4,
            height: Double(h) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = config.name.isEmpty ? String(localized: "Crisp Virtual") : config.name
        descriptor.vendorID = Self.crispVirtualVendorID  // must be non-zero or init returns nil
        // Must be unique per config AND stable across recreations (macOS keys per-display
        // settings, including "what to show", on this identity). Both halves from the config UUID.
        descriptor.productID = config.productID
        descriptor.serialNum = config.serialNumber
        // DO NOT set queue or color primaries: not needed, and may interfere with creation.

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            lastErrors[config.id] = "CGVirtualDisplay creation failed"
            return false
        }
        // Retain before apply: the background call can outlive its bounded wait.
        activeDisplayObjects[config.id] = virtualDisplay
        pendingRemovals.removeValue(forKey: config.id)
        activeConfigIDs.insert(config.id)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI

        var modes: [CGVirtualDisplayMode] = []
        let refreshRates: [Double] = [75.0, 60.0, 50.0]
        for rate in refreshRates {
            modes.append(CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: rate))
        }
        if hiDPI {
            let hw = w / 2, hh = h / 2
            if hw >= 1, hh >= 1 {
                for rate in refreshRates {
                    modes.append(CGVirtualDisplayMode(width: UInt(hw), height: UInt(hh), refreshRate: rate))
                }
            }
            let qw = w / 4, qh = h / 4
            if qw >= 1, qh >= 1 {
                for rate in refreshRates {
                    modes.append(CGVirtualDisplayMode(width: UInt(qw), height: UInt(qh), refreshRate: rate))
                }
            }
        }
        settings.modes = modes

        // Blocks on WindowServer IPC.
        let vd = virtualDisplay
        let s = settings
        creationGate.beginApply(config.id)
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            let applied = vd.apply(s)
            Task { @MainActor in self.creationGate.finishApply(config.id) }
            return applied
        }
        if applyResult { creationGate.finishApply(config.id) }
        guard applyResult, virtualDisplay.displayID != kCGNullDirectDisplay else {
            lastErrors[config.id] = "settings apply failed or timed out; WindowServer outcome may still change"
            return false
        }

        // macOS auto-adds a scaled looks-like-1080p default for high-resolution displays
        // regardless of the modes supplied; force native 1x so it reads as its real resolution.
        await applyNativeResolution(virtualDisplay.displayID, width: w, height: h)
        for _ in 0..<10 {
            let snapshot = controlSnapshot(config, online: onlineDisplayIDs())
            if snapshot.active, snapshot.resolution != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        lastErrors[config.id] = "display retained but active enumeration did not settle"
        return false
    }

    private func creationPreflight(_ config: VirtualDisplayConfig) -> Bool {
        guard config.isValid else {
            lastErrors[config.id] = "invalid saved configuration"
            return false
        }
        guard let online = onlineDisplayIDs() else {
            lastErrors[config.id] = "online display enumeration failed"
            return false
        }
        guard !configs.contains(where: {
            $0.id != config.id && $0.productID == config.productID && $0.serialNumber == config.serialNumber
        }) else {
            lastErrors[config.id] = "descriptor identity collides with another saved config"
            return false
        }
        guard !online.contains(where: {
            matchesIdentity($0, config: config)
        }) else {
            lastErrors[config.id] = "matching descriptor identity is online but is not owned by this session"
            return false
        }

        return true
    }

    /// macOS assigns its auto-scaled default asynchronously, so this retries briefly until
    /// the native 1x mode sticks, or gives up.
    private func applyNativeResolution(_ displayID: CGDirectDisplayID, width: Int, height: Int) async {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for attempt in 0..<5 {
            if attempt > 0 {
                await ReconfigEvents.shared.next(for: displayID, matching: .setModeFlag, timeout: 0.3)
            }
            if let cur = CGDisplayCopyDisplayMode(displayID),
               cur.width == width, cur.pixelWidth == width { return }
            guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
                  let native = modes.first(where: {
                      $0.pixelWidth == width && $0.pixelHeight == height && $0.width == width
                  }) ?? modes.first(where: { $0.pixelWidth == width && $0.pixelHeight == height })
            else { continue }
            _ = await ResolutionService.applyModeSync(native, on: displayID)
        }
    }

    func destroyAll() {
        for uuid in activeConfigIDs {
            activeDisplayObjects.removeValue(forKey: uuid)
        }
        activeConfigIDs.removeAll()
    }

    @discardableResult
    func destroy(configID: UUID) -> Bool {
        guard !creationGate.isBusy(configID), !HeadlessDisplayService.shared.usesVirtual(configID) else { return false }
        return release(configID: configID)
    }

    /// The caller either checked or holds the config's reservation.
    @discardableResult
    private func release(configID: UUID) -> Bool {
        enableRequests[configID] = false
        guard activeDisplayObjects[configID] != nil else {
            return false
        }

        activeDisplayObjects.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)

        return true
    }

    // MARK: - Config Management

    @discardableResult
    func addAndCreate(_ config: VirtualDisplayConfig) async -> Bool {
        guard !configs.contains(where: { $0.id == config.id }) else {
            return await create(config: config)
        }
        guard creationGate.begin(config.id, retained: false) == .create else { return false }
        defer { creationGate.finish(config.id) }
        let created = await createReserved(config)
        // A failed/timed-out apply may still own a live object. Keep its config visible
        // for read-back and cleanup instead of leaving an unaddressable virtual screen.
        guard created || activeDisplayObjects[config.id] != nil else { return false }
        configs.append(config)
        guard saveConfigs() else {
            lastErrors[config.id] = "configuration persistence read-back failed"
            return false
        }
        return created
    }

    @discardableResult
    func removeConfig(id: UUID) -> Bool {
        guard !creationGate.isBusy(id), pendingRemovals[id] == nil,
              !HeadlessDisplayService.shared.usesVirtual(id) else { return false }
        destroy(configID: id)
        let previous = configs
        configs.removeAll { $0.id == id }
        guard saveConfigs() else {
            configs = previous
            saveConfigs()
            return false
        }
        return true
    }

    /// Name/autoCreate update in place; resolution/HiDPI changes are baked into the live
    /// CGVirtualDisplay, so those destroy and recreate it.
    @discardableResult
    func updateConfig(_ updated: VirtualDisplayConfig) async -> Bool {
        guard !creationGate.isBusy(updated.id),
              pendingRemovals[updated.id] == nil,
              let idx = configs.firstIndex(where: { $0.id == updated.id }) else { return false }
        let old = configs[idx]
        let geometryChanged = old.width != updated.width
            || old.height != updated.height
            || old.hiDPI != updated.hiDPI
        guard !geometryChanged || !HeadlessDisplayService.shared.usesVirtual(updated.id) else { return false }
        configs[idx] = updated
        guard saveConfigs() else {
            configs[idx] = old
            saveConfigs()
            lastErrors[updated.id] = "configuration persistence read-back failed"
            return false
        }

        if geometryChanged && isActive(updated.id) {
            // Identity is stable, so must wait for the old display to actually leave the
            // online list, or the recreate races WindowServer's async teardown of it.
            let oldDisplayID = activeDisplayObjects[updated.id]?.displayID
            _ = creationGate.begin(updated.id, retained: false)
            defer { creationGate.finish(updated.id) }
            release(configID: updated.id)
            if let oldDisplayID { await waitForDisplayOffline(oldDisplayID) }
            return await createReserved(updated)
        }
        return true
    }

    /// Bounded wait for a torn-down virtual display to leave the online list: dropping the
    /// strong reference starts async teardown, but WindowServer finishes on its own time.
    private func waitForDisplayOffline(_ displayID: CGDirectDisplayID) async {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard ids.contains(displayID) else { return }
        await ReconfigEvents.shared.next(for: displayID, matching: .removeFlag, timeout: 1.5)
    }

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        else { return }
        configs = decoded

    }

    func restoreAutoCreate() {
        // Delay lets WindowServer stabilise before re-creating autoCreate virtual displays.
        let autoCreateConfigs = configs.filter { $0.autoCreate }
        if !autoCreateConfigs.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                for saved in autoCreateConfigs {
                    guard let config = configs.first(where: { $0.id == saved.id }), config.autoCreate,
                          enableRequests[config.id] != false else { continue }
                    _ = await create(config: config)
                }
            }
        }
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        if count == 0 { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    private func matchesIdentity(_ displayID: CGDirectDisplayID, config: VirtualDisplayConfig) -> Bool {
        config.matchesDescriptor(vendor: CGDisplayVendorNumber(displayID),
                                 product: CGDisplayModelNumber(displayID), serial: CGDisplaySerialNumber(displayID))
    }

    // MARK: - CLI

    func controlSnapshots() -> [CrispControlVirtualDisplay] {
        let online = onlineDisplayIDs()
        return configs.sorted { $0.id.uuidString < $1.id.uuidString }.map { controlSnapshot($0, online: online) }
    }

    private func controlSnapshot(_ config: VirtualDisplayConfig, online: [CGDirectDisplayID]?) -> CrispControlVirtualDisplay {
        let retainedID = activeDisplayObjects[config.id]?.displayID
        let id = retainedID ?? pendingRemovals[config.id]
        let isOnline = online.map { ids in id.map { ids.contains($0) && matchesIdentity($0, config: config) } ?? false }
        let active = isOnline == true && id.map { CGDisplayIsActive($0) != 0 } == true
        let mode = isOnline == true ? id.flatMap { CGDisplayCopyDisplayMode($0) } : nil
        let saved = (try? UserDefaults.standard.data(forKey: configsKey).map {
            try JSONDecoder().decode([VirtualDisplayConfig].self, from: $0).contains(config)
        }) == true
        let resolution = mode.map {
            CrispControlResolution(logicalWidth: $0.width, logicalHeight: $0.height,
                                   pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                                   refreshRate: $0.refreshRate, isHiDPI: $0.pixelWidth > $0.width)
        }
        let creating = creationGate.isBusy(config.id)
        return CrispControlVirtualDisplay(
            config: config, saved: saved, enableRequested: enableRequests[config.id], creating: creating,
            retained: retainedID != nil, online: isOnline, active: active,
            ready: saved && retainedID != nil && active && resolution != nil && !creating, displayID: id, resolution: resolution,
            lastError: online == nil ? "online display enumeration failed" : lastErrors[config.id]
        )
    }

    private func controlFailure(_ config: VirtualDisplayConfig, _ message: String) -> CrispControlResponse {
        CrispControlResponse(ok: false, virtualDisplay: controlSnapshot(config, online: onlineDisplayIDs()),
                             error: message + "; read 'virtual list' before deciding; do not retry automatically")
    }

    func configureForControl(_ config: VirtualDisplayConfig) -> CrispControlResponse {
        guard config.isValid else { return controlFailure(config, "invalid configuration") }
        guard !creationGate.isBusy(config.id) else { return controlFailure(config, "creation is in progress") }
        let existing = configs.first { $0.id == config.id }
        if let existing, activeDisplayObjects[config.id] != nil || pendingRemovals[config.id] != nil,
           existing.width != config.width || existing.height != config.height || existing.hiDPI != config.hiDPI {
            return controlFailure(existing, "disable this config before changing its geometry")
        }
        guard !configs.contains(where: {
            $0.id != config.id && $0.productID == config.productID && $0.serialNumber == config.serialNumber
        }) else { return controlFailure(config, "descriptor identity collides with another saved config") }
        let previous = configs
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        guard saveConfigs() else {
            configs = previous
            saveConfigs()
            return controlFailure(config, "configuration persistence read-back failed")
        }
        return CrispControlResponse(ok: true, virtualDisplay: controlSnapshot(config, online: onlineDisplayIDs()))
    }

    func setEnabledForControl(configID: UUID, enabled: Bool) async -> CrispControlResponse {
        guard let config = configs.first(where: { $0.id == configID }) else {
            return .failure("saved config \(configID.uuidString) not found")
        }
        guard !creationGate.isBusy(configID) else { return controlFailure(config, "creation is in progress") }
        if !enabled, HeadlessDisplayService.shared.usesVirtual(configID) {
            return controlFailure(config, "restore the headless session before disabling its virtual screen")
        }
        if enabled {
            guard await create(config: config) else {
                return controlFailure(config, lastErrors[configID] ?? "creation outcome is uncertain")
            }
        } else {
            _ = creationGate.begin(configID, retained: false)
            defer { creationGate.finish(configID) }
            let oldID = activeDisplayObjects[configID]?.displayID ?? pendingRemovals[configID]
            pendingRemovals[configID] = oldID
            release(configID: configID)
            if let oldID {
                await waitForDisplayOffline(oldID)
                guard let online = onlineDisplayIDs(),
                      !online.contains(oldID) || (CGDisplayVendorNumber(oldID) != 0 && !matchesIdentity(oldID, config: config)) else {
                    lastErrors[configID] = "display removal outcome is uncertain"
                    return controlFailure(config, "display removal outcome is uncertain")
                }
            }
            pendingRemovals.removeValue(forKey: configID)
            lastErrors.removeValue(forKey: configID)
        }
        let snapshot = controlSnapshot(config, online: onlineDisplayIDs())
        if enabled, !snapshot.ready { return controlFailure(config, "activation read-back is not ready") }
        return CrispControlResponse(ok: true, virtualDisplay: snapshot)
    }

    @discardableResult
    private func saveConfigs() -> Bool {
        VirtualDisplayConfig.save(configs, to: .standard, key: configsKey)
    }
}
