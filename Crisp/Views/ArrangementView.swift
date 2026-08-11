import SwiftUI
import AppKit
import ImageIO

/// Visual display arrangement view.
/// Shows all active displays as scaled thumbnails on a canvas.
/// Supports drag-to-reposition and "Set as main display" button for secondary displays.
struct ArrangementView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var draggedID: CGDirectDisplayID?
    @State private var dragOffset: CGSize = .zero
    @State private var dragError: String?
    @State private var hoveredID: CGDirectDisplayID?

    private let canvasHeight: CGFloat = 190
    /// Fraction of the canvas the displays fill; the rest stays free so a display
    /// can be dragged to a new side without leaving the canvas. computeLayout and
    /// canvasScale must use the same value.
    private let canvasFillRatio: CGFloat = 0.78

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Visual canvas
            GeometryReader { geo in
                ZStack {
                    // Grid background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.underPageBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    // Display thumbnails
                    thumbnails(canvasSize: geo.size)
                }
                // Stable space for the drag gesture; see the gesture comment.
                .coordinateSpace(.named("arranger"))
            }
            .frame(height: canvasHeight)
            .onDisappear { DisplayIdentifierOverlay.hide() }

            // Drag error feedback
            if let err = dragError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnails(canvasSize: CGSize) -> some View {
        let layout = computeLayout(canvasSize: canvasSize)
        ForEach(displayManager.displays) { display in
            let rect = layout[display.displayID] ?? CGRect(x: canvasSize.width / 2, y: canvasSize.height / 2, width: 60, height: 40)
            let isDragged = draggedID == display.displayID
            let identified = hoveredID == display.displayID || isDragged
            DisplayThumbnailView(display: display, isDragged: isDragged)
                .frame(width: max(rect.width, 40), height: max(rect.height, 25))
                // Hover/drag must attach to the framed thumbnail BEFORE .position:
                // .position expands the view to fill the canvas, so a hit test
                // placed after it would cover the whole canvas, not this screen.
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        if hovering { hoveredID = display.displayID } else if hoveredID == display.displayID { hoveredID = nil }
                    }
                }
                .gesture(
                    // minimumDistance 0 so the red identifier appears the instant
                    // you press (hold), not only once the display starts moving.
                    // The fixed "arranger" space keeps translation stable: measured
                    // in the thumbnail's own (moving) space it fed back and made the
                    // display jitter between its new and old position.
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("arranger"))
                        .onChanged { value in
                            draggedID = display.displayID
                            dragOffset = snappedCanvasOffset(for: display, translation: value.translation, canvasSize: canvasSize)
                            DisplayIdentifierOverlay.show(for: display.displayID)
                        }
                        .onEnded { value in
                            // A press without real movement is just a click: flash
                            // the identifier, don't reposition the display.
                            let moved = abs(value.translation.width) + abs(value.translation.height)
                            if moved > 2 {
                                applyDrag(for: display, translation: value.translation, canvasSize: canvasSize)
                            }
                            draggedID = nil
                            dragOffset = .zero
                            DisplayIdentifierOverlay.hide()
                        }
                )
                .position(
                    x: rect.midX + (isDragged ? dragOffset.width : 0),
                    y: rect.midY + (isDragged ? dragOffset.height : 0)
                )
                .zIndex(identified ? 2 : 0)
        }

        // Native cue: hovering (or dragging) a screen floats its name in a callout
        // above the thumbnail, its tail meeting the top edge. This is a separate
        // canvas-positioned layer, NOT an overlay on the thumbnail: the thumbnail's
        // own .position swallowed an overlay lift and left the bubble overlapping
        // the wallpaper. Positioning the callout here (same coordinate space the
        // thumbnails use) plants its bottom edge exactly on the thumbnail's top.
        ForEach(displayManager.displays) { display in
            let rect = layout[display.displayID] ?? CGRect(x: canvasSize.width / 2, y: canvasSize.height / 2, width: 60, height: 40)
            let isDragged = draggedID == display.displayID
            if hoveredID == display.displayID || isDragged {
                DisplayNameBadge(name: display.name, lift: false)
                    .modifier(BadgeAbove(
                        x: rect.midX + (isDragged ? dragOffset.width : 0),
                        topY: rect.minY + (isDragged ? dragOffset.height : 0)
                    ))
                    .zIndex(3)
                    .transition(.opacity)
            }
        }
    }

    /// Computes the canvas-space rect for each display, scaled to fit the canvas.
    private func computeLayout(canvasSize: CGSize) -> [CGDirectDisplayID: CGRect] {
        let displays = displayManager.displays
        guard !displays.isEmpty else { return [:] }

        let allBounds = displays.map { CGDisplayBounds($0.displayID) }
        let minX = allBounds.map { $0.minX }.min() ?? 0
        let minY = allBounds.map { $0.minY }.min() ?? 0
        let maxX = allBounds.map { $0.maxX }.max() ?? 1
        let maxY = allBounds.map { $0.maxY }.max() ?? 1

        let totalW = maxX - minX
        let totalH = maxY - minY
        guard totalW > 0, totalH > 0 else { return [:] }

        let padding: CGFloat = 16
        let availW = canvasSize.width - padding * 2
        let availH = canvasSize.height - padding * 2

        let scale = min(availW / totalW, availH / totalH) * canvasFillRatio
        let scaledW = totalW * scale
        let scaledH = totalH * scale
        let offsetX = padding + (availW - scaledW) / 2
        let offsetY = padding + (availH - scaledH) / 2

        var result: [CGDirectDisplayID: CGRect] = [:]
        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)
            let x = offsetX + (bounds.minX - minX) * scale
            let y = offsetY + (bounds.minY - minY) * scale
            let w = bounds.width * scale
            let h = bounds.height * scale
            result[display.displayID] = CGRect(x: x, y: y, width: w, height: h)
        }
        return result
    }

    /// Scale factor mapping screen space to canvas space (same math as computeLayout).
    private func canvasScale(canvasSize: CGSize) -> CGFloat {
        let allBounds = displayManager.displays.map { CGDisplayBounds($0.displayID) }
        guard !allBounds.isEmpty else { return 0 }
        let minX = allBounds.map { $0.minX }.min() ?? 0
        let minY = allBounds.map { $0.minY }.min() ?? 0
        let maxX = allBounds.map { $0.maxX }.max() ?? 1
        let maxY = allBounds.map { $0.maxY }.max() ?? 1
        let totalW = maxX - minX
        let totalH = maxY - minY
        guard totalW > 0, totalH > 0 else { return 0 }
        let padding: CGFloat = 16
        return min((canvasSize.width - padding * 2) / totalW, (canvasSize.height - padding * 2) / totalH) * canvasFillRatio
    }

    /// Proposed screen-space rect for the dragged display, snapped to the other displays.
    private func snappedScreenRect(for display: DisplayInfo, translation: CGSize, scale: CGFloat) -> CGRect {
        let proposed = CGDisplayBounds(display.displayID)
            .offsetBy(dx: translation.width / scale, dy: translation.height / scale)
        let others = displayManager.displays
            .filter { $0.displayID != display.displayID }
            .map { CGDisplayBounds($0.displayID) }
        // Resolve overlap first (choosing the side the drag pulls toward), then
        // edge-snap for clean alignment. Displays can never overlap, like the
        // native Arrange Displays sheet.
        let resolved = resolveOverlaps(proposed, others: others)
        return snappedRect(resolved, others: others, threshold: 10 / scale)
    }

    /// Canvas-space drag offset with snapping applied, for live thumbnail feedback.
    private func snappedCanvasOffset(for display: DisplayInfo, translation: CGSize, canvasSize: CGSize) -> CGSize {
        let scale = canvasScale(canvasSize: canvasSize)
        guard scale > 0 else { return translation }
        let bounds = CGDisplayBounds(display.displayID)
        let snapped = snappedScreenRect(for: display, translation: translation, scale: scale)
        return CGSize(width: (snapped.minX - bounds.minX) * scale,
                      height: (snapped.minY - bounds.minY) * scale)
    }

    /// Converts the drag translation to screen coordinates, snaps to neighboring
    /// displays, and applies the new position.
    private func applyDrag(for display: DisplayInfo, translation: CGSize, canvasSize: CGSize) {
        let scale = canvasScale(canvasSize: canvasSize)
        guard scale > 0 else { return }
        let snapped = snappedScreenRect(for: display, translation: translation, scale: scale)
        let newX = Int(snapped.minX.rounded())
        let newY = Int(snapped.minY.rounded())

        Task { @MainActor in
            let ok = await ArrangementService.shared.setPosition(
                x: newX, y: newY, for: display.displayID, among: displayManager.displays)
            // On success the reconfiguration callback (.movedFlag) rebuilds the display
            // list; refreshing here too rebuilt it twice per drag.
            if !ok {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dragError = String(localized: "Failed to arrange displays. Please try again.")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { self.dragError = nil }
                }
            }
        }
    }
}

