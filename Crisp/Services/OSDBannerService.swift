import AppKit
import SwiftUI
import CoreImage

/// Draws Crisp's own on-screen display on macOS 26, in the style of the
/// system's brightness and volume capsule under the menu bar. OSDUIHelper
/// draws the pre-Tahoe bezel instead on macOS 14 and 15 (BrightnessHUDService);
/// the system's own capsule has no third-party entry point (#76).
///
/// One panel per screen, created on first use and never ordered out (alpha 0
/// when hidden): showing it again would replay its materialize bloom.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerService {
    static let shared = OSDBannerService()
    private init() {}

    /// Capsule geometry at rest, fitted to the native capsule on 26.5.1:
    /// inset from the trailing screen edge, below the menu bar, corner
    /// radius. macOS 27 moves the trailing inset in from 10 to 17.
    /// Measured: see docs/osd-notes.md (Capsule geometry).
    static var trailingInset: CGFloat { drawsMacOS27Capsule ? 17 : 10 }
    static let topInset: CGFloat = 10
    static let cornerRadius: CGFloat = 20
    /// The capsule's tone: one grey mixed to match the system HUD's line over
    /// a flat backdrop; slightly lighter on macOS 27.
    /// Measured: see docs/osd-notes.md (Capsule tone).
    static var scrimColor: NSColor {
        drawsMacOS27Capsule ? NSColor(white: 0.386, alpha: 0.325)
                            : NSColor(white: 0.355, alpha: 0.343)
    }
    /// How much of the backdrop's own colour the grey scrim leaves; saturated
    /// back up to match the HUD, or a coloured window under the capsule reads
    /// noticeably duller than behind the HUD.
    /// Measured: see docs/osd-notes.md (Backdrop saturation).
    static let backdropSaturation = 1.26 / (1 - 0.343)

    /// Accessibility > Display > Reduce Transparency: darker scrim, lower
    /// saturation, heavier blur, flat badge tones, all fitted to the system
    /// HUD under that setting.
    /// Measured: see docs/osd-notes.md (Reduce transparency).
    static let reducedScrimColor = NSColor(white: 0.135, alpha: 0.753)
    static let reducedSaturation = 1.65
    /// Enough to leave the backdrop no detail at all, as the HUD's does.
    static let reducedBlurRadius: CGFloat = 20
    static func reducedBadgeDisc(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.078 : 0.949, alpha: 1)
    }
    static func reducedBadgeInk(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.584 : 0.478, alpha: 1)
    }
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    /// How the backdrop is blurred to match the HUD's softening: sampled at
    /// reduced resolution, radius chosen from a per-scale-band sweep (no
    /// build reaches the true fit), heavier on macOS 27.
    /// Measured: see docs/osd-notes.md (Backdrop blur radius).
    static let backdropScale = 0.5
    static var backdropBlurRadius: Double { drawsMacOS27Capsule ? 2.0 : 1.0 }
    /// True from macOS 27 on, where the system redrew the capsule: softer
    /// backdrop, and a rim that follows the edge instead of a flat white ring.
    static let drawsMacOS27Capsule = SystemLook.isMacOS27OrLater
    /// One point, as on 26.
    static let rimWidth: CGFloat = 1.15
    static let rimInset: CGFloat = 0
    /// The rim: an additive white line (not blended) along the top and bottom
    /// edge only, with a short inner glow, fitted to the system HUD.
    /// Measured: see docs/osd-notes.md (Rim colour and glow).
    static let rimEdgeColor = NSColor(white: 1, alpha: 0.27)
    static let rimGlowColor = NSColor(white: 1, alpha: 0.15)
    static let rimGlowShare = 0.10
    static let rimEdgeShare = 0.06
    /// How far and over how many points the edge bends the backdrop, fitted
    /// to the HUD's own bend.
    /// Measured: see docs/osd-notes.md (Refraction amount and height).
    static let refractionAmount = -80.0
    static let refractionHeight = 20.0
    /// The window level OSDUIHelper and Control Center draw their capsule at.
    static let windowLevel = NSWindow.Level(rawValue: 2005)
    /// Entry, hold and exit timings and curves, fitted frame by frame to the
    /// system HUD; macOS 27 runs the same three stages slower. Change these
    /// by measuring, not by taste.
    /// Measured: see docs/osd-notes.md (Entry, hold and exit timings).
    static var visibleDuration: TimeInterval { drawsMacOS27Capsule ? 0.98 : 1.0 }
    static var fadeInDuration: TimeInterval { drawsMacOS27Capsule ? 0.68 : 0.55 }
    static let fadeInCurve = CAMediaTimingFunction(controlPoints: 0.4, 0.05, 0.2, 0.9)
    static var growDuration: TimeInterval { drawsMacOS27Capsule ? glassGrowInDuration : 0.35 }
    static let fadeOutDuration: TimeInterval = 0.54
    static let fadeOutCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.65, 0.35, 1)
    static let exitShrinkDuration: TimeInterval = 0.45
    static let exitShrinkCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.4, 0.3, 1)
    static var entryInset: CGSize { drawsMacOS27Capsule ? CGSize(width: 38, height: 8) : CGSize(width: 11, height: 2) }
    static let exitInset = CGSize(width: 14, height: 3)
    static let hiddenLift: CGFloat = 5.5

    private var panels: [CGDirectDisplayID: OSDBannerPanel] = [:]
    /// What Reduce transparency was when the panels above were built.
    private var builtReduced = OSDBannerService.reduceTransparency

    /// Crisp's own menu bar item, handed over by AppDelegate once it exists.
    /// The system hangs each HUD under the menu bar item that owns it, so the
    /// banner hangs under Crisp's and the two stop landing on top of each
    /// other. Weak: the item outlives the banner, and neither owns the other.
    weak var statusItem: NSStatusItem?

    /// Lights that menu bar item while the banner is up, the way the system
    /// lights the Sound control while its own HUD is up. AppDelegate does the
    /// lighting, because an open panel holds the same highlight.
    var setHighlight: ((Bool) -> Void)?

    /// Takes a level the pointer set on a banner's track: the display, what it
    /// was showing, and 0...1 of the scale that banner shows. AppDelegate
    /// wires this to the same services the keys use.
    var onSlide: ((CGDirectDisplayID, OSDImage, Double) -> Void)?

    private var unlightWork: DispatchWorkItem?

    /// Shows (or refreshes) the banner on `screen`. `level` is 0...100 as the
    /// key paths pass it: for brightness a percentage of the display's extended
    /// maximum, for volume the DDC volume itself.
    func show(level: Double, image: OSDImage, on screen: NSScreen) {
        guard let displayID = Self.displayID(of: screen) else { return }
        prunePanels()
        dropPanelsIfTransparencyChanged()
        let panel: OSDBannerPanel
        if let existing = panels[displayID] {
            panel = existing
        } else {
            panel = makePanel()
            panels[displayID] = panel
        }
        panel.model.title = screen.localizedName
        panel.model.image = image
        panel.model.level = max(0, min(1, level / 100))
        // Re-wired on every show: the display is the panel's own, but what it
        // is showing is not (brightness one press, volume the next).
        panel.model.slide = { [weak self] fraction in self?.onSlide?(displayID, image, fraction) }
        panel.model.dismiss = { [weak panel] in panel?.dismiss() }
        // The frame is recomputed every time: a resolution change moves the
        // screen edge, and the menu bar item moves on its own.
        panel.reveal(at: Self.frame(on: screen, centredOn: anchorMidX(on: screen)))
        light()
    }

    /// Centred on Crisp's menu bar item, under the menu bar (visibleFrame
    /// excludes it), never closer than `trailingInset` to either side edge.
    /// Falls back to the top right corner with no item to centre on.
    /// Measured: see docs/osd-notes.md (Capsule geometry).
    static func frame(on screen: NSScreen, centredOn midX: CGFloat?) -> NSRect {
        let width = OSDBannerView.size.width
        let corner = screen.frame.maxX - trailingInset - width
        var x = corner
        if showsFullScreenWindow(screen) {
            x = screen.frame.midX - width / 2
        } else if let midX {
            x = min(max(midX - width / 2, screen.frame.minX + trailingInset), corner)
        }
        // The window is the capsule plus the overhang the close badge needs.
        return NSRect(x: x,
                      y: screen.visibleFrame.maxY - topInset - OSDBannerView.size.height,
                      width: width, height: OSDBannerView.size.height)
            .insetBy(dx: -windowMargin, dy: -windowMargin)
    }

    /// Whether `screen` is showing a full-screen space: the system then
    /// centres its capsule on the midline instead of hanging under the menu
    /// bar item, which moves off that screen. Only a window owned by an app
    /// with a Dock tile counts, or a borderless overlay (e.g. Cua Driver)
    /// misdetects as full screen. Cached briefly per display since the window
    /// list is a window-server round trip.
    /// Measured: see docs/osd-notes.md (Full-screen detection).
    private static var fullScreenCache: [CGDirectDisplayID: (value: Bool, at: Date)] = [:]
    private static let fullScreenCacheLife: TimeInterval = 0.5

    private static func showsFullScreenWindow(_ screen: NSScreen) -> Bool {
        guard let displayID = displayID(of: screen) else { return false }
        if let hit = fullScreenCache[displayID],
           Date().timeIntervalSince(hit.at) < fullScreenCacheLife {
            return hit.value
        }
        let bounds = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let covered = windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let frame = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = frame["X"], let y = frame["Y"],
                  let width = frame["Width"], let height = frame["Height"] else { return false }
            guard abs(x - bounds.minX) < 2, abs(y - bounds.minY) < 2,
                  abs(width - bounds.width) < 2, abs(height - bounds.height) < 2,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
        fullScreenCache[displayID] = (covered, Date())
        return covered
    }

    /// Where Crisp's menu bar item sits on `screen`, or nil with nothing to
    /// hang under (also nil when the bar has no room for the item). The
    /// offset from the right edge holds across screens; AppDelegate.
    /// positionPanel mirrors it the same way.
    private func anchorMidX(on screen: NSScreen) -> CGFloat? {
        guard let window = statusItem?.button?.window,
              let itemScreen = window.screen,
              window.frame.maxY >= itemScreen.frame.maxY - 1 else { return nil }
        return screen.frame.maxX - (itemScreen.frame.maxX - window.frame.midX)
    }

    /// Lights the menu bar item while the banner holds, and dims it as the
    /// banner starts to leave rather than once it is gone, matching the
    /// system. One timer for every screen: a press anywhere pushes it out.
    /// Measured: see docs/osd-notes.md (Menu bar item light).
    private func light() {
        unlightWork?.cancel()
        setHighlight?(true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A banner the pointer is on holds itself up; the light follows,
            // going out only with the hold after the leave.
            guard !self.panels.values.contains(where: { $0.model.hovering }) else { return }
            self.setHighlight?(false)
        }
        unlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    /// Called by a panel when the pointer arrives or leaves, so the menu bar
    /// item follows the banner it belongs to.
    func hoverChanged(_ hovering: Bool) {
        if hovering {
            unlightWork?.cancel()
            setHighlight?(true)
        } else {
            light()
        }
    }

    /// The close badge took the banner away, so the light goes with it instead
    /// of sitting on for the rest of the hold. Another screen's banner may
    /// still be up, and it keeps the light.
    func dismissed(_ panel: OSDBannerPanel) {
        guard !panels.values.contains(where: { $0 !== panel && $0.alphaValue > 0 && !$0.exiting })
        else { return }
        unlightWork?.cancel()
        setHighlight?(false)
    }

    /// Takes every banner away at once. Called by BrightnessHUDService.suppressed
    /// when Crisp's own panel opens, since a banner already up would float above it.
    func hideVisible() {
        for panel in panels.values where panel.alphaValue > 0 {
            panel.dismiss()
        }
    }

    /// The layer the capsule blurs its backdrop with. No public blur draws
    /// this gently, so CABackdropLayer is asked for by name (private, so any
    /// step of the lookup may fail); without it the banner falls back to the
    /// scrim alone, tone correct but with a sharp backdrop.
    /// Measured: see docs/osd-notes.md (Backdrop layer).
    private static func makeBackdrop(frame: NSRect) -> CALayer? {
        guard let tone = makeToneFilters() else { return nil }
        let blur = reduceTransparency ? reducedBlurRadius : backdropBlurRadius
        return makeBackdrop(frame: frame, blur: blur, tone: tone, refract: true)
    }

    /// macOS 27's glass, see glassVariant. Nil where the variant is not
    /// there to ask for, which keeps the hand-made capsule.
    private static func makeGlassView(frame: NSRect) -> NSGlassEffectView? {
        guard NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:")) else { return nil }
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = cornerRadius
        glass.setValue(glassVariant, forKey: "_variant")
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        return glass
    }

    private static func makeBackdrop(frame: NSRect, blur: CGFloat,
                                     tone: [NSObject], refract: Bool) -> CALayer? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
        else { return nil }
        let backdrop = backdropClass.init()
        backdrop.frame = frame
        // Also private; each is set only where it exists. Without
        // windowServerAware the sample goes stale when nothing on screen
        // changes (see docs/osd-notes.md, Backdrop layer).
        if backdrop.value(forKey: "scale") != nil {
            backdrop.setValue(backdropScale, forKey: "scale")
        }
        if backdrop.value(forKey: "windowServerAware") != nil {
            backdrop.setValue(true, forKey: "windowServerAware")
        }
        var filters: [Any] = []
        if let blurFilter = makeFilter("gaussianBlur") {
            blurFilter.setValue(blur, forKey: "inputRadius")
            // Or the blur pulls in the transparent outside of the capsule and
            // thins its own edge.
            blurFilter.setValue(true, forKey: "inputNormalizeEdges")
            filters.append(blurFilter)
        }
        filters.append(contentsOf: tone)
        if refract, let refraction = makeRefraction(on: backdrop, frame: frame) {
            filters.append(refraction)
        }
        backdrop.filters = filters
        return backdrop
    }

    /// The close badge's own tone line: it samples the desktop like the
    /// capsule and lays a line over it, fitted separately per appearance
    /// since the system badge follows light/dark independently of the
    /// capsule. Still not matched: the system occasionally swaps look near
    /// the far end of an appearance, at no fixed threshold.
    /// Measured: see docs/osd-notes.md (Badge tone).
    private static func badgeTone(dark: Bool) -> (multiply: Double, add: Double) {
        dark ? (multiply: 0.636, add: 0.012) : (multiply: 0.562, add: 0.539)
    }
    /// Heavier than the capsule's own blur.
    /// Measured: see docs/osd-notes.md (Badge tone).
    private static let badgeBlurRadius: CGFloat = 8
    private static func makeBadgeBackdrop(frame: NSRect, dark: Bool) -> CALayer? {
        guard let multiply = makeFilter("multiplyColor"),
              let add = makeFilter("colorAdd") else { return nil }
        let tone = badgeTone(dark: dark)
        multiply.setValue(NSColor(white: tone.multiply, alpha: 1).cgColor, forKey: "inputColor")
        add.setValue(NSColor(white: tone.add, alpha: 1).cgColor, forKey: "inputColor")
        return makeBackdrop(frame: frame, blur: badgeBlurRadius,
                            tone: [multiply, add], refract: false)
    }

    /// The grey and the colour, as filters over the sampled backdrop. Order
    /// matters: multiply (the grey) must run before saturate, or saturating a
    /// strong colour first clips it past black in one channel.
    private static func makeToneFilters() -> [NSObject]? {
        guard let multiply = makeFilter("multiplyColor"),
              let add = makeFilter("colorAdd"),
              let saturate = makeFilter("colorSaturate") else { return nil }
        let scrim = reduceTransparency ? reducedScrimColor : scrimColor
        let alpha = scrim.alphaComponent
        multiply.setValue(NSColor(white: 1 - alpha, alpha: 1).cgColor, forKey: "inputColor")
        add.setValue(NSColor(white: alpha * scrim.whiteComponent, alpha: 1).cgColor, forKey: "inputColor")
        saturate.setValue(reduceTransparency ? reducedSaturation : backdropSaturation,
                          forKey: "inputAmount")
        return [multiply, add, saturate]
    }

    /// Every fallback below depends on this returning nil for a filter the
    /// system lacks. The selector is checked first, since performing a
    /// missing one crashes rather than degrading; the name is checked
    /// against the system's own list, since filterWithName: returns a live
    /// but inert object for any name at all.
    private static func makeFilter(_ name: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithName:")),
              filterTypes.contains(name)
        else { return nil }
        return filterClass.perform(NSSelectorFromString("filterWithName:"), with: name)?
            .takeUnretainedValue() as? NSObject
    }

    /// The filter names this system has, read once. Empty if the call is gone,
    /// which makes every makeFilter above fail into its own fallback.
    private static let filterTypes: Set<String> = {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterTypes")),
              let names = filterClass.perform(NSSelectorFromString("filterTypes"))?
                .takeUnretainedValue() as? [String]
        else { return [] }
        return Set(names)
    }()

    /// Bends the backdrop into the capsule's edge, the way real glass would;
    /// on a patterned backdrop this is the last thing that tells the capsule
    /// apart from the HUD. This is the system's own glass filter: it reads
    /// its bend shape from a distance-field sublayer (a bare backdrop layer
    /// draws no bend). Every class and key is private; any missing one leaves
    /// the banner with the blurred backdrop and no bend.
    private static func makeRefraction(on backdrop: CALayer, frame: NSRect) -> NSObject? {
        guard let sdfClass = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementClass = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let effectClass = NSClassFromString("CASDFOutputEffect") as? NSObject.Type,
              let filter = makeFilter("glassBackground") else { return nil }
        let shapeName = "@0"
        let shape = sdfClass.init()
        shape.name = shapeName
        shape.frame = frame
        shape.setValue(effectClass.init(), forKey: "effect")
        let element = elementClass.init()
        element.frame = frame
        element.cornerRadius = cornerRadius
        element.cornerCurve = .continuous
        // The element hangs off a plain layer, as it does in the system's own
        // tree; hung directly off the shape layer it is not picked up.
        let holder = CALayer()
        holder.addSublayer(element)
        shape.addSublayer(holder)
        backdrop.addSublayer(shape)
        filter.setValue(shapeName, forKey: "inputSourceSublayerName")
        // This filter's own blur is heavy by default; the gaussian above it
        // is the one that is fitted (see docs/osd-notes.md, Refraction
        // amount and height), so this one is off.
        filter.setValue(0.0, forKey: "inputBlurRadius")
        filter.setValue(1.0, forKey: "inputRefractionOpacity")
        filter.setValue(refractionAmount, forKey: "inputInnerRefractionAmount")
        filter.setValue(refractionHeight, forKey: "inputInnerRefractionHeight")
        filter.setValue(0.0, forKey: "inputOuterRefractionAmount")
        filter.setValue(0.0, forKey: "inputOuterRefractionHeight")
        filter.setValue(-1.0, forKey: "inputRefractionDistance0")
        filter.setValue(0.0, forKey: "inputRefractionDistance1")
        filter.setValue(0.0, forKey: "inputFaceOpacity")
        return filter
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Every filter is baked in when a panel's layers are made, so panels are
    /// dropped and rebuilt the first time a banner shows after Reduce
    /// Transparency changes; nothing watches the setting while none is up.
    private func dropPanelsIfTransparencyChanged() {
        guard builtReduced != Self.reduceTransparency else { return }
        builtReduced = Self.reduceTransparency
        for (id, panel) in panels {
            panel.close()
            panels[id] = nil
        }
    }

    private func prunePanels() {
        let live = Set(NSScreen.screens.compactMap(Self.displayID(of:)))
        for (id, panel) in panels where !live.contains(id) {
            panel.close()
            panels[id] = nil
        }
    }

    /// How far the window reaches past the capsule on every side, for the
    /// close badge and its shadow.
    /// Measured: see docs/osd-notes.md (Window margin and badge).
    static let windowMargin: CGFloat = 30

    /// The window is the capsule with that margin around it.
    private static var windowSize: CGSize {
        CGSize(width: OSDBannerView.size.width + 2 * Self.windowMargin,
               height: OSDBannerView.size.height + 2 * Self.windowMargin)
    }

    /// Where the capsule sits inside the window. Views placed here keep their
    /// margins through the entry grow and the exit shrink, since they resize
    /// with the window.
    private static func capsuleRect(in root: NSView) -> NSRect {
        root.bounds.insetBy(dx: Self.windowMargin, dy: Self.windowMargin)
    }

    /// The close badge's frame, centred near the capsule's top left corner.
    /// Measured: see docs/osd-notes.md (Window margin and badge).
    private static func badgeRect(in root: NSView) -> NSRect {
        let capsule = capsuleRect(in: root)
        return NSRect(x: capsule.minX + OSDBadgeView.centreInset - OSDBadgeView.size / 2,
                      y: capsule.maxY - OSDBadgeView.centreInset - OSDBadgeView.size / 2,
                      width: OSDBadgeView.size, height: OSDBadgeView.size)
    }

    private func makePanel() -> OSDBannerPanel {
        let p = OSDBannerPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Set the level explicitly and never isFloatingPanel: that setter
        // silently resets the level to floating (3), under the menu bar.
        p.level = Self.windowLevel
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        // The masked capsule carries the shape: the edge profile matched the
        // native capsule to within two pixels without a WindowServer shadow.
        p.hasShadow = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.alphaValue = 0

        let root = BannerRootView(frame: NSRect(origin: .zero, size: Self.windowSize))
        root.wantsLayer = true

        // The capsule is what is behind the window, softened and toned down,
        // inside a layer masked to the capsule shape. The content sits above
        // it, so the label, glyphs and track keep their own tone.
        let clip = NSView(frame: Self.capsuleRect(in: root))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.autoresizingMask = [.width, .height]
        let glassView = Self.drawsMacOS27Capsule && !Self.reduceTransparency
            ? Self.makeGlassView(frame: clip.frame) : nil
        if glassView != nil {
            // The system glass is the whole capsule, see glassVariant.
        } else if let backdrop = Self.makeBackdrop(frame: clip.bounds) {
            clip.layer?.addSublayer(backdrop)
            p.backdrop = backdrop
        } else {
            let scrim = CALayer()
            scrim.frame = clip.bounds
            scrim.backgroundColor = (Self.reduceTransparency ? Self.reducedScrimColor
                                                              : Self.scrimColor).cgColor
            clip.layer?.addSublayer(scrim)
        }
        root.addSubview(glassView ?? clip)

        let hosting = NSHostingView(rootView: OSDBannerView(model: p.model))
        // Colours are explicit everywhere except the held knob's glass, which
        // needs the light appearance: dark glass over the capsule's own tone
        // is invisible. Set here, not on the panel, since a panel appearance
        // would also tint the grey.
        hosting.appearance = NSAppearance(named: .darkAqua)
        // No intrinsic-size constraints: the content follows the window
        // through the entry grow and the exit shrink.
        hosting.sizingOptions = []
        hosting.frame = Self.capsuleRect(in: root)
        hosting.autoresizingMask = [.width, .height]
        root.addSubview(hosting)

        // Read here, not with SwiftUI's onHover: that wants a key window, and
        // this panel is only key while the pointer is already on it. hitTest
        // returns nil so clicks fall through to the track and the badge.
        // Three points wider than the capsule, so the corner-hanging badge
        // stays inside it.
        let hover = BannerHoverView(frame: Self.capsuleRect(in: root).insetBy(dx: -3, dy: -3))
        hover.autoresizingMask = [.width, .height]
        hover.onHover = { [weak p] inside in p?.setHovering(inside) }
        root.addSubview(hover)

        // The close badge is drawn here and not in SwiftUI: it samples the
        // desktop the way the system's does, which no fill can, and it hangs
        // over the capsule's corner (see Self.windowMargin).
        let badge = OSDBadgeView(frame: Self.badgeRect(in: root))
        badge.alphaValue = 0
        badge.onClick = { [weak p] in p?.dismiss() }
        // Rebuilt rather than retuned when the appearance changes, since the
        // filters are set when the layer is made and the badge is one layer.
        badge.retone = { [weak badge, weak p] dark in
            guard let badge else { return }
            p?.badgeBackdrop?.removeFromSuperlayer()
            p?.badgeBackdrop = nil
            if Self.reduceTransparency {
                badge.disc.backgroundColor = Self.reducedBadgeDisc(dark: dark).cgColor
            } else if let sample = Self.makeBadgeBackdrop(frame: badge.bounds, dark: dark) {
                badge.disc.backgroundColor = nil
                badge.disc.addSublayer(sample)
                p?.badgeBackdrop = sample
            } else {
                badge.disc.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            }
        }
        badge.addGlyph()
        root.addSubview(badge)
        p.badge = badge

        // The rim: one point wide, drawn over the capsule and its content,
        // white blended over on macOS 26.
        // Measured: see docs/osd-notes.md (Rim colour and glow).
        //
        // macOS 27 redrew that rim: it is bright along the straight top and
        // bottom and dark down the two rounded ends, so OSDBevelView draws it
        // instead there. The flat white below is the one fitted on 26.5.1 and
        // stays for macOS 26.
        let bevel: NSView
        if Self.drawsMacOS27Capsule {
            bevel = OSDBevelView(frame: Self.capsuleRect(in: root))
        } else {
            bevel = NSView(frame: Self.capsuleRect(in: root))
            bevel.wantsLayer = true
            bevel.layer?.cornerRadius = Self.cornerRadius
            bevel.layer?.cornerCurve = .continuous
            bevel.layer?.borderWidth = 1
            bevel.layer?.borderColor = NSColor.white.withAlphaComponent(0.36).cgColor
        }
        bevel.autoresizingMask = [.width, .height]
        // Under the content and the hover view: a plain NSView takes every
        // click inside its bounds, and this one covers the whole capsule.
        root.addSubview(bevel, positioned: .below, relativeTo: hosting)

        // The rim is not faded in with the content: the system's is there from
        // the first frame. On the way out it goes with the glass.
        if let glassView, let content = hosting.layer,
           let rim = (bevel as? OSDBevelView)?.rings ?? bevel.layer {
            content.opacity = 0
            glassView.alphaValue = 0
            p.glass = OSDGlass(view: glassView, faded: [content], rim: rim, bevel: bevel)
        }

        p.contentView = root
        return p
    }
}

