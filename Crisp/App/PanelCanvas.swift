import AppKit
import SwiftUI
import os.log

// The split-canvas panel resize engine. Architecture and the failure map that
// forced every rule here: docs/panel-resize.md. In short: the shell layer, not
// the window, is the only per-tick animator; SwiftUI never animates geometry;
// blocks are stacked by explicit integral frames each tick, so content below a
// toggling section rides the shell edge atomically. The window frame itself
// changes only at rest.

/// Top-left origin so blocks stack downward from the pinned top edge and a
/// clip's height change reveals its content top-first, curtain style.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Do NOT disable postsFrameChangedNotifications: NSHostingView needs
        // ancestor frame-change notifications for hit-zone mapping. See
        // docs/panel-resize.md (failure map #8).
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Window-filling root, larger than the visible panel: transparent margins
/// host the layer shadow, and the window itself never resizes mid-animation
/// (docs/panel-resize.md, "Why the public paths fail"). Clicks in the margins
/// are outside-clicks, closing the panel like native menus.
final class PanelRootView: NSView {
    weak var shell: NSView?
    var onOutsideClick: (() -> Void)?

    private func isOutsideShell(_ event: NSEvent) -> Bool {
        guard let shell else { return false }
        return !shell.frame.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if isOutsideShell(event) { onOutsideClick?() } else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isOutsideShell(event) { onOutsideClick?() } else { super.rightMouseDown(with: event) }
    }
}

/// The scrollable region (everything above the footer). Manual offset scroll:
/// no elastic, no indicators, matching how the panel's ScrollView behaved.
/// ponytail: raw wheel deltas only; add momentum if it ever feels off.
final class PanelViewport: FlippedView {
    var onScroll: ((CGFloat) -> Void)?
    var isScrollable: () -> Bool = { false }
    override func scrollWheel(with event: NSEvent) {
        guard isScrollable() else { return }
        onScroll?(event.scrollingDeltaY)
    }
}

/// Vsync-locked critically damped spring on a scalar (the blocks' total
/// height). Every rule here is load-bearing, see docs/panel-resize.md (failure
/// map). Main actor: the link ticks on the main run loop, and PanelCanvas is
/// its only owner.
@MainActor
final class FrameSpring: NSObject {
    private var link: CADisplayLink?
    private var active = false
    private var lastTick: CFTimeInterval = 0
    private var t: Double = 0
    private var from: Double = 0
    private var target: Double = 0
    private var v0: Double = 0
    private(set) var velocity: Double = 0
    private let omega = 2 * Double.pi / Animation.panelResizeDuration
    var onTick: ((Double) -> Void)?
    var onSettle: (() -> Void)?

