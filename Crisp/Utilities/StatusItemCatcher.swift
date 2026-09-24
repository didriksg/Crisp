import AppKit

/// A clear window over Crisp's menu bar item that intercepts presses before
/// macOS 27's own status item highlight can react to them (otherwise the
/// system lights its own, wider pill, which then snaps narrower on release).
/// Draws nothing, so it need not be visible on the real display for hit
/// testing to find it; Command-held presses pass through so the item can
/// still be dragged.
@MainActor
final class StatusItemCatcher {
    private let panel: NSPanel
    private weak var item: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var commandWatch: Timer?

    /// macOS 27 only: older releases light the item through the button itself.
    static func over(_ button: NSStatusBarButton?, onPress: @escaping () -> Void) -> StatusItemCatcher? {
        guard SystemLook.isMacOS27OrLater, let window = button?.window else { return nil }
        return StatusItemCatcher(over: window, onPress: onPress)
    }

    private init(over item: NSWindow, onPress: @escaping () -> Void) {
        self.item = item
        panel = NSPanel(contentRect: item.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Set, not left at its default: a clear window that has not been told
        // takes no clicks where it is clear, which is everywhere.
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = PressView()
        view.onPress = onPress
        view.onEnter = { [weak self] in self?.watchCommand() }
        panel.contentView = view
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            })
        }
        follow()
        panel.orderFrontRegardless()
    }

    private func follow() {
        guard let item else { return }
        panel.setFrame(item.frame, display: false)
    }

    /// Lets Command-held presses through while the pointer is over the item: a
    /// key monitor would need the app active or an Accessibility grant, so a
    /// short poll substitutes instead.
    private func watchCommand() {
        guard commandWatch == nil else { return }
        commandWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let inside = self.panel.frame.contains(NSEvent.mouseLocation)
                self.panel.ignoresMouseEvents = inside && NSEvent.modifierFlags.contains(.command)
                if !inside {
                    self.commandWatch?.invalidate()
                    self.commandWatch = nil
                }
            }
        }
    }

    private final class PressView: NSView {
        var onPress: (() -> Void)?
        var onEnter: (() -> Void)?

        override func mouseDown(with event: NSEvent) { onPress?() }
        override func rightMouseDown(with event: NSEvent) { onPress?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { onEnter?() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }
}
