// Crisp/Services/EDROverlayManager.swift
import AppKit
import CoreGraphics
import Metal
import QuartzCore

/// Fullscreen invisible EDR overlay per display that multiplies all content
/// beneath it into the HDR headroom, brightening the whole desktop beyond the
/// SDR maximum. Lifecycle mirrors NotchOverlayManager: one borderless
/// click-through window per CGDirectDisplayID, torn down when the screen goes
/// away. Content is a uniform EDR color (value > 1.0) in a CAMetalLayer with a
/// multiply compositing filter. WindowServer only honors that filter while the
/// window keeps presenting: about a second after the last present it promotes
/// the window to direct scanout and drops the filter, so the raw near-white
/// EDR layer would cover the screen. Each overlay therefore renders
/// continuously at 5fps (a periodic Timer per window) for as long as it
/// exists, not just when the factor changes.
@MainActor
final class EDROverlayManager {
    static let shared = EDROverlayManager()

    private struct Overlay {
        let window: NSWindow
        let layer: CAMetalLayer
        var factor: Double
        var timer: Timer?
        var revealed: Bool = false
        var presentsPending: Int = 0
        var lastPresentActivity: Date = Date()
        var renderPending: Bool = false
    }

    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Apply a multiplier to a display. Once a window exists it stays alive
    /// even at factor 1.0 (identity): closing and reopening the EDR surface
    /// exits and re-enters EDR mode, which can visibly flash the display, so
    /// crossing the 100% boundary must not churn windows. Explicit teardown
    /// goes through removeOverlay. Returns false when an overlay was needed
    /// but could not be created (no Metal device, no screen), so callers can
    /// revert the toggle.
    @discardableResult
    func setFactor(_ factor: Double, for displayID: CGDirectDisplayID) -> Bool {
        let clamped = max(1.0, factor)
        if overlays[displayID] == nil {
            // Nothing to show and nothing to keep alive.
            guard clamped > 1.001 else { return true }
            guard makeOverlay(for: displayID) else { return false }
        }
        guard var overlay = overlays[displayID] else { return false }
        // Skip sub-0.5% changes to avoid pointless re-renders during fades.
        guard abs(overlay.factor - clamped) > 0.005 else { return true }
        overlay.factor = clamped
        overlays[displayID] = overlay
        render(for: displayID)
        return true
    }

    func removeOverlay(for displayID: CGDirectDisplayID) {
        overlays[displayID]?.timer?.invalidate()
        overlays[displayID]?.window.close()
        overlays.removeValue(forKey: displayID)
    }

    func removeAll() {
        for id in Array(overlays.keys) { removeOverlay(for: id) }
    }

    /// Re-render every overlay (Metal drawables can be lost across sleep).
    func rerenderAll() {
        for displayID in Array(overlays.keys) { render(for: displayID) }
    }

    private func makeOverlay(for displayID: CGDirectDisplayID) -> Bool {
        guard let screen = NSScreen.screen(for: displayID),
              let device else { return false }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // Shielding level: WindowServer only promotes an idle window to direct
        // scanout (dropping the compositingFilter) once nothing above it needs
        // the window to keep compositing; sitting at the shielding level, same
        // as BrightIntosh (the shipping open-source app this technique is
        // adapted from), keeps that promotion from ever mattering.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .stationary, .canJoinAllSpaces, .ignoresCycle,
            .canJoinAllApplications, .fullScreenAuxiliary
        ]
        window.hasShadow = false
        // Hidden until the first frame actually lands (see render/revealWindow
        // below), so the raw near-white EDR clear color never flashes before
        // the multiply filter is actually compositing over the desktop.
        window.alphaValue = 0

        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        metalLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        // Uniform color: a 1x1 drawable scaled to fullscreen costs nothing.
        metalLayer.drawableSize = CGSize(width: 1, height: 1)
        metalLayer.compositingFilter = "multiply"

        let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer = metalLayer
        window.contentView = host
        window.orderFrontRegardless()

