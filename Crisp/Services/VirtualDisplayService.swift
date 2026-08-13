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

    /// Active config IDs, populated when a CGVirtualDisplay is alive.
    @Published private(set) var activeConfigIDs: Set<UUID> = []

    /// Strong references to live CGVirtualDisplay objects.
    /// Releasing an entry causes the virtual display to disappear immediately.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]

    private let configsKey = "crisp.VirtualDisplayConfigs"

    /// Vendor ID stamped on every Crisp virtual display's descriptor. Also the
    /// race-free signature we filter on: CGDisplayVendorNumber reports it the
    /// instant WindowServer brings the display online.
    static let crispVirtualVendorID: UInt32 = 0xEEEE

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    /// Returns true if `displayID` is a virtual display managed by this service.
    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        // Match by our stamped vendor ID first: it's live from CG the moment the
        // display is online, so a freshly created one is filtered on the very
        // first refresh instead of flashing as a top-level display in the gap
        // before activeDisplayObjects records it. The object set is a backstop.
        if CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID { return true }
        return activeDisplayObjects.values.contains { $0.displayID == displayID }
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the given config using CGVirtualDisplay private API.
    /// Returns true on success. The CGVirtualDisplay object is retained in `activeDisplayObjects`.
    /// The ENTIRE creation (descriptor build + CGVirtualDisplay init + apply) runs off the
    /// main actor via `runWithTimeout` because any of these calls can block on WindowServer IPC.
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        // When a new display registers, macOS pops its own "What do you want to
        // show on [display]?" picker, which takes key focus and would trip our
        // panel's outside-click / resign-key auto-dismiss (the app appears to
        // vanish). Suppress that here, same as the HiDPI auth path. Harmless at
        // launch (autoCreate) since the panel isn't open then.
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

        // Step 1-2: Build descriptor + create CGVirtualDisplay ON MAIN ACTOR.
        // CGVirtualDisplay(descriptor:) requires the main thread (returns nil from background).
        let descriptor = CGVirtualDisplayDescriptor()
        // Size from a fixed PPI so each resolution reports a physical size like a
        // real panel of that resolution. This makes macOS default to the NATIVE
        // resolution (4K stays 4K) instead of a scaled Retina mode, matching how
        // dummy-display tools (BetterDisplay) present virtual displays.
        // Note: the "what to show" / mirror-or-extend prompt is gated on the
        // display's reported type (macOS treats these as HDMI/TV), not on physical
        // size, so shrinking the reported size does NOT avoid it, it only changes
        // the default scaling. Suppressing the prompt would need an EDID override
        // (mark as DisplayPort), which this CGVirtualDisplay API doesn't expose.
        let ppi: Double = 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(w) / ppi * 25.4,
            height: Double(h) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = config.name.isEmpty ? String(localized: "Crisp Virtual") : config.name
        descriptor.vendorID = Self.crispVirtualVendorID  // non-zero required, 0 causes CGVirtualDisplay(descriptor:) to return nil
        // Identity must be both UNIQUE per config (else a second virtual display
        // collides with the first, which WindowServer mirrors/rejects) and STABLE
        // across recreations (macOS keys per-display settings, including the
        // "extend vs mirror / what to show" choice, on this identity; a value that
        // changes each time makes it treat every creation as a brand-new display
        // and re-prompt every time). Both halves come from the config UUID:
        // product from bytes 0-3, serial from bytes 4-7.
        let ident = config.id.uuid
        descriptor.productID = UInt32(ident.0) << 24 | UInt32(ident.1) << 16 | UInt32(ident.2) << 8 | UInt32(ident.3)
        descriptor.serialNum = UInt32(ident.4) << 24 | UInt32(ident.5) << 16 | UInt32(ident.6) << 8 | UInt32(ident.7)
        // DO NOT set queue or color primaries, they are not needed and may interfere with creation

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

        // Back on main actor, store the strong reference
        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)

        // macOS auto-adds a scaled (looks-like-1080p) mode for high-resolution
        // displays and picks it as the default no matter which modes we supply,
        // so a 4K display comes up at 1080p. Force the native 1x mode so it reads
        // as its real resolution (4K stays 4K).
        await applyNativeResolution(virtualDisplay.displayID, width: w, height: h)
        return true
    }

    /// Drives a freshly-created virtual display to its native 1x resolution.
    /// macOS assigns its auto-scaled default asynchronously, so this checks the
    /// active mode and retries briefly until the native mode sticks (or gives up).
    private func applyNativeResolution(_ displayID: CGDirectDisplayID, width: Int, height: Int) async {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for attempt in 0..<5 {
            // Between attempts, wake on the mode-change event instead of a blind
            // 300ms sleep; same per-attempt ceiling when no event comes.
            if attempt > 0 {
                await ReconfigEvents.shared.next(for: displayID, matching: .setModeFlag, timeout: 0.3)
            }
            // Native 1x means point size == pixel size == the target resolution.
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

    /// Applies edits to an existing config. Name and autoCreate are metadata and
    /// update in place; changing resolution or HiDPI is baked into the live
    /// CGVirtualDisplay, so an active display is destroyed and recreated with the
    /// new settings. Returns false only if a required recreate failed.
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
            // Identity is stable, so the recreated display reuses the old one's
            // identity. Wait for the old display to actually leave the online
            // list before recreating, or the new one races WindowServer's async
            // teardown of the old one (collision / mirror).
            let oldDisplayID = activeDisplayObjects[updated.id]?.displayID
            destroy(configID: updated.id)
            if let oldDisplayID { await waitForDisplayOffline(oldDisplayID) }
            return await create(config: updated)
        }
        return true
    }

    /// Waits (bounded, 1.5s ceiling) for a torn-down virtual display to leave the
    /// online display list. CGVirtualDisplay teardown is async: dropping the strong
    /// reference starts it, but WindowServer finishes on its own time. Event-driven:
    /// the check-then-await is race-free on the main actor (see ReconfigEvents).
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
