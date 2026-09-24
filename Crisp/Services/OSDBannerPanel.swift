import AppKit
import SwiftUI

/// One banner window. Holds its model and the hide timer; OSDBannerService
/// owns placement and content.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerPanel: NSPanel {
    /// Only ever while the pointer is on the capsule, see setHovering.
    override var canBecomeKey: Bool { true }

    let model = OSDBannerModel()
    /// The capsule's backdrop layer, or nil when the private class was
    /// missing and the banner fell back to the flat grey. See startKeepAlive.
    var backdrop: CALayer?
    /// macOS 27's glass, or nil where the whole window fades instead.
    var glass: OSDGlass?
    /// The close badge and the layer it samples the desktop with.
    var badge: OSDBadgeView?
    var badgeBackdrop: CALayer?
    private var hideWork: DispatchWorkItem?
    /// Whether Crisp was the front app when the pointer arrived on the capsule.
    private var crispWasActive = false
    private var keepAliveWork: DispatchWorkItem?
    /// Where the banner sits when it is up. Kept so a pointer arriving during
    /// the exit can bring it back to the frame it was leaving.
    private var restFrame: NSRect = .zero
    private var growTimer: Timer?
    private var growBegin = 0.0

    /// Grows the capsule inside a window already at its final frame: a window
    /// frame animation is pixel-snapped and jumps, so the views inside carry
    /// the grow instead, stepped at 120 Hz.
    private func growCapsule() {
        growTimer?.invalidate()
        growBegin = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(growStep), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        growTimer = timer
        growStep()
    }

    @objc private func growStep() {
        guard let glass, let root = contentView else { growTimer?.invalidate(); return }
        let t = CACurrentMediaTime() - growBegin
        let p = OSDBannerService.glassGrowInCurve.solve(min(t / OSDBannerService.glassGrowInDuration, 1))
        let final = root.bounds.insetBy(dx: OSDBannerService.windowMargin, dy: OSDBannerService.windowMargin)
        // The capsule grows into place pinned at the middle of its top edge.
        // The glass and rim are resized, not scaled; the content is drawn at
        // final size and scaled down instead, or its refraction band draws
        // thinner than it settles at, a hard line that lifts as the grow ends.
        // Measured: see docs/osd-notes.md (Capsule grow (macOS 27)).
        let inset = CGSize(width: OSDBannerService.entryInset.width * (1 - p),
                           height: OSDBannerService.entryInset.height * (1 - p))
        let size = CGSize(width: final.width - inset.width, height: final.height - inset.height)
        let rect = CGRect(x: final.midX - size.width / 2, y: final.maxY - size.height,
                          width: size.width, height: size.height)
        let scale = size.width / final.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.view.frame = rect
        glass.bevel.frame = rect
        if let content = glass.faded.first?.delegate as? NSView {
            content.frame = final
            if let layer = content.layer {
                let pivot = CGPoint(x: content.bounds.width / 2, y: content.bounds.height)
                var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
                transform = CATransform3DScale(transform, scale, scale, 1)
                layer.transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            }
        }
        CATransaction.commit()
        if t >= OSDBannerService.glassGrowInDuration { growTimer?.invalidate(); growTimer = nil }
    }
    /// When the running entry ends. `alphaValue` reads the interpolated value
    /// during a window animation, so a second press inside the entry would
    /// otherwise restart it from the shrunk frame.
    private var entryEnds = Date.distantPast
    /// Whether an exit has run since the last reveal. A press lands inside one
    /// often, one hold after the press before it. Nothing clears this when the
    /// exit ends on its own: by then stopping it is a pair of no-ops.
    var exiting = false

    /// Places the banner at `frame` and brings it to full opacity, restarting
    /// the hide timer. A hidden or fading banner plays the system HUD's entry;
    /// a visible one only moves, so key repeat animates nothing.
    func reveal(at frame: NSRect) {
        hideWork?.cancel()
        keepAliveWork?.cancel()
        startKeepAlive()
        restFrame = frame
        // A banner on screen is a control: the pointer gets a knob on the
        // track and a close badge, as the system HUD does. It takes clicks
        // only while the pointer is on the capsule, see setHovering.
        ignoresMouseEvents = !model.hovering
        if exiting {
            // A second animation does not replace one in flight; the exit
            // would win and the banner would blink out and back. Stop it
            // where it is (alphaValue still reads 1 for the first frames,
            // hence the flag) and go up from there.
            stopAnimations()
            exiting = false
            // Clear the stale entry window from before the exit, or the
            // branch below is skipped and the banner strands dim.
            entryEnds = .distantPast
        }
        if Date() < entryEnds {
            // Re-aim a grow in flight: it targets the frame it started for,
            // which is stale if the menu bar item moved or the screen
            // changed between two presses.
            if frame != self.frame { setFrame(frame, display: false, animate: true) }
        } else if alphaValue < 1 {
            entryEnds = Date().addingTimeInterval(OSDBannerService.fadeInDuration)
            // Only from hidden: caught mid-exit the banner is on screen, and
            // dropping it back to the entry frame is a jump the eye sees.
            if alphaValue == 0 {
                setFrame(Self.hidden(frame, inset: OSDBannerService.entryInset), display: false)
                if let glass {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    glass.rim.opacity = Float(OSDBannerService.glassRimStart)
                    CATransaction.commit()
                }
            }
            orderFrontRegardless()
            if glass != nil {
                // The window goes to its final frame at once and the capsule
                // inside grows, see growCapsule.
                setFrame(frame, display: false)
                growCapsule()
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = OSDBannerService.growDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().setFrame(frame, display: true)
                }
            }
            if glass != nil {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = OSDBannerService.glassWindowInDuration
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 0.26, 0.35, 1)
                    animator().alphaValue = 1
                }
                showGlass(true)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = OSDBannerService.fadeInDuration
                    ctx.timingFunction = OSDBannerService.fadeInCurve
                    animator().alphaValue = 1
                }
            }
        } else {
            setFrame(frame, display: false)
        }
        scheduleHide()
    }

    /// The hold before the banner leaves, restarted by every press and by the
    /// pointer leaving the capsule.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.hovering else { return }
            self.fadeOut()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OSDBannerService.visibleDuration, execute: work)
    }

    /// The pointer arriving on the capsule or leaving it holds the banner up,
    /// matching the system HUD, and can bring back one already leaving.
    /// Measured: see docs/osd-notes.md (Hover hold).
    func setHovering(_ hovering: Bool) {
        // Hidden means alpha 0, not gone: the window is still there, so it
        // must not un-hide on a stray hover, and a banner fading under
        // Crisp's own panel must not steal key from the panel.
        if hovering && (alphaValue == 0 || BrightnessHUDService.shared.suppressed) { return }
        guard model.hovering != hovering else { return }
        model.hovering = hovering
        // The window is wider than the capsule (see windowMargin) and takes
        // every click inside it regardless of view hitTest, so clickability
        // is gated here instead, on the tracking area's hover state.
        ignoresMouseEvents = !hovering
        // AppKit only draws the real slider (glass knob, bright line) in a key
        // window; see OSDBannerView.track. Key only while the pointer is on
        // the capsule, handed back on the way out, or every brightness press
        // would steal the keyboard from whatever is in front.
        if hovering {
            // Give the keyboard back only to the app it came from: Crisp is
            // its own app in front while an update window or About is up.
            crispWasActive = NSApp.isActive
            makeKey()
        } else if isKeyWindow && !crispWasActive {
            NSApp.deactivate()
        }
        OSDBannerService.shared.hoverChanged(hovering)
        fadeBadge(to: hovering)
        if hovering {
            hideWork?.cancel()
            if exiting || alphaValue < 1 { reveal(at: restFrame) }
        } else {
            scheduleHide()
        }
    }

    /// The badge fades and only fades; the knob and the fill are not animated.
    /// Measured: see docs/osd-notes.md (Badge fade).
    private func fadeBadge(to shown: Bool) {
        guard let badge else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = shown ? 0.29 : 0.35
            ctx.timingFunction = shown
                ? CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
                : CAMediaTimingFunction(name: .linear)
            badge.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// The close badge: the banner goes at once, on the same exit.
    func dismiss() {
        setHovering(false)
        hideWork?.cancel()
        OSDBannerService.shared.dismissed(self)
        fadeOut()
    }

    /// Keeps the backdrop sampling while the banner is up. WindowServer stops
    /// compositing a screen with nothing changing on it, so a still backdrop
    /// (holding brightness at 100 percent, say) goes dark and stays dark; an
    /// animation too small to see keeps the layer rendering instead
    /// (EDROverlayManager fights the same promotion by re-presenting at 5 fps).
    private static let keepAliveKey = "crispBannerKeepAlive"

    private func startKeepAlive() {
        for layer in [backdrop, badgeBackdrop].compactMap({ $0 })
        where layer.animation(forKey: Self.keepAliveKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.999
            pulse.duration = 0.25
            pulse.autoreverses = true
            pulse.repeatCount = .greatestFiniteMagnitude
            layer.add(pulse, forKey: Self.keepAliveKey)
        }
    }

    /// Opens or closes the glass: its blur, bend and tint and the content
    /// each go from wherever they are, so a press caught mid-exit turns them
    /// round.
    private func showGlass(_ shown: Bool) {
        guard let glass else { return }
        let service = OSDBannerService.self
        // The label sits where it settles from the first frame: a sub-pixel
        // hold on a 1x screen is a whole pixel of text moving, which reads
        // as a pop.
        for layer in glass.faded {
            Self.ramp(layer, "opacity", to: shown ? 1.0 : 0.0,
                      duration: shown ? service.glassContentInDuration : service.glassOutDuration,
                      curve: shown ? service.glassContentInCurve : service.glassOutCurve)
        }
        if shown {
            // The rim runs its own ramp on top of the window's fade: a rise
            // from reveal()'s reset value on a cold entry, or a catch-up from
            // wherever it is when a press lands mid-exit.
            Self.ramp(glass.rim, "opacity", to: 1.0,
                      duration: service.glassRimInDuration, curve: service.glassRimInCurve)
        } else {
            Self.ramp(glass.rim, "opacity", to: 0.0,
                      duration: service.glassRimOutDuration, curve: service.glassOutCurve)
        }
        openGlass(shown)
    }

    /// The glass view builds its layers only once its window is on screen, so
    /// on the first entry it stays unseen (rather than showing untuned) and
    /// this retries on later run loop turns.
    private func openGlass(_ shown: Bool, attempt: Int = 0) {
        guard let glass else { return }
        let service = OSDBannerService.self
        guard let layer = glass.tunedBackdrop() else {
            if shown && attempt < 10 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.exiting else { return }
                    self.openGlass(true, attempt: attempt + 1)
                }
            }
            return
        }
        glass.view.alphaValue = 1
        if backdrop !== layer {
            backdrop = layer
            startKeepAlive()
        }
        let curve = shown ? service.glassInCurve : service.glassOutCurve
        let inTime = service.glassInDuration
        glass.ramp(layer, [
            .init("inputBlurRadius", shown ? service.glassBlurStep : service.glassBlur.closed,
                  shown ? service.glassBlurStepDuration : service.glassBlurOutDuration,
                  shown ? service.glassInCurve : curve),
            .init("inputBlurRadius", shown ? service.glassBlur.open : service.glassBlur.closed,
                  shown ? service.glassBlurRiseDuration : 0.01,
                  shown ? service.glassBlurInCurve : curve,
                  delay: shown ? service.glassBlurRiseDelay : 0.01),
            .init("inputInnerRefractionHeight",
                  shown ? service.glassRefractionHeight.open : service.glassRefractionHeight.closed,
                  shown ? service.glassRefractionHeightDuration : service.glassBendOutDuration,
                  shown ? service.glassBendInCurve : curve),
            .init("inputInnerRefractionAmount", shown ? service.glassBend.open : service.glassBend.closed,
                  shown ? service.glassBendInDuration : service.glassBendOutDuration,
                  shown ? service.glassBendInCurve : curve),
            .init("inputFaceOpacity", shown ? service.glassTint.open : service.glassTint.closed,
                  shown ? inTime : service.glassTintOutDuration, curve),
            .init("inputKeyFillHighlightAmount",
                  shown ? service.glassHighlight.open : service.glassHighlight.closed,
                  shown ? service.glassRimInDuration : service.glassRimOutDuration,
                  shown ? service.glassRimInCurve : curve)
        ] + shimmerLegs(shown: shown, curve: curve))
    }

    /// The shimmer: the backdrop samples at full resolution through the entry
    /// and steps down once the rest has settled. The exit puts it back, so the
    /// next entry starts sharp again.
    private func shimmerLegs(shown: Bool, curve: CAMediaTimingFunction) -> [OSDGlassRamp.Leg] {
        let service = OSDBannerService.self
        guard service.drawsMacOS27Capsule else { return [] }
        guard shown else {
            // Nothing on the way out: sharpening the backdrop again under a
            // leaving capsule reads as something popping in. The entry's
            // first leg resets it while the window is still alpha 0.
            return []
        }
        return [
            .init("backdropScale", service.glassBackdropScale, 0.01, curve),
            .init("backdropScale", service.glassShimmerScale, service.glassShimmerDuration,
                  service.glassSettleInCurve, delay: service.glassShimmerDelay),
            .init("backdropScale", service.glassBackdropScale, service.glassShimmerReturnDuration,
                  service.glassSettleInCurve, delay: service.glassShimmerReturnDelay)
        ]
    }

    private static func ramp(_ layer: CALayer, _ keyPath: String, to value: Any,
                             duration: TimeInterval, curve: CAMediaTimingFunction) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = curve
        // Held at its end value, not removed: with the window still fading
        // out, a finished ramp coming off the glass drew a wide, untoned blur
        // for the rest of the fade. The next ramp on the key replaces it.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
        CATransaction.commit()
    }

    /// Leaves the window where the animations have it and lets them go.
    private func stopAnimations() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            animator().alphaValue = alphaValue
            animator().setFrame(frame, display: false)
        }
    }

    private func fadeOut() {
        exiting = true
        let service = OSDBannerService.self
        let reversed = glass != nil
        let duration = reversed ? service.glassWindowOutDuration : service.fadeOutDuration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = reversed ? service.glassWindowOutCurve : service.fadeOutCurve
            animator().alphaValue = 0
        }
        showGlass(false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reversed ? service.glassOutDuration : service.exitShrinkDuration
            ctx.timingFunction = reversed ? service.glassOutCurve : service.exitShrinkCurve
            animator().setFrame(Self.hidden(frame,
                                            inset: reversed ? service.glassExitInset : service.exitInset,
                                            lift: reversed ? service.glassExitInset.height : service.hiddenLift),
                                display: true)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.backdrop?.removeAnimation(forKey: Self.keepAliveKey)
            self?.badgeBackdrop?.removeAnimation(forKey: Self.keepAliveKey)
            // Hidden means alpha 0, not off screen, so the window is still
            // there to take a click nobody meant for it.
            self?.ignoresMouseEvents = true
            self?.model.hovering = false
            self?.badge?.alphaValue = 0
        }
        keepAliveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The hidden frame: `frame` inset and lifted by the inset height, which
    /// anchors the top edge (only the bottom moves), matching the system.
    private static func hidden(_ frame: NSRect, inset: CGSize,
                               lift: CGFloat = OSDBannerService.hiddenLift) -> NSRect {
        frame.insetBy(dx: inset.width, dy: inset.height).offsetBy(dx: 0, dy: lift)
    }
}

