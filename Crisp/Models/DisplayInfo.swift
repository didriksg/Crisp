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
    @Published var availableModes: [DisplayMode]
    @Published var currentDisplayMode: DisplayMode?
    @Published var ddcValues: [UInt8: UInt16?] = [:]
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32

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
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? pixelWidth, nativeMode?.height ?? pixelHeight)
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

        if builtin {
            self.name = "Built-in Display"
        } else {
            self.name = NSScreen.screen(for: displayID)?.localizedName ?? "Display \(displayID)"
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