/// The system glass view, tuned to the HUD (see OSDBannerService.glassInputs),
/// and the layers that fade with it. The panel ramps three of the inputs
/// (the blur, the bend and the tint), see OSDBannerPanel.showGlass.
@available(macOS 26.0, *)
@MainActor
struct OSDGlass {
    let view: NSGlassEffectView
    let faded: [CALayer]
    /// The rim's rings, which the entry ramps. Not the whole bevel view: its
    /// glow stays up, see OSDBevelView.rings.
    let rim: CALayer
    let bevel: NSView

    /// The layer carrying the view's glass filter, tuned as it is set. The
    /// view rewrites its filter on every size change from SwiftUI's render
    /// pass, after any layout hook, so a tuning applied from outside is lost
    /// on alternating frames of the grow and shrink (the glass flashed); this
    /// class tunes it at write time instead. Nil if the view has no such
    /// filter.
    func tunedBackdrop() -> CALayer? {
        view.layoutSubtreeIfNeeded()
        guard let layer = Self.backdrop(in: view.layer),
              let tunedClass = Self.tunedClass(for: type(of: layer)) else { return nil }
        if layer.value(forKey: Self.targetsKey) == nil {
            layer.setValue([
                "inputBlurRadius": OSDBannerService.glassBlur.closed,
                "inputInnerRefractionAmount": OSDBannerService.glassBend.closed,
                "inputFaceOpacity": OSDBannerService.glassTint.closed,
                "inputInnerRefractionHeight": OSDBannerService.glassRefractionHeight.closed,
                "inputKeyFillHighlightAmount": OSDBannerService.glassHighlight.closed,
                "backdropScale": OSDBannerService.glassBackdropScale
            ], forKey: Self.targetsKey)
        }
        if !layer.isKind(of: tunedClass) { object_setClass(layer, tunedClass) }
        layer.filters = layer.filters
        return layer
    }

