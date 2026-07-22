import AppKit
import CoreGraphics

// MARK: - OSDUIHelper Protocol (Private API)

/// OSDImage values for the native macOS OSD.
/// Brightness up/down uses value 1 (brightness icon with level bar).
@objc enum OSDImage: CLong {
    case brightness = 1
    case volume = 3
    case mute = 4
    case eject = 6
}

/// XPC protocol matching OSDUIHelper's interface.
/// This version (with filledChiclets/totalChiclets) shows the brightness level bar.
@objc protocol OSDUIHelperProtocol {
    func showImage(
        _ img: OSDImage,
        onDisplayID displayID: CGDirectDisplayID,
        priority: CUnsignedInt,
        msecUntilFade: CUnsignedInt,
        filledChiclets: CUnsignedInt,
        totalChiclets: CUnsignedInt,
        locked: Bool
    )
}

// MARK: - BrightnessHUDService

/// Shows the native macOS brightness OSD via the private OSDUIHelper XPC service.
/// This produces the exact same brightness indicator that macOS uses natively.
///
/// Used by MonitorControl and BetterDisplay for the same purpose.
@MainActor
final class BrightnessHUDService: @unchecked Sendable {
    static let shared = BrightnessHUDService()
    private init() {}

    // MARK: - Public API

    /// Shows the native macOS brightness OSD on the specified display.
    /// - Parameters:
    ///   - brightness: Brightness level 0–100
    ///   - screen: The NSScreen on which the OSD should appear
    func show(brightness: Double, on screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            NSLog("[BrightnessHUD] Could not get CGDirectDisplayID for screen")
            return
        }

        let totalChiclets: CUnsignedInt = 16
        let filledChiclets = CUnsignedInt((brightness / 100.0 * Double(totalChiclets)).rounded())

        let conn = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
        conn.interruptionHandler = { NSLog("[BrightnessHUD] XPC connection interrupted") }
        conn.invalidationHandler = { NSLog("[BrightnessHUD] XPC connection invalidated") }
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            NSLog("[BrightnessHUD] XPC error: %@", error.localizedDescription)
        }

        guard let helper = proxy as? OSDUIHelperProtocol else {
            NSLog("[BrightnessHUD] Failed to get OSDUIHelper proxy")
            conn.invalidate()
            return
        }

        helper.showImage(
            .brightness,
            onDisplayID: displayID,
            priority: 0x1f4,
            msecUntilFade: 1500,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets,
            locked: false
        )

        // Invalidate after a short delay to allow the XPC message to be delivered
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            conn.invalidate()
        }
    }
}