        overlays[displayID] = Overlay(window: window, layer: metalLayer, factor: 1.0, timer: nil, revealed: false)

        // Continuous low-rate rendering keeps WindowServer from ever promoting
        // this window to direct scanout: re-present forever, at 5fps, for as
        // long as the overlay exists (matches BrightIntosh's MTKView-driven
        // approach; ours stays a CAMetalLayer + Timer to keep the diff small).
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            // Added to RunLoop.main below, so it fires on the main run loop.
            MainActor.assumeIsolated { self?.render(for: displayID) }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlays[displayID]?.timer = timer

        // Anti-flash fallback: reveal after a beat regardless, in case the
        // first frame's completion handler is slow to fire.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.revealWindow(for: displayID)
        }
        return true
    }

    private func render(for displayID: CGDirectDisplayID) {
        guard var overlay = overlays[displayID] else { return }
        // Frame self-heal: an HDR flip's reconfiguration can move this screen
        // while the one didChangeScreenParameters notification fires mid-
        // transition, leaving the overlay parked over a NEIGHBORING display
        // (observed as a multiplied strip on the Dell while boosting the AOC).
        // The keep-alive already runs at 5Hz; re-align whenever geometry
        // drifts instead of trusting a single notification.
        if let screen = NSScreen.screen(for: displayID), overlay.window.frame != screen.frame {
            overlay.window.setFrame(screen.frame, display: true)
            overlay.layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
        // Coalesce: at most two presents outstanding per overlay. Drag events
        // and the fast headroom poll call this at up to 120Hz; the layer's
        // drawable pool holds 3, so capping outstanding presents at 2 means
        // nextDrawable() always has a free drawable and never blocks the main
        // thread (the original above-100% slider lag). The presented handler
        // re-renders once with the latest factor, so nothing is lost. If
        // presents stop landing entirely (display asleep mid-flight), the
        // counter resets at most once per second so the keep-alive is never
        // silenced forever, without ever stacking unretired drawables.
        if overlay.presentsPending >= 2 {
            if Date().timeIntervalSince(overlay.lastPresentActivity) < 1.0 {
                overlay.renderPending = true
                overlays[displayID] = overlay
                return
            }
            overlay.presentsPending = 0
            overlay.lastPresentActivity = Date()
        }
        guard let commandQueue,
              let drawable = overlay.layer.nextDrawable() else { return }
        overlay.presentsPending += 1
        overlay.renderPending = false
        overlays[displayID] = overlay
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let f = overlay.factor
        pass.colorAttachments[0].clearColor = MTLClearColor(red: f, green: f, blue: f, alpha: 1.0)
        guard let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, var done = self.overlays[displayID] else { return }
                done.presentsPending = max(0, done.presentsPending - 1)
                done.lastPresentActivity = Date()
                self.overlays[displayID] = done
                if done.renderPending { self.render(for: displayID) }
            }
        }
        cmd.present(drawable)
        if !overlay.revealed {
            cmd.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    self?.revealWindow(for: displayID)
                }
            }
        }
        cmd.commit()
    }

    /// Makes the overlay window visible once its first frame has actually
    /// landed (or the anti-flash fallback fires), so the raw EDR clear color
    /// never shows before the multiply filter is compositing. Idempotent.
    private func revealWindow(for displayID: CGDirectDisplayID) {
        guard var overlay = overlays[displayID], !overlay.revealed else { return }
        overlay.revealed = true
        overlays[displayID] = overlay
        overlay.window.alphaValue = 1
    }

    @objc private func screenParametersChanged() {
        var toRemove: [CGDirectDisplayID] = []
        for (displayID, overlay) in overlays {
            guard let screen = NSScreen.screen(for: displayID) else {
                overlay.timer?.invalidate()
                overlay.window.close()
                toRemove.append(displayID)
                continue
            }
            overlay.window.setFrame(screen.frame, display: true)
            overlay.layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
        for id in toRemove { overlays.removeValue(forKey: id) }
    }
}