    func warm(view: NSView) {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// The link syncs to whatever display it was created on; recreate it when
    /// the panel moves screens, or a 165Hz monitor gets fed 120Hz updates
    /// (judder). Safe at open time: the link is hot long before the first toggle.
    func retarget(view: NSView) {
        link?.invalidate()
        link = nil
        warm(view: view)
    }

    func animate(from f: CGFloat, to tg: CGFloat) {
        from = Double(f)
        target = Double(tg)
        v0 = velocity
        t = 0
        // Resets lastTick to now: the link ticks (and updates lastTick) even
        // while idle, so skipping this burns a stale frame off t on the first
        // active tick.
        lastTick = CACurrentMediaTime()
        active = true
    }

    func cancel() {
        active = false
        velocity = 0
    }

    var isAnimating: Bool { active }

    /// Pauses (never invalidates) the link while hidden. See docs/panel-resize.md
    /// (failure map #2).
    func setPaused(_ paused: Bool) {
        link?.isPaused = paused
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = (now - lastTick) * 1000
        lastTick = now
        guard active else { return }
        // Wall time clamped to a short catch-up window. See docs/panel-resize.md
        // (failure map #3).
        let period = l.targetTimestamp - l.timestamp
        t += min(gap / 1000, 0.021)
        let e = exp(-omega * t)
        let d0 = from - target
        let a = v0 + omega * d0
        let x = target + (d0 + a * t) * e
        if abs(x - target) < 0.25 {
            active = false
            velocity = 0
            onTick?(target)
            PanelCanvas.log.log("settle gap=\(gap, format: .fixed(precision: 1))ms")
            onSettle?()
        } else {
            velocity = (a - omega * (d0 + a * t)) * e
            let start = CACurrentMediaTime()
            onTick?(x)
            let cost = (CACurrentMediaTime() - start) * 1000
            // Per-tick logging costs real budget at 165Hz; log misses only.
            let periodMs = (period > 0 && period < 0.05) ? period * 1000 : 8.3
            if gap > periodMs * 1.7 {
                PanelCanvas.log.log("miss gap=\(gap, format: .fixed(precision: 1))ms period=\(periodMs, format: .fixed(precision: 1))ms x=\(x, format: .fixed(precision: 1)) cost=\(cost, format: .fixed(precision: 1))ms")
            }
        }
    }
}

/// Hosting view for panel blocks; counts layout() passes so a flight can
/// report SwiftUI re-layouts triggered (issue #28). Read/reset on the main
/// thread only.
final class CountedHostingView: NSHostingView<AnyView> {
    nonisolated(unsafe) static var layoutCount = 0
    /// issue #28: mutes a static block's SwiftUI layout during a flight (its
    /// geometry is unchanged); forced live again at settle.
    var muteLayout = false
    override func layout() {
        Self.layoutCount += 1
        if muteLayout { return }
        super.layout()
    }
}

/// One block of panel content: a hosting view at natural size inside a clip
/// that animates between 0 and the content height. Fixed blocks are always
/// open; height still animates when content height changes.
@MainActor
final class PanelBlock {
    let id: String
    let clip: FlippedView
    let host: NSView
    var contentHeight: CGFloat = 0
    let isOpen: () -> Bool
    /// Displayed clip height right now (animates toward `target`).
    var current: CGFloat = 0
    /// Detail blocks paint their shaded band on the clip's layer (tintBands),
    /// not the SwiftUI content: fading it with the content left a bare-glass
    /// hole mid-collapse.
    var banded = false
    /// Keeps SwiftUI layout live during a flight even when height is static: a
    /// chevron's rotation needs per-frame render, and muting froze it until
    /// settle.
    var liveInFlight = false
    var target: CGFloat { isOpen() ? contentHeight : 0 }

    init(id: String, host: NSView, isOpen: @escaping () -> Bool) {
        self.id = id
        self.host = host
        self.isOpen = isOpen
        clip = FlippedView(frame: .zero)
        clip.addSubview(host)
    }
}

/// Owns the block stack, the scroll viewport, the footer, and the spring, and
/// keeps window frame + block frames consistent every tick.
@MainActor
final class PanelCanvas {
    nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "panelcanvas")
    /// For the spring's tick log sub-timings (single instance in practice).
    static weak var shared: PanelCanvas?

    let width: CGFloat = 308
    /// Transparent window margins hosting the layer shadow.
    let sideMargin: CGFloat = 40
    let bottomMargin: CGFloat = 48
    /// Room above the shell for the twin's rim stroke: flush to the window top,
    /// the outset twin would clip and the top rim line would vanish in flight.
    let topMargin: CGFloat = 2
    private let topInset: CGFloat = 8
    private let docTopInset: CGFloat = 4
    private let docBottomInset: CGFloat = 4
    /// Slack above each block's content height so BlockHost's top-glue pins
    /// content to the top during a mid-reveal curtain. See docs/panel-resize.md
    /// (hostSlack).
    private let hostSlack: CGFloat = 1200

    private(set) var blocks: [PanelBlock] = []
    private var footer: PanelBlock?
    let viewport = PanelViewport(frame: .zero)
    let doc = FlippedView(frame: .zero)
    private let spring = FrameSpring()
    private weak var panel: NSPanel?
    private weak var shellView: NSView?
    private weak var shadowView: NSView?
    weak var shadowMask: CAShapeLayer?
    /// macOS 27's own bottom rim line, drawn here since the system doesn't.
    /// See docs/panel-resize.md (bottomEdge).
    private let bottomEdge = CALayer()
    /// True when the shadow twin's bottom stroke is cut (macOS 27 dark mode).
    /// Cached, not read per tick. See docs/panel-resize.md (bottomEdge).
    private var hidesBottomRim = false
    /// Fitted against a native menu bar pill. See docs/panel-resize.md (bottomEdge).
    private static let bottomEdgeColor = NSColor(white: 1, alpha: 0.175)
    private static let bottomEdgeWidth: CGFloat = 1
    /// Settled shell height from the last layout, for windowTight().
    private var lastShellH: CGFloat = 0
    var isShown: () -> Bool = { false }

