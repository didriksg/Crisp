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
    @Published var brightness: Double {
        didSet { persistBrightnessIfNeeded() }
    }
    /// Last brightness written to defaults; avoids per-frame churn from a glide.
    private var persistedBrightness: Double?
    /// 100 normally; above 100 while Extra Brightness (EDR upscaling) is enabled, where
    /// 100...maxBrightness maps to the EDR overlay boost instead of hardware.
    @Published var maxBrightness: Double = 100.0
    /// DDC speaker volume 0–100. Meaningful only while volumeSupported.
    @Published var volume: Double = 0
    /// True once a DDC read of VCP 0x62 succeeded. Gates the volume slider and key routing.
    @Published var volumeSupported: Bool = false
    @Published var availableModes: [DisplayMode]
    @Published var currentDisplayMode: DisplayMode?
    @Published var ddcValues: [UInt8: UInt16?] = [:]
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    /// macOS drives this display's backlight itself (built-in, Apple externals like
    /// Studio Display); Crisp follows via DisplayServices, not DDC.
    let hasNativeBrightness: Bool
    /// Nominal SDR luminance ceiling in nits, used only to scale the combined brightness
    /// control across unlike panels. Filled by loadDetails (walks the whole IORegistry).
    @Published var nominalMaxNits: Double?

    /// Persists across sleep/wake even if macOS reassigns the CGDirectDisplayID.
    var displayUUID: String {
        // Fallback: vendor+model+serial hash is more stable than raw displayID
        Self.cgDisplayUUID(displayID) ?? "v\(vendorNumber)-m\(modelNumber)-s\(serialNumber)"
    }

    /// nil while offline. Static because init needs it before `self` is fully formed.
    static func cgDisplayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
              let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) else { return nil }
        return uuidStr as String
    }

    /// The highest non-HiDPI resolution, for HiDPI enablement and presets. Reported in
    /// CG's rotated space: on a 90/270-rotated display this is portrait, like availableModes.
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? pixelWidth, nativeMode?.height ?? pixelHeight)
    }

    var isRotated: Bool {
        Int(CGDisplayRotation(displayID).rounded()) % 180 != 0
    }

    /// nativeResolution in the panel's unrotated scanout space: the scale-resolutions
    /// override plist describes the hardware, not rotation, so plist writes/checks use
    /// these dims while mode-list comparisons stay in nativeResolution's rotated space.
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
        // Seed from the last brightness seen for this display: a reconnect or displayID
        // reshuffle must not park the slider on a fictional 50 that the next key or
        // click would write to the monitor; BrightnessService corrects it once DDC lands.
        let seed = Self.cgDisplayUUID(displayID).flatMap {
            SettingsService.shared.brightness(forDisplayUUID: $0)
        }
        self.brightness = seed ?? 50.0
        self.persistedBrightness = seed
        self.availableModes = []
        self.currentDisplayMode = DisplayMode.currentMode(for: displayID)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        self.vendorNumber = vendor
        self.modelNumber = model
        self.serialNumber = CGDisplaySerialNumber(displayID)
        self.hasNativeBrightness = BrightnessService.hasNativeBrightness(displayID)

        if builtin {
            self.name = String(localized: "Built-in Display")
        } else {
            // String(displayID), not the raw UInt32: a numeric interpolation generates a
            // numeric-specifier key that never matches the catalog's "Display %@" entry.
            self.name = NSScreen.screen(for: displayID)?.localizedName ?? String(localized: "Display \(String(displayID))")
        }

    }

    /// Records the brightness this display is at, for next time it appears. Externals
    /// only: the built-in reports its real level immediately and its auto-adjust would
    /// write on every step. Boost values (above 100) are skipped to keep a plain percentage.
    private func persistBrightnessIfNeeded() {
        guard !isBuiltin, brightness <= 100.0 else { return }
        guard abs(brightness - (persistedBrightness ?? -1)) >= 1.0 else { return }
        persistedBrightness = brightness
        SettingsService.shared.setBrightness(brightness, forDisplayUUID: displayUUID)
    }

    func loadDetails() async {
        let displayID = self.displayID

        let modes = await Task.detached(priority: .userInitiated) {
            DisplayMode.availableModes(for: displayID)
        }.value

        self.availableModes = modes

        let builtin = self.isBuiltin
        self.nominalMaxNits = await Task.detached(priority: .userInitiated) {
            DisplayLuminanceService.maximumSDRNits(displayID: displayID, isBuiltin: builtin)
        }.value
    }
}
