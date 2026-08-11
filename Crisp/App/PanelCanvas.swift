import AppKit
import SwiftUI
import os.log

// The split-canvas panel resize engine. Architecture and the failure map that
// forced every rule here: docs/panel-resize.md. In short: the window frame is
// the ONLY animator; SwiftUI never animates geometry; blocks are stacked by
// explicit integral frames each tick, so content below a toggling section
// rides the window edge atomically.

/// Top-left origin so blocks stack downward from the pinned top edge and a
/// clip's height change reveals its content top-first, curtain style.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Do NOT disable postsFrameChangedNotifications here: NSHostingView
        // listens for ancestor frame changes to keep its window-coordinate
        // mapping fresh; without them, hit zones go stale after blocks move
        // (click dead zones near the panel edges).
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Window-filling root. The window is LARGER than the visible panel: the
/// transparent margins host the layer shadow, and the window itself never
/// resizes while an animation is in flight (the WindowServer prices every
/// per-frame resize of a shadowed transparent window at 5-9ms, the measured
/// root cause of every animated-resize cadence failure). Clicks landing in
/// the margins are outside-clicks: close the panel, like native menus
/// consuming the dismissing click.
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
/// height). Every rule is load-bearing (docs/panel-resize.md):
/// frame-paced time (one refresh period per tick, never wall time), a link
/// created once and never invalidated, velocity carry across retargets.
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

    /// The link syncs to whatever display it was created on. Recreate it when
    /// the panel lands on a different screen, or a 165Hz monitor gets fed
    /// 120Hz updates (uneven frame doubling, reads as judder). Safe at open
    /// time: the link is hot again long before the first toggle.
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
        // Start the clock at the flight's start, not the last idle vsync. The
        // link ticks continuously and updates lastTick even while inactive, so
        // without this the first active tick advanced t by a whole stale frame,
        // snapping the clip ~one frame ahead of the SwiftUI curtain it should
        // move in step with. That gap is invisible in 1.3.2 (the visible edge is
        // the curtain-driven content), but here the visible edge is this
        // spring-driven shell, so the inner content lagged the outer edge.
        lastTick = CACurrentMediaTime()
        active = true
    }

    func cancel() {
        active = false
        velocity = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = (now - lastTick) * 1000
        lastTick = now
        guard active else { return }
        // Wall-clock time clamped to a short catch-up window. A single missed
        // vsync advances full wall time (temporally correct, no speed error);
        // a genuine stall cannot teleport (clamp). Pure frame-pacing ran at
        // HALF speed through sustained 60Hz stretches (tall panel, per-tick
        // cost near the budget) and snapped to full speed when ticks
        // recovered, which read as a jump.
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

/// Hosting view for panel blocks, instrumented: counts layout() passes so a
/// flight can report how many SwiftUI host re-layouts it triggered (issue #28,
/// the 60Hz panel stretches). The counter is read/reset on the main thread only.
final class CountedHostingView: NSHostingView<AnyView> {
    nonisolated(unsafe) static var layoutCount = 0
    /// issue #28: while a flight is running, a static block's SwiftUI layout
    /// pass is pure waste (geometry and content unchanged); the canvas mutes
    /// it and forces a real pass at settle.
    var muteLayout = false
    override func layout() {
        Self.layoutCount += 1
        if muteLayout { return }
        super.layout()
    }
}

/// One block of panel content: a SwiftUI hosting view at its natural size
/// inside a clip whose height animates between 0 and the content height.
/// Fixed (always visible) blocks are just clips whose isOpen is always true;
/// their height still animates when their CONTENT height changes (a preset
/// added, a nested reveal inside Settings).
@MainActor
final class PanelBlock {
    let id: String
    let clip: FlippedView
    let host: NSView
    var contentHeight: CGFloat = 0
    let isOpen: () -> Bool
    /// Displayed clip height right now (animates toward `target`).
    var current: CGFloat = 0
    /// Detail-region blocks: the shaded band is painted on the CLIP's layer
    /// (tintBands), not the SwiftUI content, so a reveal fade dims only the
    /// content while the band slides with the clip. Fading the band left a
    /// bare-glass hole mid-collapse.
    var banded = false
    /// Header rows keep SwiftUI layout live even when their own height is
    /// static in a flight: their chevron rotation is a per-frame SwiftUI
    /// render, and the static-block muting froze it until settle (the arrow
    /// snapped instead of turning). One-row hosts, so staying live is cheap.
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
    static let log = Logger(subsystem: "com.crisp.app", category: "panelcanvas")
    /// For the spring's tick log sub-timings (single instance in practice).
    static weak var shared: PanelCanvas?

    let width: CGFloat = 308
    /// Transparent window margins hosting the layer shadow.
    let sideMargin: CGFloat = 40
    let bottomMargin: CGFloat = 48
    /// Room above the shell for the twin's 1pt rim stroke; with the shell
    /// flush to the window top, the outset twin would be clipped and the
    /// top rim line vanish in flight.
    let topMargin: CGFloat = 2
    private let topInset: CGFloat = 8
    private let docTopInset: CGFloat = 4
    private let docBottomInset: CGFloat = 4
    /// Slack added to each block's NSHostingView canvas ABOVE its content height.
    /// The top-glue in BlockHost (.frame(maxHeight:.infinity, alignment:.top))
    /// only engages when the content MODEL is shorter than the canvas: only then
    /// does it fill the slack and pin the content's frame to the top, so a
    /// mid-reveal curtain (shorter presentation) animates INSIDE a fixed
    /// top-aligned frame. A canvas sized exactly to the content (no slack) lets
    /// NSHostingView position by the shorter presentation instead -> it centered
    /// the reveal and dropped the top on open. 1.3.2 got this for free with one
    /// fixed 2400 canvas for the whole panel; the split canvas needs it per block.
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
    /// Settled shell height from the last layout, for windowTight().
    private var lastShellH: CGFloat = 0
    var isShown: () -> Bool = { false }

    /// Screen-space anchor of the pinned top edge, set by positionPanel.
    private var anchorTopY: CGFloat = 0
    private var anchorX: CGFloat = 0

    private var animFrom: [CGFloat] = []
    /// Targets CAPTURED at animate start. Per-tick math must never read the
    /// live block targets: a mid-flight toggle flips them synchronously, and
    /// interpolating toward a new target with the old progress teleports the
    /// block in one frame. Mid-flight changes re-anchor via requestApply
    /// (velocity carry) instead.
    private var animTarget: [CGFloat] = []
    private var animTargetSum: CGFloat = 0
    private var animFromSum: CGFloat = 0
    /// Blocks fading with this flight: a section opening from zero fades in,
    /// one closing to zero fades out, tracking the spring. Mirrors the soft
    /// .opacity transition SwiftUI gives the in-block curtains (Brightness
    /// Keys, Support), so every reveal gets the same treatment.
    private var fadeInIdx: Set<Int> = []
    private var fadeOutIdx: Set<Int> = []
    private var scrollOffset: CGFloat = 0
    private var animatePending = false
    /// The shell is layer-driven and presents its frame change in the CURRENT
    /// CATransaction; SwiftUI commits the inner curtain's render and presents it
    /// ONE frame later. Applying each spring tick one frame late lands the shell
    /// on the same frame the curtain does, so the outer edge and inner content
    /// move together (the "inner lags the outer" residual). Reset per flight.
    private var pendingScalar: CGFloat?
    private var flightTicks = 0
    private var flightHostLayouts0 = 0
    /// Window height last handed to setFrame; a mismatch at the next layout
    /// means someone else resized the window (EXT in the log).
    private var lastSetWindowH: CGFloat = -1
    /// Sub-timings of the last layoutNow, for the tick log.
    private(set) var lastLoopMs: Double = 0
    private(set) var lastWinMs: Double = 0
    /// True only during the warm-up pre-paint, so every block lies inside the
    /// viewport and genuinely draws once (a capped viewport would leave the
    /// lower blocks unpainted, defeating the pre-paint).
    private var ignoreCap = false

    func install(shell: NSView, shadow: NSView, panel: NSPanel) {
        PanelCanvas.shared = self
        self.panel = panel
        self.shellView = shell
        self.shadowView = shadow
        viewport.addSubview(doc)
        shell.addSubview(viewport)
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
            // One-frame buffer: apply the previous tick, hold this one. See
            // pendingScalar. onSettle sets the exact targets, superseding any
            // held value, so the last frame lands precisely.
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

    /// fittingSize straight after init is nondeterministic; force a layout
    /// pass first (failure map item 5). SwiftUI's geometry reporting keeps
    /// heights fresh from then on.
    func measureAll() {
        for b in blocks + [footer].compactMap({ $0 }) {
            b.host.layoutSubtreeIfNeeded()
            b.contentHeight = b.host.fittingSize.height
        }
    }

    /// SwiftUI reported a block's natural (fully-laid-out) height: initial
    /// layout, a nested reveal's end state, presets changing. It reports the
    /// final height in one shot (the curtain animates at the presentation
    /// layer, invisible to geometry callbacks), so the spring animates the clip
    /// to it. The host frame tracks the spring (layoutNow), which keeps the
    /// content top-aligned during the reveal (see layoutNow).
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
        // Reveals fade while they slide: the HOST (content) fades, the clip
        // (which carries the band for detail blocks) only resizes. Opening
        // blocks start invisible (their clip is still zero-height this frame,
        // so no flash either way); everything else snaps opaque in case a
        // prior flight was retargeted mid-fade.
        fadeInIdx.removeAll()
        fadeOutIdx.removeAll()
        for i in blocks.indices {
            if animFrom[i] == 0, animTarget[i] > 0 { fadeInIdx.insert(i) }
            else if animFrom[i] > 0, animTarget[i] == 0 { fadeOutIdx.insert(i) }
            let a: CGFloat = fadeInIdx.contains(i) ? 0 : 1
            if blocks[i].host.alphaValue != a { blocks[i].host.alphaValue = a }
        }
        // One window grow per toggle, HERE at rest (nothing moves in this
        // frame, so its WindowServer cost cannot jump); per-tick work during
        // the flight is layer-only. Shadow swaps first so the grow's setFrame
        // is shadowless (no server shadow recompute).
        useFlightShadow()
        windowForFlight()
        flightTicks = 0
        flightHostLayouts0 = CountedHostingView.layoutCount
        // Mute the STATIC blocks' SwiftUI layout for the flight: the window's
        // constraint engine walks every host on every per-tick clip resize,
        // and ~10 SwiftUI layout passes per 8.3ms frame were the 60Hz panel
        // stretches. A static block's geometry and content are unchanged
        // mid-flight, so its layout() is skipped wholesale. The block whose
        // height animates stays live: nested curtains (resolution and preset
        // dropdowns, Image Adjustment) report their final height once and
        // then animate at the SwiftUI presentation layer, which needs
        // per-frame layout; muting it froze the inner reveal until settle.
        // endFlightMuting() at settle/snap runs one real pass at rest.
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
            // Ceiling is the TALLER of this flight's endpoints, not the current
            // contentHeight. A nested reveal closing (Image Adjustment) sets the
            // block's contentHeight to its new SHORT value before the flight
            // starts; clamping to that snapped current down instantly on frame
            // one (outer panel closed instant while the inner curtain animated),
            // yet grew smoothly on open. Bounding by the start height instead
            // lets the clip spring down in step with the curtain.
            b.current = min(max(exact, 0), max(animFrom[i], animTarget[i]))
        }
        layoutNow()
    }

    /// The one layout function: stacks blocks with cumulative integral
    /// rounding (sums stay exact, no per-block jitter), then derives the
    /// window frame. Only integral frames reach AppKit (failure map item 4).
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
            // The host canvas is TALLER than the content (hostSlack), so the
            // top-glue in BlockHost engages and pins the content to the top; the
            // clip above reveals only `current` of it and masks the slack. A
            // canvas sized to the content let NSHostingView center the shorter
            // mid-reveal presentation, dropping the top on every open.
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
        // The WINDOW is static here: only the shell and its shadow twin move,
        // in one Core Animation transaction (atomic, GPU-composited). Window
        // frames change only at rest, in setWindowHeight.
        let rootH = panel.contentView?.bounds.height ?? 0
        let shellR = NSRect(x: sideMargin, y: (rootH - topMargin - shellH).rounded(),
                            width: width, height: shellH)
        if let shell = shellView, shell.frame != shellR { shell.frame = shellR }
        // The twin is outset ONE DEVICE PIXEL (its border strokes outside
        // the glass): the native rim is a 1px hairline at any backing scale,
        // so the outset is 1/scale points, not 1pt. Shadow geometry stays
        // the true shell rect, and the knockout mask removes the shadow
        // interior so the glass backdrop never samples it.
        let px = 1 / max(panel.backingScaleFactor, 1)
        let svR = shellR.insetBy(dx: -px, dy: -px)
        if let sv = shadowView, sv.frame != svR {
            sv.frame = svR
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let inner = CGRect(x: px, y: px, width: shellR.width, height: shellR.height)
            let innerPath = CGPath(roundedRect: inner, cornerWidth: 16, cornerHeight: 16, transform: nil)
            sv.layer?.shadowPath = innerPath
            sv.layer?.cornerRadius = 16 + px
            let maskR = CGRect(origin: .zero, size: svR.size)
            let p = CGMutablePath()
            p.addRect(CGRect(x: -60, y: -60, width: svR.width + 120, height: svR.height + 120))
            p.addPath(innerPath)
            // The native shadow barely wraps above the top edge (a faint
            // ~6% shade in the menu-bar gap, nothing beyond); cut the
            // blur 3px above the twin's top border row.
            p.addRect(CGRect(x: -60, y: svR.height + 3, width: svR.width + 120, height: 57))
            if let mask = shadowMask { mask.frame = maskR; mask.path = p }
            CATransaction.commit()
        }
        lastShellH = shellH
        lastLoopMs = (t1 - t0) * 1000
        lastWinMs = (CACurrentMediaTime() - t1) * 1000
    }

    /// Window frames are set ONLY here, and only while the panel is at rest
    /// (animation boundaries, positioning): even a shadowless transparent
    /// window resize is a WindowServer transaction we keep out of the
    /// per-tick path.
    private func setWindowHeight(_ h: CGFloat) {
        guard let panel else { return }
        // h is the VISIBLE height below anchorTopY; the window extends
        // topMargin above it (rim headroom, covered by the menu bar).
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

    /// The panel wears the CA clone shadow at ALL times, in flight and at
    /// rest. The server shadow cannot follow the shell in flight without
    /// the measured 5-9ms per-frame recompute, and a hybrid (native at
    /// rest, clone in flight) flashes at every settle: hasShadow renders on
    /// the WindowServer's schedule (~200ms after invalidateShadow, video-
    /// measured), the twin on Core Animation's, so no swap can be atomic.
    /// The clone is pixel-calibrated against the native shadow instead
    /// (profiles in AppDelegate).
    private func useFlightShadow() {
        // Disabled actions: raw layer property changes implicitly animate
        // (0.25s fade), but the native shadow they replace vanishes
        // instantly, so any fade reads as a rim flash at flight start.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowView?.isHidden = false
        // The white inner line only reads in dark mode; in light mode the
        // glass's own edge bevel already saturates white on the straight
        // edges, and the extra stroke washes out the corners' cyan
        // refraction (measured 231,241,244 vs the native 214,244,248).
        // NSApp, not the panel: the panel is positioned (and its shadow first
        // applied) while still off screen, where panel.effectiveAppearance
        // has not resolved to dark yet, so it would paint light-mode values at
        // spawn and repaint dark on the first interaction (a visible change).
        // The app appearance is always resolved and matches the system menu
        // bar, which is what native menus follow.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The white inner line is a full point (2px at 2x, video-measured),
        // unlike the black rim, which is a 1-device-pixel hairline.
        shellView?.layer?.borderWidth = dark ? 1 : 0
        // The native rim and blur are appearance-dependent: rim ~0.29 black
        // in light mode vs near-black (~0.85) in dark; the blur runs ~0.21
        // light vs ~0.37 dark (bottom edge 15.7% vs 20% darkening).
        shadowView?.layer?.borderColor = NSColor.black
            .withAlphaComponent(dark ? 0.85 : 0.29).cgColor
        shadowView?.shadow?.shadowColor = NSColor.black
            .withAlphaComponent(dark ? 0.37 : 0.21)
        CATransaction.commit()
        panel?.hasShadow = false
    }

    /// Settle path: keep the clone, just refresh appearance-tied colors.
    private func useRestShadow() {
        useFlightShadow()
    }

    /// Re-apply the appearance-tied rim + clone-shadow tints. useFlightShadow
    /// picks them from NSApp.effectiveAppearance, but only runs on a flight or
    /// settle, so a light<->dark switch (or the first on-screen open, before the
    /// launch-time appearance had resolved) otherwise left the panel wearing the
    /// other mode's rim until an expansion refreshed it. Called on every open
    /// and on system theme change.
    func refreshAppearance() {
        guard panel != nil else { return }
        useRestShadow()
        tintBands()
    }

    /// Paints the detail band (labelColor at 8%, the AppKit resolution of the
    /// SwiftUI Color.primary band the detail region used to carry) on banded
    /// blocks' clip layers, resolved against the current appearance.
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
