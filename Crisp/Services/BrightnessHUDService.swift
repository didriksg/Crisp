import AppKit
import CoreGraphics

// MARK: - OSDUIHelper Protocol (Private API)

/// Glyph vocabulary shared by both OSD paths: the raw values are what
/// OSDUIHelper expects, and OSDBannerView picks its symbols from the cases.
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

/// Shows the brightness / volume OSD for a display: Crisp's own banner on
/// macOS 26 (OSDBannerService), the native OSDUIHelper bezel before that.
///
/// The XPC path is what MonitorControl and BetterDisplay used for the same purpose.
@MainActor
final class BrightnessHUDService: @unchecked Sendable {
    static let shared = BrightnessHUDService()
    private init() {}

    /// Held while Crisp's own panel is open. The panel carries the same value
    /// on its own slider, and a second one over it is noise, so the OSD stays
    /// away until the panel closes. AppDelegate sets this.
    var suppressed = false {
        didSet {
            // A banner already up when the panel opens floats over it, and the
            // pointer landing on it takes key away from the panel.
            guard suppressed, suppressed != oldValue else { return }
            if #available(macOS 26.0, *) { OSDBannerService.shared.hideVisible() }
        }
    }

    // MARK: - Public API

    /// Shows the brightness OSD on the specified display.
    /// - Parameters:
    ///   - brightness: Brightness level 0–100
    ///   - screen: The NSScreen on which the OSD should appear
    func show(brightness: Double, on screen: NSScreen) {
        show(level: brightness, image: .brightness, on: screen)
    }

    /// Shows the OSD with the given glyph (brightness, volume,
    /// mute) and a 0–100 level bar on the specified display.
    func show(level: Double, image: OSDImage, on screen: NSScreen) {
        guard !suppressed else { return }
        // macOS 26 draws the pre-Tahoe bottom-centre bezel for OSDUIHelper
        // callers while its own HUD is a capsule under the menu bar, so Crisp
        // draws that capsule itself there (#76). macOS 14 and 15 keep the helper.
        if #available(macOS 26.0, *) {
            OSDBannerService.shared.show(level: level, image: image, on: screen)
            return
        }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return
        }

        let totalChiclets: CUnsignedInt = 16
        let filledChiclets = CUnsignedInt((level / 100.0 * Double(totalChiclets)).rounded())

        let conn = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in }

        guard let helper = proxy as? OSDUIHelperProtocol else {
            conn.invalidate()
            return
        }

        helper.showImage(
            image,
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