    /// Screen-space anchor of the pinned top edge, set by positionPanel.
    private var anchorTopY: CGFloat = 0
    private var anchorX: CGFloat = 0

    private var animFrom: [CGFloat] = []
    /// Captured at animate start; per-tick math must never read live block
    /// targets. See docs/panel-resize.md (failure map #7).
    private var animTarget: [CGFloat] = []
    private var animTargetSum: CGFloat = 0
    private var animFromSum: CGFloat = 0
    /// Blocks fading with this flight: opening from zero fades in, closing to
    /// zero fades out, tracking the spring. Mirrors the .opacity transition
    /// SwiftUI gives in-block curtains.
    private var fadeInIdx: Set<Int> = []
    private var fadeOutIdx: Set<Int> = []
    private var scrollOffset: CGFloat = 0
    private var animatePending = false
    /// The shell presents its frame change in the CURRENT CATransaction;
    /// SwiftUI presents its curtain render ONE frame later. Applying each tick
    /// one frame late lands both on the same frame. Reset per flight.
    private var pendingScalar: CGFloat?
    private var flightTicks = 0
    private var flightHostLayouts0 = 0
    /// Window height last handed to setFrame; a mismatch at the next layout
    /// means someone else resized the window (EXT in the log).
    private var lastSetWindowH: CGFloat = -1
    /// Sub-timings of the last layoutNow, for the tick log.
    private(set) var lastLoopMs: Double = 0
    private(set) var lastWinMs: Double = 0
    /// True only during warm-up pre-paint, so every block lies inside the
    /// viewport and genuinely draws once.
    private var ignoreCap = false

    func install(shell: NSView, shadow: NSView, panel: NSPanel) {
        PanelCanvas.shared = self
        self.panel = panel
        self.shellView = shell
        self.shadowView = shadow
        viewport.addSubview(doc)
        shell.addSubview(viewport)
        if SystemLook.isMacOS27OrLater {
            bottomEdge.backgroundColor = Self.bottomEdgeColor.cgColor
            bottomEdge.zPosition = 1
            shell.layer?.addSublayer(bottomEdge)
        }
        viewport.onScroll = { [weak self] delta in
            guard let self else { return }
            self.scrollOffset -= delta
            self.layoutNow()
        }
        viewport.isScrollable = { [weak self] in
            guard let self else { return false }
            return self.doc.frame.height > self.viewport.frame.height + 0.5
        }
        spring.warm(view: shell)
        spring.onTick = { [weak self] x in
            guard let self else { return }
            self.flightTicks += 1
            // One-frame buffer: apply the previous tick, hold this one (pendingScalar).
            // onSettle supersedes with exact targets, so the last frame lands precisely.
            if let prev = self.pendingScalar { self.applyScalar(prev) }
            self.pendingScalar = CGFloat(x)
        }
        spring.onSettle = { [weak self] in
            guard let self, self.animTarget.count == self.blocks.count else { return }
            for (i, b) in self.blocks.enumerated() { b.current = self.animTarget[i] }
            PanelCanvas.log.log("flight ticks=\(self.flightTicks) hostLayouts=\(CountedHostingView.layoutCount - self.flightHostLayouts0) blocks=\(self.blocks.count)")
            self.layoutNow()
            // Unmute and replay frame notifications: one full host resync at
            // rest, refreshing the hit-zone mappings deferred during the flight.
            self.endFlightMuting()
            self.windowTight()
            self.useRestShadow()
        }
    }

