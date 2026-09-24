import Foundation
import CoreGraphics
import IOKit

/// HiDPI override plist management. See docs/display-notes.md (HiDPIService).
@MainActor
final class HiDPIService: @unchecked Sendable {
    static let shared = HiDPIService()
    private init() {}

    private var refreshTask: Task<Void, Never>?

    private let overridesBase = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")

    // MARK: - Public API

    /// Checks whether HiDPI is enabled for the given display via plist override.
    func isHiDPIEnabled(for displayID: CGDirectDisplayID, vendor: UInt32, product: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: overridePlistURL(vendor: vendor, product: product).path)
    }

    /// Checks whether HiDPI is enabled for the given display via plist override only.
    func isHiDPIEnabled(vendor: UInt32, product: UInt32) -> Bool {
        let plistURL = overridePlistURL(vendor: vendor, product: product)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Enables HiDPI via plist override; requires a display reconnect (or reboot) to apply.
    /// Returns nil on success, or an error string.
    func enableHiDPI(for displayID: CGDirectDisplayID,
                     vendor: UInt32,
                     product: UInt32,
                     nativeWidth: Int,
                     nativeHeight: Int) async -> String? {
        return enableHiDPIPlist(vendor: vendor, product: product,
                                nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Legacy single-path enable (plist only).
    func enableHiDPI(vendor: UInt32, product: UInt32, nativeWidth: Int, nativeHeight: Int) -> String? {
        enableHiDPIPlist(vendor: vendor, product: product,
                         nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Disables HiDPI for an external display by removing the plist override.
    func disableHiDPI(for displayID: CGDirectDisplayID,
                      vendor: UInt32,
                      product: UInt32) -> String? {
        return disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Legacy single-path disable (plist only).
    func disableHiDPI(vendor: UInt32, product: UInt32) -> String? {
        disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Refreshes availableModes on the given DisplayInfo after enabling HiDPI.
    func refreshModes(for display: DisplayInfo) {
        refreshTask?.cancel()
        let physicalID = display.displayID

        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            async let modes = Task.detached(priority: .userInitiated) {
                DisplayMode.availableModes(for: physicalID)
            }.value
            async let current = Task.detached(priority: .userInitiated) {
                DisplayMode.currentMode(for: physicalID)
            }.value
            display.availableModes = await modes
            display.currentDisplayMode = await current
        }
    }

    // MARK: - Smooth Scaling

    /// False on chips that never render a HiDPI backing larger than the panel (#174).
    /// See docs/display-notes.md (HiDPIService).
    static let smoothScalingSupported: Bool = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return true }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return true }
        return !(String(bytes: buf.prefix { $0 != 0 }, encoding: .utf8)?.hasPrefix("Apple A") ?? false)
    }()

    /// Injects the dense HiDPI ladder into the override plist and re-probes; skips the
    /// privileged write (and its admin prompt) when the plist already matches.
    /// See docs/display-notes.md (HiDPIService).
    func enableSmoothScaling(vendor: UInt32, product: UInt32,
                             nativeWidth: Int, nativeHeight: Int) -> String? {
        let target = generateSmoothScaledModes(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        if overridePlistMatches(vendor: vendor, product: product, scaledModes: target) {
            // Already installed; re-probe (no admin) in case the modes need re-enumerating.
            triggerDisplayReenumeration(vendor: vendor, product: product)
            return nil
        }
        return writeScaledModesPlist(vendor: vendor, product: product, scaledModes: target)
    }

    /// True when enabling smooth scaling would need a privileged write (admin prompt),
    /// i.e. the on-disk override plist doesn't already carry the dense modes. Lets the UI
    /// show the "asks for administrator password" hint only when it's actually true.
    func smoothScalingWouldPrompt(vendor: UInt32, product: UInt32,
                                  nativeWidth: Int, nativeHeight: Int) -> Bool {
        !overridePlistMatches(vendor: vendor, product: product,
                              scaledModes: generateSmoothScaledModes(nativeWidth: nativeWidth,
                                                                     nativeHeight: nativeHeight))
    }

    // MARK: - Plist Override

    private func enableHiDPIPlist(vendor: UInt32, product: UInt32,
                                  nativeWidth: Int, nativeHeight: Int) -> String? {
        writeScaledModesPlist(vendor: vendor, product: product,
                              scaledModes: generateScaledModes(nativeWidth: nativeWidth,
                                                               nativeHeight: nativeHeight))
    }

    /// Writes the override plist with the given scale-resolutions entries via admin auth,
    /// then re-probes so macOS re-enumerates modes. Shared by normal HiDPI and smooth scaling.
    private func writeScaledModesPlist(vendor: UInt32, product: UInt32, scaledModes: [Data]) -> String? {
        let dirPath = overrideDir(vendor: vendor).path
        let plistPath = overridePlistURL(vendor: vendor, product: product).path

        let plist: [String: Any] = [
            "scale-resolutions": scaledModes
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return "Failed to generate plist data"
        }

        let tmpPath = NSTemporaryDirectory() + "crisp_hidpi_override.plist"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        } catch {
            return "Failed to write temp file: \(error.localizedDescription)"
        }

        if let err = executePrivilegedCommand("mkdir -p '\(dirPath)' && cp '\(tmpPath)' '\(plistPath)'") {
            return err
        }

        try? FileManager.default.removeItem(atPath: tmpPath)

        triggerDisplayReenumeration(vendor: vendor, product: product)

        return nil
    }

    private func disableHiDPIPlist(vendor: UInt32, product: UInt32) -> String? {
        let plistPath = overridePlistURL(vendor: vendor, product: product).path
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }

        if let err = executePrivilegedCommand("rm -f '\(plistPath)'") {
            return err
        }
        return nil
    }

    // MARK: - Helpers

    /// Executes a shell command with administrator privileges via AppleScript.
    /// Returns nil on success, or an error message on failure.
    func executePrivilegedCommand(_ command: String) -> String? {
        let script = """
            do shell script "\(command)" with administrator privileges
            """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return "Failed to create AppleScript"
        }
        // The auth dialog steals key focus and would trip the panel's auto-dismiss;
        // suppress it, and keep suppression alive briefly after the dialog closes.
        PanelOpenGuard.suppressAutoDismiss = true
        let generation = PanelOpenGuard.suppressGeneration
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Skip if a newer suppression window opened since (caller wraps a whole
                // soft-reconnect in one); resetting here would clear it mid-reconnect.
                if PanelOpenGuard.suppressGeneration == generation {
                    PanelOpenGuard.suppressAutoDismiss = false
                }
            }
        }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if msg.contains("canceled") || msg.contains("Cancel") {
                return "User canceled authorization"
            }
            return "Administrator authorization failed: \(msg)"
        }
        return nil
    }

    private func triggerDisplayReenumeration(vendor: UInt32, product: UInt32) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let cfDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() else {
                continue
            }
            let dict = cfDict as NSDictionary

            let serviceVendor: UInt32
            let serviceProduct: UInt32

            if let v = dict["DisplayVendorID"] as? UInt32 {
                serviceVendor = v
            } else if let v = dict["DisplayVendorID"] as? Int {
                serviceVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let p = dict["DisplayProductID"] as? UInt32 {
                serviceProduct = p
            } else if let p = dict["DisplayProductID"] as? Int {
                serviceProduct = UInt32(bitPattern: Int32(truncatingIfNeeded: p))
            } else { continue }

            guard serviceVendor == vendor && serviceProduct == product else { continue }

            IOServiceRequestProbe(service, 0)
            break
        }
    }

    private func overrideDir(vendor: UInt32) -> URL {
        overridesBase
            .appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
    }

    private func overridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        overrideDir(vendor: vendor)
            .appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    /// True when the on-disk override plist's scale-resolutions already equals `scaledModes`
    /// (order-independent). Lets callers skip the privileged rewrite, and its admin prompt,
    /// when nothing would change. Reading /Library/Displays needs no privileges.
    private func overridePlistMatches(vendor: UInt32, product: UInt32, scaledModes: [Data]) -> Bool {
        let url = overridePlistURL(vendor: vendor, product: product)
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let existing = dict["scale-resolutions"] as? [Data]
        else { return false }
        return Set(existing) == Set(scaledModes)
    }

    private func generateScaledModes(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        // Coarse HiDPI ladder matching macOS's usual scaled set: native plus a few standard
        // steps. Each entry is the backing (pixel) resolution = logical × 2.
        var logical: [(Int, Int)] = [(nativeWidth, nativeHeight)]
        for scale in [0.75, 0.625, 0.5] {
            let w = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let h = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard w >= 800, h >= 600 else { continue }
            logical.append((w, h))
        }
        return logical.map { encodeScaledMode(backingW: $0.0 * 2, backingH: $0.1 * 2) }
    }

    /// Dense HiDPI "looks like" ladder for smooth scaling, opt-in per display since it
    /// floods the System Settings resolution list. See docs/display-notes.md (HiDPIService).
    func generateSmoothScaledModes(nativeWidth: Int, nativeHeight: Int,
                                   minScale: Double = 0.5) -> [Data] {
        smoothScaledLogicalSizes(nativeWidth: nativeWidth, nativeHeight: nativeHeight, minScale: minScale)
            .map { encodeScaledMode(backingW: $0.width * 2, backingH: $0.height * 2) }
    }

    /// Logical (point) sizes smooth scaling injects: native width stepped down by 16 points
    /// (BetterDisplay's grid) with height held to the panel's aspect, down to `minScale`×native.
    /// Exposed so the UI can tell whether these have enumerated yet (only after a reconnect).
    func smoothScaledLogicalSizes(nativeWidth: Int, nativeHeight: Int,
                                  minScale: Double = 0.5) -> [(width: Int, height: Int)] {
        let minW = Int((Double(nativeWidth) * minScale).rounded())
        var stops: [(width: Int, height: Int)] = []
        var w = nativeWidth
        while w >= minW {
            let h = Int((Double(w) * Double(nativeHeight) / Double(nativeWidth)).rounded())
            if w >= 800, h >= 600 { stops.append((width: w, height: h)) }
            w -= 16  // BetterDisplay's step; 16px stays even, so backing (×2) stays integer
        }
        return stops  // native first, then descending: distinct widths, no dedup needed
    }

    /// Encodes a backing (pixel) resolution as the 8-byte big-endian entry the
    /// `scale-resolutions` override plist expects: [backingW big-endian][backingH big-endian].
    private func encodeScaledMode(backingW: Int, backingH: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = UInt8((backingW >> 24) & 0xFF)
        bytes[1] = UInt8((backingW >> 16) & 0xFF)
        bytes[2] = UInt8((backingW >> 8) & 0xFF)
        bytes[3] = UInt8(backingW & 0xFF)
        bytes[4] = UInt8((backingH >> 24) & 0xFF)
        bytes[5] = UInt8((backingH >> 16) & 0xFF)
        bytes[6] = UInt8((backingH >> 8) & 0xFF)
        bytes[7] = UInt8(backingH & 0xFF)
        return Data(bytes)
    }
}