// MARK: - Snap Logic

/// Only does "edge hug" snapping: horizontally hug another display's left/right side (optionally with top/bottom edge alignment),
/// or vertically hug its top/bottom (optionally with left/right edge alignment).
/// Does not do center alignment, nor isolated edge alignment without a hug relationship.
func snappedRect(_ rect: CGRect, others: [CGRect], threshold: CGFloat) -> CGRect {
    var r = rect
    var bestDX = CGFloat.infinity
    var partnerX: CGRect?
    var bestDY = CGFloat.infinity
    var partnerY: CGRect?
    for o in others {
        for dx in [o.maxX - r.minX, o.minX - r.maxX] where abs(dx) < abs(bestDX) {
            bestDX = dx
            partnerX = o
        }
        for dy in [o.maxY - r.minY, o.minY - r.maxY] where abs(dy) < abs(bestDY) {
            bestDY = dy
            partnerY = o
        }
    }
    let canX = abs(bestDX) <= threshold
    let canY = abs(bestDY) <= threshold
    if canX && (!canY || abs(bestDX) <= abs(bestDY)) {
        // Horizontal hug (hug side) -> vertically only align top/bottom edges
        r.origin.x += bestDX
        if let o = partnerX,
           let align = [o.minY - r.minY, o.maxY - r.maxY].min(by: { abs($0) < abs($1) }),
           abs(align) <= threshold {
            r.origin.y += align
        }
    } else if canY {
        // Vertical hug (top/bottom stack) -> horizontally only align left/right edges
        r.origin.y += bestDY
        if let o = partnerY,
           let align = [o.minX - r.minX, o.maxX - r.maxX].min(by: { abs($0) < abs($1) }),
           abs(align) <= threshold {
            r.origin.x += align
        }
    }
    return r
}