    func setBlocks(_ newBlocks: [PanelBlock], footer newFooter: PanelBlock) {
        for b in blocks { b.clip.removeFromSuperview() }
        footer?.clip.removeFromSuperview()
        blocks = newBlocks
        footer = newFooter
        for b in blocks { doc.addSubview(b.clip) }
        if let shell = viewport.superview { shell.addSubview(newFooter.clip) }
        tintBands()
        measureAll()
        for b in blocks { b.current = b.target }
        footer?.current = footer?.target ?? 0
    }

    /// fittingSize right after init is nondeterministic; force layout first.
    /// See docs/panel-resize.md (failure map #5).
    func measureAll() {
        for b in blocks + [footer].compactMap({ $0 }) {
            b.host.layoutSubtreeIfNeeded()
            b.contentHeight = b.host.fittingSize.height
        }
    }

    /// SwiftUI reports a block's natural height once (initial layout, a nested
    /// reveal's end state, presets changing); the spring then animates the clip
    /// to it, and layoutNow keeps content top-aligned during the reveal.
    func contentChanged(_ id: String, height: CGFloat) {
        // height 0 is legitimate (the update row while no update is known).
        if let f = footer, f.id == id {
            guard abs(f.contentHeight - height) > 0.5 else { return }
            f.contentHeight = height
            f.current = height
            requestApply()
            return
        }
        guard let b = blocks.first(where: { $0.id == id }),
              abs(b.contentHeight - height) > 0.5 else { return }
        b.contentHeight = height
        // A height report is a nested curtain animating inside this block:
        // it needs live SwiftUI layout even mid-flight, so lift its mute.
        if let host = b.host as? CountedHostingView, host.muteLayout {
            host.muteLayout = false
            host.needsLayout = true
        }
        requestApply()
    }

