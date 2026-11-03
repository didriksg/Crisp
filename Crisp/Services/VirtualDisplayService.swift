import CoreGraphics
import Foundation
import IOKit

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

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

    // MARK: - State

    @Published var configs: [VirtualDisplayConfig] = []

    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects; releasing an entry destroys it.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]

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
        let ident = config.id.uuid
        descriptor.productID = UInt32(ident.0) << 24 | UInt32(ident.1) << 16 | UInt32(ident.2) << 8 | UInt32(ident.3)
        descriptor.serialNum = UInt32(ident.4) << 24 | UInt32(ident.5) << 16 | UInt32(ident.6) << 8 | UInt32(ident.7)
        // DO NOT set queue or color primaries: not needed, and may interfere with creation.

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

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
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applyResult else { return false }
        guard virtualDisplay.displayID != kCGNullDirectDisplay else { return false }

        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)

        // macOS auto-adds a scaled looks-like-1080p default for high-resolution displays
        // regardless of the modes supplied; force native 1x so it reads as its real resolution.
        await applyNativeResolution(virtualDisplay.displayID, width: w, height: h)
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

    /// Name/autoCreate update in place; resolution/HiDPI changes are baked into the live
    /// CGVirtualDisplay, so those destroy and recreate it.
    @discardableResult
    func updateConfig(_ updated: VirtualDisplayConfig) async -> Bool {
        guard let idx = configs.firstIndex(where: { $0.id == updated.id }) else { return false }
        let old = configs[idx]
        configs[idx] = updated
        saveConfigs()

        let geometryChanged = old.width != updated.width
            || old.height != updated.height
            || old.hiDPI != updated.hiDPI
        if geometryChanged && isActive(updated.id) {
            // Identity is stable, so must wait for the old display to actually leave the
            // online list, or the recreate races WindowServer's async teardown of it.
            let oldDisplayID = activeDisplayObjects[updated.id]?.displayID
            destroy(configID: updated.id)
            if let oldDisplayID { await waitForDisplayOffline(oldDisplayID) }
            return await create(config: updated)
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
                    guard !virtualDisplayAlreadyExists(width: config.width, height: config.height) else {
                        continue
                    }
                    _ = await create(config: config)
                }
            }
        }
    }

    /// True if an online display already matches these dimensions with no IOKit service port
    /// (virtual displays have none); used by autoCreate to avoid duplicating a crash survivor.
    private func virtualDisplayAlreadyExists(width: Int, height: Int) -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        for id in displayIDs {
            // No service port means virtual; physical displays always have one.
            let servicePort = CGDisplayIOServicePort(id)
            guard servicePort == 0 || servicePort == MACH_PORT_NULL else { continue }
            let w = Int(CGDisplayPixelsWide(id))
            let h = Int(CGDisplayPixelsHigh(id))
            if w == width && h == height { return true }
        }
        return false
    }

    private func saveConfigs() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: configsKey)
    }
}