    /// Takes each input from where it is to its value on its own curve. The
    /// window server does not run a Core Animation animation on this view's
    /// filter (it drew the settled glass from the first frame), so the inputs
    /// are stepped here and the filter set again on each step.
    func ramp(_ layer: CALayer, _ legs: [OSDGlassRamp.Leg]) {
        Self.ramps[ObjectIdentifier(layer)]?.stop()
        let ramp = OSDGlassRamp(layer: layer, legs: legs,
                                from: layer.value(forKey: Self.targetsKey) as? [String: Double] ?? [:])
        Self.ramps[ObjectIdentifier(layer)] = ramp
        ramp.start()
    }

    private static var ramps: [ObjectIdentifier: OSDGlassRamp] = [:]

    static let filterName = "glassBackground"
    /// Where the three ramped inputs are headed, kept on the layer. The ramps
    /// draw the way there; this is what a filter set in the meantime starts at.
    fileprivate nonisolated static let targetsKey = "crispGlassTargets"

    /// A subclass of the backdrop's class whose setFilters: passes on a tuned
    /// copy of the glass filter. The filter is copied and not changed in
    /// place, because a change in place never reaches the window server.
    private static func tunedClass(for base: AnyClass) -> AnyClass? {
        let name = "CrispTuned" + NSStringFromClass(base)
        if let existing = NSClassFromString(name) { return existing }
        if NSStringFromClass(base).hasPrefix("CrispTuned") { return base }
        guard let tuned = objc_allocateClassPair(base, name, 0) else { return nil }
        let selector = NSSelectorFromString("setFilters:")
        typealias SetFilters = @convention(c) (AnyObject, Selector, NSArray?) -> Void
        let inherited = unsafeBitCast(class_getMethodImplementation(base, selector), to: SetFilters.self)
        let setFilters: @convention(block) (CALayer, NSArray?) -> Void = { layer, filters in
            let targets = layer.value(forKey: targetsKey) as? [String: Double] ?? [:]
            let scale = targets["backdropScale"] ?? OSDBannerService.glassBackdropScale
            if layer.value(forKey: "scale") as? Double != scale {
                layer.setValue(scale, forKey: "scale")
            }
            inherited(layer, selector, tunedFilters(filters, targets: targets))
        }
        class_addMethod(tuned, selector, imp_implementationWithBlock(setFilters), "v@:@")
        objc_registerClassPair(tuned)
        return tuned
    }