    /// Section state changed (or content resized): animate to targets when the
    /// panel is visible, snap silently when hidden. Coalesces bursts (one
    /// user action can flip several published properties).
    func requestApply() {
        guard !animatePending else { return }
        animatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.animatePending = false
            if self.isShown() { self.animateToTargets() } else { self.snapToTargets() }
        }
    }

    func snapToTargets() {
        spring.cancel()
        pendingScalar = nil
        for b in blocks { b.current = b.target }
        if let f = footer { f.current = f.target }
        layoutNow()
        endFlightMuting()
        windowTight()
        useRestShadow()
    }

    private func animateToTargets() {
        let fromSum = blocks.reduce(0) { $0 + $1.current }
        let targetSum = blocks.reduce(0) { $0 + $1.target }
        if let f = footer { f.current = f.target }
        guard abs(targetSum - fromSum) > 0.5 else {
            // No net height change (or nothing moved): settle exactly.
            for b in blocks { b.current = b.target }
            layoutNow()
            return
        }
        animFrom = blocks.map { $0.current }
        animTarget = blocks.map { $0.target }
        animFromSum = fromSum
        animTargetSum = targetSum
        pendingScalar = nil
        // Reveals fade the HOST (content), not the clip (which carries the band
        // for detail blocks): opening blocks start invisible; everything else
        // snaps opaque in case a prior flight was mid-fade.
        fadeInIdx.removeAll()
        fadeOutIdx.removeAll()
        for i in blocks.indices {
            if animFrom[i] == 0, animTarget[i] > 0 {
                fadeInIdx.insert(i)
            } else if animFrom[i] > 0, animTarget[i] == 0 {
                fadeOutIdx.insert(i)
            }
            let a: CGFloat = fadeInIdx.contains(i) ? 0 : 1
            if blocks[i].host.alphaValue != a { blocks[i].host.alphaValue = a }
        }
        // Grows the window once per toggle, here at rest so its WindowServer
        // cost cannot cause a jump; shadow swaps first so the grow's setFrame
        // is shadowless.
        useFlightShadow()
        windowForFlight()
        flightTicks = 0
        flightHostLayouts0 = CountedHostingView.layoutCount
        // Mutes static blocks' SwiftUI layout during the flight (walking every
        // host per clip resize is too costly at 60-165Hz); the animating
        // block's own host stays live for nested curtains. Unmuted again at
        // rest (endFlightMuting).
        for (i, b) in blocks.enumerated() {
            (b.host as? CountedHostingView)?.muteLayout =
                (animFrom[i] == animTarget[i]) && !b.liveInFlight
        }
        (footer?.host as? CountedHostingView)?.muteLayout = true
        PanelCanvas.log.log("animate from=\(fromSum, format: .fixed(precision: 1)) to=\(targetSum, format: .fixed(precision: 1)) v0=\(self.spring.velocity, format: .fixed(precision: 1))")
        spring.animate(from: fromSum, to: targetSum)
    }

    /// Unmute every host and force a real layout pass, so anything skipped
    /// mid-flight (hover states, live value changes, hit-zone mappings) lands
    /// now, at rest.
    private func endFlightMuting() {
        // Fades land fully opaque; a closed block is invisible through its
        // zero-height clip regardless of alpha.
        for b in blocks where b.host.alphaValue != 1 { b.host.alphaValue = 1 }
        fadeInIdx.removeAll()
        fadeOutIdx.removeAll()
        for b in blocks {
            (b.host as? CountedHostingView)?.muteLayout = false
            b.host.needsLayout = true
        }
        if let f = footer {
            (f.host as? CountedHostingView)?.muteLayout = false
            f.host.needsLayout = true
        }
    }

    private func applyScalar(_ x: CGFloat) {
        let denom = animTargetSum - animFromSum
        guard abs(denom) > 0.001, animFrom.count == blocks.count,
              animTarget.count == blocks.count else { return }
        let s = (x - animFromSum) / denom
        let fade = min(max(s, 0), 1)
        for i in fadeInIdx { blocks[i].host.alphaValue = fade }
        for i in fadeOutIdx { blocks[i].host.alphaValue = 1 - fade }
        for (i, b) in blocks.enumerated() {
            let exact = animFrom[i] + s * (animTarget[i] - animFrom[i])
            // Bounds by the flight's start height, not current contentHeight: a
            // nested reveal that shrinks its contentHeight before the flight
            // starts must still collapse in step with the curtain, not snap
            // instantly.
            b.current = min(max(exact, 0), max(animFrom[i], animTarget[i]))
        }
        layoutNow()
    }

    /// Stacks blocks with cumulative integral rounding, then derives the window
    /// frame. Only integral frames reach AppKit. See docs/panel-resize.md
    /// (failure map #4).
    func layoutNow() {
        guard let panel else { return }
        let t0 = CACurrentMediaTime()
        var cursor = docTopInset
        var exact = docTopInset
        for b in blocks {
            exact += b.current
            let y = exact.rounded()
            let h = y - cursor
            let clipR = NSRect(x: 0, y: cursor, width: width, height: h)
            if b.clip.frame != clipR { b.clip.frame = clipR }
            // hostSlack keeps this canvas taller than the content so BlockHost's
            // top-glue pins it to the top; the clip above reveals only `current`.
            let hostR = NSRect(x: 0, y: 0, width: width,
                               height: (b.contentHeight + hostSlack).rounded(.up))
            if b.host.frame != hostR { b.host.frame = hostR }
            cursor = y
        }
        let docH = cursor + docBottomInset
        let footerH = (footer?.current ?? 0).rounded()
        let cap = ignoreCap ? CGFloat.greatestFiniteMagnitude : PanelMetrics.maxContentHeight.rounded()
        let viewportH = min(docH, cap)
        let shellH = topInset + viewportH + footerH

        if lastSetWindowH >= 0, abs(panel.frame.height - lastSetWindowH) > 0.01 {
            PanelCanvas.log.log("EXT frame=\(panel.frame.height, format: .fixed(precision: 1)) expected=\(self.lastSetWindowH, format: .fixed(precision: 1))")
        }
        scrollOffset = min(max(scrollOffset, 0), max(0, docH - viewportH))
        let docR = NSRect(x: 0, y: -scrollOffset, width: width, height: docH)
        if doc.frame != docR { doc.frame = docR }
        // Shell is non-flipped: footer hugs the shell bottom, viewport spans
        // from 8pt below the shell top down to the footer.
        let vpR = NSRect(x: 0, y: footerH, width: width, height: viewportH)
        if viewport.frame != vpR { viewport.frame = vpR }
        if let f = footer {
            let fR = NSRect(x: 0, y: 0, width: width, height: footerH)
            if f.clip.frame != fR { f.clip.frame = fR }
            let fhR = NSRect(x: 0, y: 0, width: width, height: f.contentHeight.rounded(.up))
            if f.host.frame != fhR { f.host.frame = fhR }
        }
        let t1 = CACurrentMediaTime()
        // The window itself never moves here; only the shell and its shadow
        // twin do, atomically. Window frames change only at rest.
        let rootH = panel.contentView?.bounds.height ?? 0
        let shellR = NSRect(x: sideMargin, y: (rootH - topMargin - shellH).rounded(),
                            width: width, height: shellH)
        if let shell = shellView, shell.frame != shellR { shell.frame = shellR }
        // Bottom left of the shell's own layer, which is unflipped, so the
        // line stays put through a flight and only follows the panel width.
        let edgeR = CGRect(x: 0, y: 0, width: width, height: Self.bottomEdgeWidth)
        if bottomEdge.frame != edgeR {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bottomEdge.frame = edgeR
            CATransaction.commit()
        }
        // Shadow twin geometry (outset px, macOS 27 dark-mode bottom stroke,
        // blur cut above the top row): see docs/panel-resize.md (Shadow twin).
        let px = 1 / max(panel.backingScaleFactor, 1)
        let svR = hidesBottomRim ? NSRect(x: shellR.minX - px, y: shellR.minY,
                                          width: shellR.width + 2 * px, height: shellR.height + px)
                                 : shellR.insetBy(dx: -px, dy: -px)
        if let sv = shadowView, sv.frame != svR {
            sv.frame = svR
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let inner = CGRect(x: px, y: hidesBottomRim ? 0 : px, width: shellR.width, height: shellR.height)
            let innerPath = CGPath(roundedRect: inner, cornerWidth: 16, cornerHeight: 16, transform: nil)
            sv.layer?.shadowPath = innerPath
            sv.layer?.cornerRadius = 16 + px
            let maskR = CGRect(origin: .zero, size: svR.size)
            let p = CGMutablePath()
            p.addRect(CGRect(x: -60, y: -60, width: svR.width + 120, height: svR.height + 120))
            p.addPath(innerPath)
            p.addRect(CGRect(x: -60, y: svR.height + 3, width: svR.width + 120, height: 57))
            if let mask = shadowMask { mask.frame = maskR; mask.path = p }
            CATransaction.commit()
        }
        lastShellH = shellH
        lastLoopMs = (t1 - t0) * 1000
        lastWinMs = (CACurrentMediaTime() - t1) * 1000
    }

    /// Window frames are set ONLY here, at rest: even a shadowless transparent
    /// window resize is a WindowServer transaction kept out of the per-tick path.
    private func setWindowHeight(_ h: CGFloat) {
        guard let panel else { return }
        // h is the visible height below anchorTopY; the window extends topMargin
        // above it (rim headroom, covered by the menu bar).
        let fullHeight = h.rounded() + topMargin
        let f = NSRect(x: anchorX - sideMargin, y: anchorTopY + topMargin - fullHeight,
                       width: width + 2 * sideMargin, height: fullHeight)
        if panel.frame != f {
            panel.setFrame(f, display: false)
            lastSetWindowH = fullHeight
            layoutNow()
        }
    }

    /// Room for the whole flight, grown once at animate start (at rest).
    private func windowForFlight() {
        let footerH = (footer?.contentHeight ?? 0).rounded()
        setWindowHeight(topInset + PanelMetrics.maxContentHeight.rounded() + footerH + bottomMargin)
    }

    /// Hug the settled shell again, so the margin (whose clicks read as
    /// outside-clicks) covers as little screen as possible at rest.
    private func windowTight() {
        setWindowHeight(lastShellH + bottomMargin)
    }

    /// The panel wears the CA clone shadow at all times, in flight and at rest:
    /// switching between native and clone shadow per frame flashes at settle
    /// (they render on different schedules). See docs/panel-resize.md (Shadow twin).
    private func useFlightShadow() {
        // Disabled actions: raw layer changes implicitly animate (0.25s fade),
        // but the native shadow they replace vanishes instantly, reading as a
        // rim flash.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowView?.isHidden = false
        // Appearance read from NSApp, not the panel (still off screen, and
        // unresolved, when first applied). Rim, blur, and border values are
        // calibrated per mode: see docs/panel-resize.md (Shadow twin).
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // macOS 27 flattens the rim to the bottom edge only (bottomEdge draws it).
        let flat = SystemLook.isMacOS27OrLater
        shellView?.layer?.borderWidth = dark && !flat ? 1 : 0
        bottomEdge.isHidden = !dark
        hidesBottomRim = flat && dark
        shadowView?.layer?.borderColor = NSColor.black
            .withAlphaComponent(dark ? (flat ? 0.58 : 0.85) : 0.29).cgColor
        // A whole NSShadow, not a mutated color: AppKit only syncs the view's
        // shadow property onto its layer on a display pass.
        let menuShadow = NSShadow()
        menuShadow.shadowColor = NSColor.black
            .withAlphaComponent(dark ? 0.37 : (flat ? 0.08 : 0.21))
        menuShadow.shadowBlurRadius = 8.5
        menuShadow.shadowOffset = NSSize(width: 0, height: -4)
        shadowView?.shadow = menuShadow
        CATransaction.commit()
        panel?.hasShadow = false
    }

    /// Settle path: keep the clone, just refresh appearance-tied colors.
    private func useRestShadow() {
        useFlightShadow()
    }

    /// Re-applies the appearance-tied rim and shadow tints: useFlightShadow only
    /// runs on a flight or settle, so a light/dark switch (or first open, before
    /// launch appearance resolves) would otherwise show the wrong mode's rim.
    func refreshAppearance() {
        guard panel != nil else { return }
        useRestShadow()
        tintBands()
    }

    /// Paints the detail band (labelColor at 8%, matching the SwiftUI
    /// Color.primary band the detail rows show) on banded blocks' clip layers,
    /// resolved against the current appearance.
    func tintBands() {
        let appearance = shellView?.effectiveAppearance ?? NSApp.effectiveAppearance
        var band = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        appearance.performAsCurrentDrawingAppearance {
            band = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
        for b in blocks where b.banded {
            b.clip.wantsLayer = true
            b.clip.layer?.backgroundColor = band
        }
    }

    /// Screen rect of the VISIBLE panel. The window frame includes the
    /// transparent shadow margins, so outside-click tests use this.
    func visibleScreenFrame() -> NSRect {
        guard let panel, let shell = shellView, let root = panel.contentView else { return .zero }
        return panel.convertToScreen(root.convert(shell.frame, to: nil))
    }

    func setAnchor(topY: CGFloat, x: CGFloat) {
        anchorTopY = topY.rounded()
        anchorX = x.rounded()
    }

    private weak var linkScreen: NSScreen?

    /// Re-sync the spring's display link to the screen the panel is on now.
    func retargetLinkIfNeeded() {
        guard let panel, let screen = panel.screen, let v = panel.contentView,
              screen !== linkScreen else { return }
        spring.retarget(view: v)
        linkScreen = screen
        PanelCanvas.log.log("link fps=\(screen.maximumFramesPerSecond)")
    }

    /// Stops vsync wakeups while hidden (idle ticks aren't free at 60-165Hz).
    /// Snaps any in-flight animation first so a paused link can't strand
    /// onSettle's cleanup.
    func parkSpring() {
        if spring.isAnimating { snapToTargets() }
        spring.setPaused(true)
    }

    func wakeSpring() {
        spring.setPaused(false)
    }

    /// Warm-up pre-paint: draw every block once while the panel is invisible
    /// so no first reveal is ever a first paint (failure map item 6).
    func prePaint() {
        ignoreCap = true
        for b in blocks { b.current = b.contentHeight }
        footer?.current = footer?.contentHeight ?? 0
        // The window must hold EVERY block at full height for this one paint.
        let needed = blocks.reduce(topInset + docTopInset + docBottomInset) { $0 + $1.contentHeight }
            + (footer?.contentHeight ?? 0) + bottomMargin
        setWindowHeight(needed.rounded())
        layoutNow()
        panel?.display()
        ignoreCap = false
        snapToTargets()
    }
}
