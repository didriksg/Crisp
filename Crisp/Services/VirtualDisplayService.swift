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

    struct VirtualDisplayConfig: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var width: Int
        var height: Int
        var refreshRate: Double
        var hiDPI: Bool
        var autoCreate: Bool
        /// Starts at the 2x mode (half the width and height in points) instead of the native
        /// 1x. Optional so configs saved before it decode, as off: `hiDPI` was always saved on
        /// and only offers the 2x modes, so it can't mean this.
        var startsHiDPI: Bool?

        var productID: UInt32 {
            let bytes = id.uuid
            return UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
        }

        var serialNumber: UInt32 {
            let bytes = id.uuid
            return UInt32(bytes.4) << 24 | UInt32(bytes.5) << 16 | UInt32(bytes.6) << 8 | UInt32(bytes.7)
        }

        var displayUUID: String {
            CrispVirtualDisplayIdentity.uuid(productID: productID, serialNumber: serialNumber)
        }

        init(id: UUID = UUID(), name: String, width: Int, height: Int,
             refreshRate: Double = 60.0, hiDPI: Bool = true, autoCreate: Bool = true) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
            self.hiDPI = hiDPI
            self.autoCreate = autoCreate
        }
    }

    static let refreshRateOptions: [Double] = [50, 60, 75, 120, 144]

    /// "3840 × 2160 · 60 Hz", the line under a virtual display's name.
    static func summary(_ config: VirtualDisplayConfig) -> String {
        "\(config.width) × \(config.height) · \(RefreshRateFormat.label(config.refreshRate))"
            + (config.startsHiDPI == true ? " · HiDPI" : "")
    }

    // MARK: - State

    @Published var configs: [VirtualDisplayConfig] = []

    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects; releasing an entry destroys it.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]

    private let configsKey = "crisp.VirtualDisplayConfigs"

    /// Vendor ID stamped on every Crisp virtual display's descriptor, and the race-free
    /// signature filtered on: CGDisplayVendorNumber reports it the instant the display is online.
    static let crispVirtualVendorID = CrispVirtualDisplayIdentity.vendorID

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    /// The UUID a preset stores for a display. On Apple Silicon WindowServer gives a virtual
    /// display a random UUID, so a Crisp virtual display is stored by its config's identity.
    func presetUUID(of display: DisplayInfo) -> String {
        let id = display.displayID
        guard CGDisplayVendorNumber(id) == Self.crispVirtualVendorID,
              let config = configs.first(where: {
                  $0.productID == CGDisplayModelNumber(id) && $0.serialNumber == CGDisplaySerialNumber(id)
              }) else { return display.displayUUID }
        return config.displayUUID
    }

    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        // Vendor ID first: it's live the instant the display is online, so a freshly created
        // one is filtered on the first refresh. The object set below is a backstop.
        if CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID { return true }
        return activeDisplayObjects.values.contains { $0.displayID == displayID }
    }

    func configuredRefreshRate(for displayID: CGDirectDisplayID) -> Double? {
        guard CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID else { return nil }
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        return configs.first(where: { $0.productID == product && $0.serialNumber == serial })?.refreshRate
    }

    func applyConfiguredRefreshRate(for displayID: CGDirectDisplayID) async {
        guard let rate = configuredRefreshRate(for: displayID),
              let current = CGDisplayCopyDisplayMode(displayID) else { return }
        var config = VirtualDisplayConfig(
            name: "", width: current.pixelWidth, height: current.pixelHeight,
            refreshRate: rate, autoCreate: false
        )
        config.startsHiDPI = current.pixelWidth > current.width
        await applyConfiguredResolution(displayID, config: config)
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the config. Descriptor build and CGVirtualDisplay init
    /// run on the main actor (the API requires it); only `apply` runs off-main, since it can
    /// block on WindowServer IPC. See docs/display-notes.md (VirtualDisplayService.create).
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
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
            return false
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI

        var modes: [CGVirtualDisplayMode] = []
        let refreshRates = [config.refreshRate] + Self.refreshRateOptions.filter { $0 != config.refreshRate }
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
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applyResult else { return false }
        guard virtualDisplay.displayID != kCGNullDirectDisplay else { return false }

        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)

        await applyConfiguredResolution(virtualDisplay.displayID, config: config)
        return true
    }

    /// Sets the configured start mode: macOS gives a high-resolution virtual display a
    /// scaled default whatever modes are supplied. Returns once the mode holds through 0.3 s
    /// with no further mode change: on Intel, WindowServer replaced a mode that had
    /// already held once during registration (#284).
    private func applyConfiguredResolution(_ displayID: CGDirectDisplayID, config: VirtualDisplayConfig) async {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let scale = config.startsHiDPI == true ? 2 : 1
        let width = config.width / scale
        let height = config.height / scale
        for _ in 0..<10 {
            if let cur = CGDisplayCopyDisplayMode(displayID),
               cur.width == width, cur.height == height,
               cur.pixelWidth == config.width, cur.pixelHeight == config.height,
               abs(cur.refreshRate - config.refreshRate) < 0.5 {
                guard await ReconfigEvents.shared.next(for: displayID, matching: .setModeFlag, timeout: 0.3) else {
                    return
                }
                continue
            }
            guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
                  let target = modes.first(where: {
                      $0.pixelWidth == config.width && $0.pixelHeight == config.height
                          && $0.width == width && $0.height == height
                          && abs($0.refreshRate - config.refreshRate) < 0.5
                  })
            else {
                await ReconfigEvents.shared.next(for: displayID, matching: .setModeFlag, timeout: 0.3)
                continue
            }
            _ = await ResolutionService.applyModeSync(target, on: displayID)
        }
    }

    func destroyAll() {
        for uuid in activeConfigIDs {
            activeDisplayObjects.removeValue(forKey: uuid)
        }
        activeConfigIDs.removeAll()
    }

    func setActive(_ enabled: Bool, configID: UUID) async -> Bool {
        guard let config = configs.first(where: { $0.id == configID }) else { return false }
        if enabled {
            if !isActive(configID), !(await create(config: config)) { return false }
            guard let displayID = activeDisplayObjects[configID]?.displayID else { return false }
            for _ in 0..<30 {
                if CGDisplayIsOnline(displayID) != 0 { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        guard let displayID = activeDisplayObjects[configID]?.displayID else { return true }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success,
              displays.prefix(Int(count)).contains(where: { $0 != displayID }) else { return false }
        destroy(configID: configID)
        await waitForDisplayOffline(displayID)
        return CGDisplayIsOnline(displayID) == 0
    }

    @discardableResult
    func destroy(configID: UUID) -> Bool {
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
        // Create first; only persist on success to avoid stale config if process crashes.
        if await create(config: config) {
            configs.append(config)
            saveConfigs()
            return true
        }
        return false
    }

    func removeConfig(id: UUID) {
        destroy(configID: id)
        configs.removeAll { $0.id == id }
        saveConfigs()
    }

    /// Name/autoCreate update in place; resolution/HiDPI/refresh-rate changes affect the live
    /// CGVirtualDisplay, so those destroy and recreate it.
    @discardableResult
    func updateConfig(_ updated: VirtualDisplayConfig) async -> Bool {
        guard let idx = configs.firstIndex(where: { $0.id == updated.id }) else { return false }
        let old = configs[idx]
        configs[idx] = updated
        saveConfigs()

        let modeChanged = old.width != updated.width
            || old.height != updated.height
            || old.hiDPI != updated.hiDPI
            || old.refreshRate != updated.refreshRate
        if modeChanged && isActive(updated.id) {
            // Identity is stable, so must wait for the old display to actually leave the
            // online list, or the recreate races WindowServer's async teardown of it.
            let oldDisplayID = activeDisplayObjects[updated.id]?.displayID
            destroy(configID: updated.id)
            if let oldDisplayID { await waitForDisplayOffline(oldDisplayID) }
            return await create(config: updated)
        }
        if old.startsHiDPI != updated.startsHiDPI, let displayID = activeDisplayObjects[updated.id]?.displayID {
            await applyConfiguredResolution(displayID, config: updated)
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

        // Delay lets WindowServer stabilise before re-creating autoCreate virtual displays.
        let autoCreateConfigs = configs.filter { $0.autoCreate }
        if !autoCreateConfigs.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                for config in autoCreateConfigs {
                    // A virtual display from a crashed previous session may still be registered.
                    guard !virtualDisplayAlreadyExists(config: config) else {
                        continue
                    }
                    _ = await create(config: config)
                }
            }
        }
    }

    private func virtualDisplayAlreadyExists(config: VirtualDisplayConfig) -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        for displayID in displayIDs.prefix(Int(displayCount)) {
            if CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID,
               CGDisplayModelNumber(displayID) == config.productID,
               CGDisplaySerialNumber(displayID) == config.serialNumber {
                return true
            }
        }
        return false
    }

    private func saveConfigs() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: configsKey)
    }
}

extension DisplayInfo {
    /// The UUID presets store for this display (see `VirtualDisplayService.presetUUID(of:)`).
    var presetUUID: String { VirtualDisplayService.shared.presetUUID(of: self) }
}
