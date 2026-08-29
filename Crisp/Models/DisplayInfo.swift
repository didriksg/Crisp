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
    /// Nominal SDR luminance ceiling in nits. Used only to normalize the
    /// combined brightness control across unlike display classes.
    let nominalMaxNits: Double?

    /// A stable identifier for the physical display that persists across sleep/wake
    /// even if macOS reassigns the CGDirectDisplayID.
    var displayUUID: String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            return uuidStr as String
        }
        // Fallback: vendor+model+serial hash is more stable than raw displayID
        return "v\(vendorNumber)-m\(modelNumber)-s\(serialNumber)"
    }

    /// The native (highest non-HiDPI) resolution, used for HiDPI enablement and presets.
    /// Reported in CG's rotated space: on a 90/270-rotated display this is portrait,
    /// matching availableModes.
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? pixelWidth, nativeMode?.height ?? pixelHeight)
    }

    /// Whether macOS renders this display rotated 90/270 (portrait on a landscape panel).
    var isRotated: Bool {
        Int(CGDisplayRotation(displayID).rounded()) % 180 != 0
    }

    /// nativeResolution in the panel's unrotated scanout space. The scale-resolutions
    /// override plist describes the panel hardware, which knows nothing about rotation,
    /// so plist writes and checks must use these dims; mode-list comparisons stay in
    /// the rotated space of nativeResolution/availableModes.
    var panelNativeResolution: (width: Int, height: Int) {
        let (w, h) = nativeResolution
        return isRotated ? (h, w) : (w, h)
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
        let serial = CGDisplaySerialNumber(displayID)
        self.vendorNumber = vendor
        self.modelNumber = model
        self.serialNumber = serial
        self.nominalMaxNits = DisplayLuminanceService.maximumSDRNits(
            displayID: displayID,
            isBuiltin: builtin,
            vendor: vendor,
            model: model,
            serial: serial
        )

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

        let modes = await Task.detached(priority: .userInitiated) {
            DisplayMode.availableModes(for: displayID)
        }.value

        self.availableModes = modes
    }
}
