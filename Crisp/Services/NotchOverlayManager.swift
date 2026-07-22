import AppKit
import CoreGraphics

/// Manages a black overlay window that covers the notch area of built-in MacBook displays.
@MainActor
class NotchOverlayManager {
    static let shared = NotchOverlayManager()
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        var toRemove: [CGDirectDisplayID] = []
        for (displayID, window) in overlayWindows {
            guard let screen = NSScreen.screen(for: displayID) else {
                // Screen gone — close overlay
                window.close()
                toRemove.append(displayID)
                continue
            }
            let notchHeight = screen.safeAreaInsets.top
            guard notchHeight > 0 else {
                window.close()
                toRemove.append(displayID)
                continue
            }
            let screenFrame = screen.frame
            let newFrame = NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - notchHeight,
                width: screenFrame.width,
                height: notchHeight
            )
            window.setFrame(newFrame, display: true)
        }
        for displayID in toRemove {
            overlayWindows.removeValue(forKey: displayID)
        }
    }

    func showOverlay(for displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screen(for: displayID) else { return }
        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else { return }

        // Close the old window first before creating a new one
        if let existing = overlayWindows[displayID] {
            existing.close()
            overlayWindows.removeValue(forKey: displayID)
        }

        let screenFrame = screen.frame
        let overlayFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - notchHeight,
            width: screenFrame.width,
            height: notchHeight
        )

        let window = NSWindow(
            contentRect: overlayFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false  // Prevent dangling pointer after close()
        window.backgroundColor = .black
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isOpaque = true
        window.hasShadow = false
        window.orderFront(nil)

        overlayWindows[displayID] = window
    }

    func hideOverlay(for displayID: CGDirectDisplayID) {
        overlayWindows[displayID]?.close()
        overlayWindows.removeValue(forKey: displayID)
    }

    func isShowingOverlay(for displayID: CGDirectDisplayID) -> Bool {
        overlayWindows[displayID] != nil
    }
}
