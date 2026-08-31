import Foundation
import CoreGraphics
import IOKit
import AppKit

@MainActor
class DisplayInfo: ObservableObject, Identifiable {
    nonisolated var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    @Published var name: String
    @Published var isBuiltin: Bool
    @Published var isMain: Bool
    @Published var isOnline: Bool
    @Published var isEnabled: Bool
    @Published var bounds: CGRect
    @Published var pixelWidth: Int
    @Published var pixelHeight: Int
    @Published var brightness: Double
    /// UI brightness ceiling. 100 normally; above 100 while Extra Brightness
    /// (EDR upscaling) is enabled, where the range 100...maxBrightness maps to
    /// the EDR overlay boost instead of hardware.
    @Published var maxBrightness: Double = 100.0
    /// DDC speaker volume 0–100. Meaningful only while volumeSupported.
    @Published var volume: Double = 0
    /// True once a DDC read of VCP 0x62 succeeded, i.e. the monitor exposes
    /// controllable speaker volume. Gates the volume slider and key routing.
    @Published var volumeSupported: Bool = false
    @Published var availableModes: [DisplayMode]
    @Published var currentDisplayMode: DisplayMode?
    @Published var ddcValues: [UInt8: UInt16?] = [:]
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    /// Captured while this object is created. Do not resolve this lazily from
    /// `displayID`: macOS may reuse that numeric ID for different hardware.
    let displayUUID: String
    /// EDID/IORegistry evidence in unrotated panel space. Loaded with the mode list.
    @Published private(set) var detectedPanelResolution: DetectedPanelResolution?
    /// User fallback for displays whose EDID is unavailable or wrong.
    @Published private(set) var manualPanelResolution: PanelResolution?

    /// A stable identifier for the physical display that persists across sleep/wake
    /// even if macOS reassigns the CGDirectDisplayID.
    /// Physical native resolution in CG's rotated space. EDID/native-format metadata
    /// wins over WindowServer's mode list, whose largest non-HiDPI entry can be a
    /// compatibility fallback (for example 1024x768 on a 4K panel).
    var nativeResolution: (width: Int, height: Int) {
        let panel = resolvedPanelResolution.resolution
        return isRotated ? (panel.height, panel.width) : (panel.width, panel.height)
    }

    var panelResolutionSource: PanelResolutionSource { resolvedPanelResolution.source }

    /// Whether macOS renders this display rotated 90/270 (portrait on a landscape panel).
    var isRotated: Bool {
        Int(CGDisplayRotation(displayID).rounded()) % 180 != 0
    }

    /// nativeResolution in the panel's unrotated scanout space. The scale-resolutions
    /// override plist describes the panel hardware, which knows nothing about rotation,
    /// so plist writes and checks must use these dims; mode-list comparisons stay in
    /// the rotated space of nativeResolution/availableModes.
    var panelNativeResolution: (width: Int, height: Int) {
        let resolution = resolvedPanelResolution.resolution
        return (resolution.width, resolution.height)
    }

    private var resolvedPanelResolution: ResolvedPanelResolution {
        let unscaledModes = availableModes.filter { !$0.isHiDPI }.map {
            isRotated
                ? PanelResolution(width: $0.height, height: $0.width)
                : PanelResolution(width: $0.width, height: $0.height)
        }
        let current = isRotated
            ? PanelResolution(width: pixelHeight, height: pixelWidth)
            : PanelResolution(width: pixelWidth, height: pixelHeight)
        return PanelResolutionResolver.resolve(
            manual: manualPanelResolution,
            edid: detectedPanelResolution?.edid,
            registry: detectedPanelResolution?.registry,
            unscaledModes: unscaledModes,
            currentPixels: current
        )
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        self.isBuiltin = builtin
        self.isMain = CGDisplayIsMain(displayID) != 0
        self.isOnline = CGDisplayIsOnline(displayID) != 0
        self.isEnabled = CGDisplayIsActive(displayID) != 0
        self.bounds = CGDisplayBounds(displayID)
        self.pixelWidth = CGDisplayPixelsWide(displayID)
        self.pixelHeight = CGDisplayPixelsHigh(displayID)
        // Use persisted brightness as the initial value if available, otherwise 50.0.
        // BrightnessService will overwrite this with the real hardware value once probed.
        self.brightness = SettingsService.shared.brightness(for: displayID) ?? 50.0
        self.availableModes = []
        self.currentDisplayMode = DisplayMode.currentMode(for: displayID)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        self.vendorNumber = vendor
        self.modelNumber = model
        self.serialNumber = CGDisplaySerialNumber(displayID)
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            self.displayUUID = uuidStr as String
        } else {
            // Fallback: vendor+model+serial is more stable than raw displayID.
            self.displayUUID = "v\(vendor)-m\(model)-s\(self.serialNumber)"
        }
        self.detectedPanelResolution = nil
        self.manualPanelResolution = SettingsService.shared.panelResolutionOverride(
            vendor: vendor, product: model, serial: self.serialNumber)

        if builtin {
            self.name = String(localized: "Built-in Display")
        } else {
            // String(displayID), not the raw UInt32: a numeric interpolation generates a
            // numeric-specifier key that never matches the catalog's "Display %@" entry.
            self.name = NSScreen.screen(for: displayID)?.localizedName ?? String(localized: "Display \(String(displayID))")
        }

    }

    func loadDetails() async {
        let displayID = self.displayID
        let vendor = vendorNumber
        let product = modelNumber
        let serial = serialNumber
        let builtin = isBuiltin

        async let detectionTask = Task.detached(priority: .utility) {
            builtin ? nil : PanelResolutionDetector.detect(
                vendor: vendor, product: product, serial: serial)
        }.value
        async let modeTask = Task.detached(priority: .userInitiated) {
            DisplayMode.enumerateModes(for: displayID)
        }.value

        let detection = await detectionTask
        let enumeration = await modeTask
        self.detectedPanelResolution = detection

        let evidence = manualPanelResolution ?? detection?.edid ?? detection?.registry
        let aspect = evidence.map {
            isRotated ? Double($0.height) / Double($0.width)
                : Double($0.width) / Double($0.height)
        }
        self.availableModes = enumeration.resolved(nativeAspect: aspect)
    }

    func setManualPanelResolution(_ resolution: PanelResolution?) {
        SettingsService.shared.setPanelResolutionOverride(
            resolution, vendor: vendorNumber, product: modelNumber, serial: serialNumber)
        manualPanelResolution = resolution
    }
}
