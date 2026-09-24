import AppKit

/// The lit pill behind Crisp's menu bar icon while the panel or the banner is
/// up. `NSStatusBarButton.highlight(_:)` paints nothing on macOS 27, so there
/// the pill is drawn here instead, in the button's own layer.
/// See docs/panel-resize.md (StatusItemHighlight) for the measured shape and colors.
enum StatusItemHighlight {
    private static let barInset: CGFloat = 3
    private static let overhang: CGFloat = 2

    private static let lift: CGFloat = 11

    @MainActor
    static func apply(_ lit: Bool, to button: NSStatusBarButton?) {
        guard let button else { return }
        guard SystemLook.isMacOS27OrLater else {
            button.highlight(lit)
            return
        }
        draw(lit, on: button)
    }

    /// True over the item's whole window (the press area), not the button's own
    /// smaller rect.
    @MainActor
    static func isPointerOver(_ button: NSStatusBarButton?) -> Bool {
        guard let window = button?.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    @MainActor
    private static func draw(_ lit: Bool, on button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard lit, let frame = frame(in: button) else {
            pill(in: host)?.removeFromSuperlayer()
            return
        }
        let layer = pill(in: host) ?? add(to: host)
        layer.frame = frame
        layer.cornerRadius = frame.height / 2
    }

    /// The pill's frame in the button's own coordinates, sized off the menu bar
    /// (not the button: a notched bar is a different height).
    @MainActor
    private static func frame(in button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window, let screen = window.screen else { return nil }
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard barHeight > 2 * barInset else { return nil }
        let height = barHeight - 2 * barInset
        let buttonTop = window.convertToScreen(button.convert(button.bounds, to: nil)).maxY
        let top = buttonTop - (screen.frame.maxY - barInset)
        return CGRect(x: 0,
                      y: button.layer?.isGeometryFlipped == true ? top : button.bounds.height - top - height,
                      width: button.bounds.width,
                      height: height)
    }

    /// Widens the item's window by the overhang, once, so the pill isn't
    /// clipped. Call before the item is ever lit: widening later visibly shifts
    /// the icon.
    @MainActor
    static func makeRoom(for button: NSStatusBarButton?) {
        guard SystemLook.isMacOS27OrLater, let button, let window = button.window else { return }
        guard button.bounds.width < window.frame.width || widened != window.frame.width else { return }
        var frame = window.frame
        frame.origin.x -= overhang
        frame.size.width += 2 * overhang
        window.setFrame(frame, display: false)
        widened = frame.width
        button.frame = NSRect(x: 0, y: button.frame.minY, width: frame.width, height: button.frame.height)
    }

    /// The widened window width, so the widening happens once per layout.
    @MainActor private static var widened: CGFloat = 0

    private static let name = "crisp.statusItemHighlight"

    private static func pill(in host: CALayer) -> CALayer? {
        host.sublayers?.first { $0.name == name }
    }

    private static func add(to host: CALayer) -> CALayer {
        let layer = CALayer()
        layer.name = name
        layer.backgroundColor = NSColor(white: 1, alpha: lift / 255).cgColor
        layer.compositingFilter = "plusL"
        host.addSublayer(layer)
        return layer
    }
}