/// Pushes `rect` out of any display it overlaps by snapping it flush against the
/// side it's being pulled toward, so displays can never sit on top of each other
/// (matching the native Arrange Displays sheet). Iterates so it settles against
/// multiple neighbors; capped to avoid a pathological oscillation looping forever.
func resolveOverlaps(_ rect: CGRect, others: [CGRect]) -> CGRect {
    var r = rect
    for _ in 0..<32 {
        guard let o = others.first(where: { overlapExtents($0, r) != nil }) else { break }
        r = snapToDominantSide(r, of: o)
    }
    return r
}

/// Places `r` flush against one side of `o`, choosing the side the drag is
/// pulling toward rather than the shallowest push (which makes a sideways drag
/// jump vertically). Horizontal stays put until `r`'s center passes `o`'s
/// center, then flips; it only switches to a vertical stack once the vertical
/// pull clearly dominates. Never leaves `r` overlapping `o`.
private func snapToDominantSide(_ r: CGRect, of o: CGRect) -> CGRect {
    var out = r
    let dx = r.midX - o.midX
    let dy = r.midY - o.midY
    // Strongly prefer side-by-side. Stack vertically only when the drag is
    // clearly more vertical than horizontal (the 1.8 bias) AND the vertical
    // pull is real: the center offset must exceed half the shorter display's
    // height. Without that absolute floor, a horizontal drag briefly stacks at
    // the crossover point (where dx≈0, so any dy beats the ratio test). Native
    // only stacks once you distinctly pull one display up or down.
    let verticalPullFloor = min(r.height, o.height) * 0.5
    if abs(dy) > abs(dx) * 1.8 && abs(dy) > verticalPullFloor {
        out.origin.y = dy >= 0 ? o.maxY : o.minY - r.height
    } else {
        out.origin.x = dx >= 0 ? o.maxX : o.minX - r.width
    }
    return out
}

/// Positive overlap width/height of two rects, or nil when they merely touch or
/// are disjoint (a shared edge is allowed, that's the target adjacent state).
private func overlapExtents(_ a: CGRect, _ b: CGRect) -> (x: CGFloat, y: CGFloat)? {
    let ox = min(a.maxX, b.maxX) - max(a.minX, b.minX)
    let oy = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    return (ox > 0 && oy > 0) ? (ox, oy) : nil
}

// MARK: - Display Name Badge

/// The dark name callout the native Arrange Displays sheet floats above a
/// display when you hover it: a rounded bubble with a downward tail.
struct DisplayNameBadge: View {
    let name: String
    /// Optional second line: the preset preview shows a display's resolution ·
    /// brightness here. nil in the arranger, which shows just the name.
    var detail: String? = nil
    /// When true (the preset preview), the callout lifts itself above its overlay
    /// anchor by its own measured height. The arranger sets this false and instead
    /// positions the callout in canvas space itself, because the `.position` applied
    /// to each draggable thumbnail swallows an overlay lift, leaving the bubble
    /// rendered top-against-top over the wallpaper.
    var lift: Bool = true
    @State private var height: CGFloat = 0

    private let fill = Color(white: 0.22)