    private nonisolated static func tunedFilters(_ filters: NSArray?, targets: [String: Double]) -> NSArray? {
        guard let filters = filters as? [NSObject],
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return filters as NSArray? }
        return filters.map { filter -> NSObject in
            guard filter.value(forKey: "name") as? String == "glassBackground",
                  let copy = filterClass.perform(NSSelectorFromString("filterWithName:"), with: "glassBackground")?
                    .takeUnretainedValue() as? NSObject,
                  let keys = filter.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String]
            else { return filter }
            for key in keys { copy.setValue(filter.value(forKey: key), forKey: key) }
            copy.setValue("glassBackground", forKey: "name")
            for (key, value) in OSDBannerService.glassInputs { copy.setValue(value, forKey: key) }
            for (key, value) in targets where key.hasPrefix("input") { copy.setValue(value, forKey: key) }
            return copy
        } as NSArray
    }

    private static func backdrop(in layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if (layer.filters as? [NSObject])?.contains(where: { $0.value(forKey: "name") as? String == filterName }) == true {
            return layer
        }
        for sublayer in layer.sublayers ?? [] {
            if let found = backdrop(in: sublayer) { return found }
        }
        return nil
    }
}

/// The window is bigger than the capsule so the badge and its shadow have
/// room (see windowMargin). This hands back everything outside the capsule,
/// or the margin would swallow clicks on the menu bar and desktop around it.
@available(macOS 26.0, *)
final class BannerRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // The same three points the hover view takes, which is what holds the
        // badge hanging over the capsule's corner.
        let live = bounds.insetBy(dx: OSDBannerService.windowMargin - 3,
                                  dy: OSDBannerService.windowMargin - 3)
        return live.contains(local) ? super.hitTest(point) : nil
    }
}

