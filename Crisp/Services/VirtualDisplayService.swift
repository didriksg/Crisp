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

    /// Active config IDs — populated when a CGVirtualDisplay is alive.
    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects.
    /// Releasing an entry causes the virtual display to disappear immediately.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]

    private let configsKey = "fd.VirtualDisplayConfigs"

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    /// Returns true if `displayID` is a virtual display managed by this service.
    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        activeDisplayObjects.values.contains { $0.displayID == displayID }
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the given config using CGVirtualDisplay private API.
    /// Returns true on success. The CGVirtualDisplay object is retained in `activeDisplayObjects`.
    /// The ENTIRE creation (descriptor build + CGVirtualDisplay init + apply) runs off the
    /// main actor via `runWithTimeout` because any of these calls can block on WindowServer IPC.
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        let w = config.width
        let h = config.height
        let hiDPI = config.hiDPI

        // Step 1-2: Build descriptor + create CGVirtualDisplay ON MAIN ACTOR.
        // CGVirtualDisplay(descriptor:) requires the main thread (returns nil from background).
        let descriptor = CGVirtualDisplayDescriptor()
        let ppi: Double = 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(w) / ppi * 25.4,
            height: Double(h) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = "Crisp Virtual"
        descriptor.vendorID = 0xEEEE  // non-zero required — 0 causes CGVirtualDisplay(descriptor:) to return nil
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        // DO NOT set queue or color primaries — they are not needed and may interfere with creation

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

        // Step 3: Build settings with modes
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

        // Step 4: Apply settings on BACKGROUND thread (blocks on WindowServer IPC).
        let vd = virtualDisplay
        let s = settings
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applyResult else { return false }
        guard virtualDisplay.displayID != kCGNullDirectDisplay else { return false }

        // Back on main actor — store the strong reference
        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)
        return true
    }

    /// Destroys all active virtual displays. Called on app termination to avoid
    /// leaving stale displays registered with WindowServer.
    func destroyAll() {
        for uuid in activeConfigIDs {
            activeDisplayObjects.removeValue(forKey: uuid)
        }
        activeConfigIDs.removeAll()
    }

    /// Destroys the virtual display associated with `configID`.
    @discardableResult
    func destroy(configID: UUID) -> Bool {
        guard activeDisplayObjects[configID] != nil else {
            return false
        }

        // ARC releases the CGVirtualDisplay → virtual display disappears
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

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        else { return }
        configs = decoded

        // Re-create virtual displays marked autoCreate after WindowServer stabilises.
        let autoCreateConfigs = configs.filter { $0.autoCreate }
        if !autoCreateConfigs.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                for config in autoCreateConfigs {
                    // After a crash, a virtual display from the previous session may
                    // still be registered with WindowServer. Skip creation if an online
                    // virtual display with matching dimensions already exists.
                    guard !virtualDisplayAlreadyExists(width: config.width, height: config.height) else {
                        #if DEBUG
                        print("[VirtualDisplayService] autoCreate skipped — virtual display \(config.width)×\(config.height) already online")
                        #endif
                        continue
                    }
                    _ = await create(config: config)
                }
            }
        }
    }

    /// Returns true if any currently-online display matches the given pixel dimensions and
    /// has no associated IOKit service port (indicating it is a virtual/software display).
    /// Used by autoCreate to avoid duplicating a display that survived an app crash.
    private func virtualDisplayAlreadyExists(width: Int, height: Int) -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        for id in displayIDs {
            // A software/virtual display has no IOService entry (servicePort == 0 / MACH_PORT_NULL).
            // Physical displays always have a non-null service port.
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