    /// The bubble + downward tail, sized to its content. No lift, the caller
    /// decides how to place it (overlay self-lift, or explicit canvas position).
    private var callout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            )
            BadgeTail()
                .fill(fill)
                .frame(width: 12, height: 6)
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
    }

    var body: some View {
        Group {
            if lift {
                callout
                    .background(GeometryReader { g in
                        Color.clear.preference(key: BadgeHeightKey.self, value: g.size.height)
                    })
                    .onPreferenceChange(BadgeHeightKey.self) { if $0 > 0 { height = $0 } }
                    .offset(y: -height)   // lift fully above; tail meets the anchor's top edge
            } else {
                callout
            }
        }
        .allowsHitTesting(false)
    }
}

/// Measures the name callout's height so it can lift itself above the thumbnail.
private struct BadgeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Places a callout in canvas space so its BOTTOM edge (the tail tip) lands on
/// (x, topY), centered above the thumbnail with the tail meeting its top edge.
/// Measures the callout's height (seeded so the first frame is already placed).
private struct BadgeAbove: ViewModifier {
    let x: CGFloat
    let topY: CGFloat
    @State private var height: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear.preference(key: BadgeHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(BadgeHeightKey.self) { if $0 > 0 { height = $0 } }
            .position(x: x, y: topY - height / 2)
    }
}

/// Downward-pointing triangle for the badge's tail.
private struct BadgeTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Display Thumbnail

struct DisplayThumbnailView: View {
    let display: DisplayInfo
    let isDragged: Bool

    @State private var wallpaper: NSImage?

    var body: some View {
        // Color.clear adopts the exact frame proposed by the parent, so the
        // aspect-fill wallpaper (which reports a size larger than the frame to
        // cover it) is clipped to the frame instead of bleeding past it and
        // visually overlapping the neighbouring thumbnail.
        Color.clear
        .overlay {
            // Desktop wallpaper fill (native arranger look); a gradient/panel
            // fallback shows while it loads or when a display has no picture.
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(fallbackFill)
            }
        }
        .overlay(alignment: .top) {
            // Native cue: the main display shows a thin menu-bar strip at the top.
            // No name labels, the system Arrange Displays sheet has none either.
            if display.isMain {
                Rectangle()
                    .fill(.white.opacity(0.8))
                    .frame(height: 2.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isDragged ? Color.accentColor : Color.white.opacity(0.5),
                    lineWidth: isDragged ? 1.5 : 1
                )
        )
        // No scale-up on drag: native doesn't balloon the dragged display, and
        // the extra 4% made the drag overlap read wrong. A slightly deeper
        // shadow gives the "lifted" cue instead.
        .shadow(color: .black.opacity(isDragged ? 0.28 : 0.18),
                radius: isDragged ? 5 : 3, x: 0, y: isDragged ? 2 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragged)
        .task(id: display.displayID) {
            wallpaper = await DesktopWallpaper.image(for: display.displayID)
        }
    }

    private var fallbackFill: AnyShapeStyle {
        display.isBuiltin
        ? AnyShapeStyle(LinearGradient(
            colors: [.blue.opacity(0.75), .purple.opacity(0.65)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Desktop Wallpaper

/// Loads and caches a downsampled desktop-picture thumbnail per display, so the
/// arrangement thumbnails show each screen's wallpaper like the native
/// "Arrange Displays" sheet. Cached for the session (a wallpaper change needs a
/// relaunch to refresh, which is fine for a transient arrangement view).
@MainActor
enum DesktopWallpaper {
    private static var cache: [CGDirectDisplayID: NSImage] = [:]

    static func image(for displayID: CGDirectDisplayID, maxPixel: Int = 400) async -> NSImage? {
        if let cached = cache[displayID] { return cached }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }), let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        let image = await Task.detached(priority: .userInitiated) {
            downsample(url: url, maxPixel: maxPixel)
        }.value
        if let image { cache[displayID] = image }
        return image
    }

    nonisolated private static func downsample(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Physical Display Identifier

/// Draws a red border around a physical display, like the native Arrange
/// Displays sheet, so hovering or dragging a thumbnail shows which real screen
/// it maps to. A single transparent, click-through overlay window is reused and
/// moved between screens.
@MainActor
enum DisplayIdentifierOverlay {
    private static var window: NSWindow?
    private static var shownID: CGDirectDisplayID?

    static func show(for displayID: CGDirectDisplayID) {
        guard shownID != displayID else { return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }) else { hide(); return }
        shownID = displayID
        let w = window ?? makeWindow()
        window = w
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
    }

    /// Hides only if `displayID` is the one currently framed, so a thumbnail's
    /// hover-exit can't clear a border another thumbnail just raised.
    static func hide(for displayID: CGDirectDisplayID) {
        if shownID == displayID { hide() }
    }

    static func hide() {
        shownID = nil
        window?.orderOut(nil)
    }

    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemRed.cgColor
        border.layer?.borderWidth = 7
        border.layer?.cornerRadius = 10
        border.autoresizingMask = [.width, .height]
        w.contentView = border
        return w
    }
}