/// The close badge: a disc that samples the desktop through its own backdrop
/// layer, with the system's xmark over it. AppKit and not SwiftUI, because a
/// SwiftUI fill can only blend with the capsule under it, and the system's
/// badge reads the desktop straight (see OSDBannerService.badgeTone).
@available(macOS 26.0, *)
final class OSDBadgeView: NSView {
    /// Measured on the system HUD: 18 points across, its centre 6.5 points in
    /// from the capsule's top left corner.
    static let size: CGFloat = 18
    static let centreInset: CGFloat = 6.5

    var onClick: (() -> Void)?
    /// The disc itself. It is a sublayer and not this view's own layer because
    /// the shadow below has to fall outside it, and a layer that masks its
    /// content to a circle masks its shadow away with it.
    private(set) var disc = CALayer()
    /// Kept so its resolution can follow the screen, see below.
    private var shadowLayer = CAGradientLayer()
    /// Kept so its ink can follow the appearance, see applyAppearance.
    private weak var glyph: NSImageView?
    /// Rebuilds the disc's sample of the desktop for the appearance given.
    /// Set by OSDBannerService, which owns the tone the sample is drawn with.
    var retone: ((Bool) -> Void)? { didSet { applyAppearance() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.frame = bounds
        disc.cornerRadius = frame.width / 2
        disc.masksToBounds = true
        disc.borderWidth = 1

        layer?.addSublayer(disc)
        shadowLayer = makeShadow()
        layer?.insertSublayer(shadowLayer, below: disc)
        applyAppearance()
    }

    /// A layer made by hand draws at one pixel a point whatever the screen is,
    /// where AppKit gives a view's own layer the screen's scale. On a Retina
    /// panel that left the shadow drawn at half resolution and scaled up, which
    /// is what turned its ramp into steps.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        disc.contentsScale = scale
        shadowLayer.contentsScale = scale
        shadowLayer.mask?.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The two looks the system badge has: a light disc with a dark cross, or
    /// the mirror in dark, over the same backdrop. Ink and rim tone live
    /// here; the disc's own tone is in OSDBannerService.badgeTone.
    /// Measured: see docs/osd-notes.md (Badge tone).
    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduced = OSDBannerService.reduceTransparency
        retone?(dark)
        disc.borderColor = reduced ? NSColor.clear.cgColor
                                   : NSColor(white: 1, alpha: dark ? 0.20 : 0.66).cgColor
        shadowLayer.colors = (dark ? Self.shadowAlphasDark : Self.shadowAlphasLight)
            .map { NSColor.black.withAlphaComponent($0).cgColor }
        glyph?.contentTintColor = reduced ? OSDBannerService.reducedBadgeInk(dark: dark)
                                          : Self.inkColour(dark: dark)
    }