/// Reads the pointer arriving on the banner and leaving it. SwiftUI's onHover
/// tracks in the key window, which this panel is not always, so the tracking
/// area runs always-active instead. hitTest returns nil so clicks fall
/// through to the track and the close badge.
@available(macOS 26.0, *)
final class BannerHoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The capsule rim on macOS 27, where the system stopped drawing one flat
/// white line around the edge: bright along the top and bottom, dark at the
/// rounded ends (drawn by the glass view's own edge, not here), added on as
/// the only blend that reaches a window-server-composited backdrop.
/// Measured: see docs/osd-notes.md (Rim (macOS 27, OSDBevelView)).
@available(macOS 26.0, *)
final class OSDBevelView: NSView {
    /// The ring only, not the glow: the rim's entry ramp runs on this layer,
    /// and a glow ramping with it would lift the bottom edge band late.
    let rings = CALayer()
    private let edgeRing = CALayer()
    private let edges = CAGradientLayer()
    private let innerMask = CALayer()
    private let inner = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        let clear = NSColor.clear.cgColor
        // Bright along the top and bottom only, nothing at the ends, added on
        // rather than blended over (see OSDBannerService.rimEdgeColor).
        let edgeStop = OSDBannerService.rimEdgeShare
        let colour = OSDBannerService.rimEdgeColor.cgColor
        edges.colors = [clear, colour, colour, clear]
        edges.locations = [0, NSNumber(value: edgeStop), NSNumber(value: 1 - edgeStop), 1]
        edges.startPoint = CGPoint(x: 0, y: 0.5)
        edges.endPoint = CGPoint(x: 1, y: 0.5)
        edges.compositingFilter = "plusL"
        // A short inner glow, added on like the edges, over the capsule
        // rather than over the ring (see docs/osd-notes.md, Rim (macOS 27)).
        inner.colors = [OSDBannerService.rimGlowColor.cgColor, clear,
                        clear, OSDBannerService.rimGlowColor.cgColor]
        let glow = OSDBannerService.rimGlowShare
        inner.locations = [0, NSNumber(value: glow), NSNumber(value: 1 - glow), 1]
        inner.startPoint = CGPoint(x: 0.5, y: 0)
        inner.endPoint = CGPoint(x: 0.5, y: 1)
        inner.compositingFilter = "plusL"
        innerMask.cornerRadius = OSDBannerService.cornerRadius
        innerMask.cornerCurve = .continuous
        innerMask.backgroundColor = NSColor.white.cgColor
        inner.mask = innerMask
        layer.addSublayer(inner)
        // A mask is a layer with nothing but a border, so the ring follows the
        // same continuous corner the capsule is drawn with; a path would have
        // to rebuild that curve by hand.
        edgeRing.cornerRadius = OSDBannerService.cornerRadius
        edgeRing.cornerCurve = .continuous
        edgeRing.borderColor = NSColor.white.cgColor
        edges.mask = edgeRing
        rings.addSublayer(edges)
        layer.addSublayer(rings)
        layoutRim()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRim()
    }

    /// The window grows and shrinks through the entry and the exit, and layers
    /// do not follow a resize on their own.
    private func layoutRim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeRing.frame = CGRect(origin: .zero, size: bounds.size)
        edgeRing.borderWidth = OSDBannerService.rimWidth
        edges.frame = CGRect(origin: .zero, size: bounds.size)
        rings.frame = CGRect(origin: .zero, size: bounds.size)
        inner.frame = CGRect(origin: .zero, size: bounds.size)
        innerMask.frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
    }
}