    private static func inkColour(dark: Bool) -> NSColor {
        dark ? NSColor(white: 1, alpha: 0.552) : NSColor(white: 0, alpha: 0.498)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The shadow the badge sits on: a radial gradient masked to outside the
    /// disc, since the disc itself is a backdrop sample and lets what's under
    /// it through. Its alpha ring is fitted to the system badge's own drop
    /// profile, which differs between light and dark.
    /// Measured: see docs/osd-notes.md (Badge shadow).
    private static let shadowReach: CGFloat = 36
    /// Points out from the centre, as fractions of the reach. Inside 9 is the
    /// disc, which the mask cuts.
    private static let shadowLocations: [CGFloat] = [
        0.25, 0.278, 0.333, 0.389, 0.472, 0.556, 0.667, 0.778, 0.861, 0.944, 1.0
    ]
    private static let shadowAlphasLight: [CGFloat] = [
        0.085, 0.079, 0.058, 0.044, 0.031, 0.024, 0.016, 0.010, 0.007, 0.004, 0
    ]
    private static let shadowAlphasDark: [CGFloat] = [
        0.052, 0.048, 0.027, 0.016, 0.008, 0.006, 0.003, 0.001, 0, 0, 0
    ]

    private func makeShadow() -> CAGradientLayer {
        let reach = Self.shadowReach
        let shadow = CAGradientLayer()
        shadow.type = .radial
        shadow.frame = CGRect(x: bounds.midX - reach, y: bounds.midY - reach,
                              width: reach * 2, height: reach * 2)
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 1)
        shadow.locations = Self.shadowLocations.map { NSNumber(value: Double($0)) }
        let hole = CGMutablePath()
        hole.addRect(CGRect(origin: .zero, size: shadow.frame.size))
        hole.addEllipse(in: CGRect(x: reach - bounds.width / 2, y: reach - bounds.height / 2,
                                   width: bounds.width, height: bounds.height))
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: shadow.frame.size)
        mask.path = hole
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        shadow.mask = mask
        return shadow
    }

    /// The glyph's weight is fitted so its ink covers as much of the disc as
    /// the system's own glyph does; lighter weights read as too thin. Colour
    /// follows the appearance, see applyAppearance.
    /// Measured: see docs/osd-notes.md (Badge glyph).
    func addGlyph() {
        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        guard let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let view = NSImageView(image: image)
        view.contentTintColor = Self.inkColour(
            dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        // Centred on the X's own crossing point, not the image's bounding
        // box: SF Symbols carry their own bearings, so a hand-measured nudge
        // would not survive a size or screen change. This reads the ink's
        // actual position from the rendered image instead.
        let ink = Self.inkOffset(of: image)
        view.frame = bounds.offsetBy(dx: -ink.x, dy: -ink.y)
        view.imageScaling = .scaleNone
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        glyph = view
    }

    /// Where a symbol's ink sits in its own image, in points from the image's
    /// centre. Read off the image itself, so it follows the point size.
    private static func inkOffset(of image: NSImage) -> CGPoint {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return .zero }
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        let scaleX = image.size.width / CGFloat(rep.pixelsWide)
        let scaleY = image.size.height / CGFloat(rep.pixelsHigh)
        let midX = CGFloat(minX + maxX + 1) / 2 * scaleX
        let midY = CGFloat(minY + maxY + 1) / 2 * scaleY
        // The bitmap's rows run down and the view's y runs up.
        return CGPoint(x: midX - image.size.width / 2, y: image.size.height / 2 - midY)
    }

    /// Round, and only while the badge is there to be clicked.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.5 else { return nil }
        let local = convert(point, from: superview)
        let radius = bounds.width / 2
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= radius ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Steps the glass filter's ramped inputs, see OSDGlass.ramp.
@available(macOS 26.0, *)
@MainActor
final class OSDGlassRamp: NSObject {
    struct Leg {
        let key: String
        let to: Double
        let duration: TimeInterval
        let curve: CAMediaTimingFunction
        let delay: TimeInterval

        init(_ key: String, _ to: Double, _ duration: TimeInterval, _ curve: CAMediaTimingFunction,
             delay: TimeInterval = 0) {
            (self.key, self.to, self.duration, self.curve, self.delay) = (key, to, duration, curve, delay)
        }
    }

    private let layer: CALayer
    private let legs: [Leg]
    private let from: [String: Double]
    private let begin = CACurrentMediaTime()
    private var timer: Timer?

    init(layer: CALayer, legs: [Leg], from: [String: Double]) {
        (self.layer, self.legs, self.from) = (layer, legs, from)
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(step),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        step()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func step() {
        let elapsed = CACurrentMediaTime() - begin
        var values = layer.value(forKey: OSDGlass.targetsKey) as? [String: Double] ?? [:]
        var prior = from
        var seen = Set<String>()
        for leg in legs {
            let start = prior[leg.key] ?? leg.to
            if elapsed >= leg.delay || !seen.contains(leg.key) {
                values[leg.key] = start + (leg.to - start)
                    * leg.curve.solve(min(max(elapsed - leg.delay, 0) / leg.duration, 1))
            }
            prior[leg.key] = leg.to
            seen.insert(leg.key)
        }
        layer.setValue(values, forKey: OSDGlass.targetsKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.filters = layer.filters
        CATransaction.commit()
        if legs.allSatisfy({ elapsed >= $0.delay + $0.duration }) { stop() }
    }
}

extension CAMediaTimingFunction {
    /// The curve's output at an input time, 0...1. Nothing public evaluates a
    /// timing function; this is the method Core Animation itself uses.
    func solve(_ time: Double) -> Double {
        let selector = NSSelectorFromString("_solveForInput:")
        guard responds(to: selector) else { return time }
        typealias Solve = @convention(c) (AnyObject, Selector, Float) -> Float
        return Double(unsafeBitCast(method(for: selector), to: Solve.self)(self, selector, Float(time)))
    }
}
