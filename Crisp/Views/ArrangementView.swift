import SwiftUI

/// Visual display arrangement view.
/// Shows all active displays as scaled thumbnails on a canvas.
/// Supports drag-to-reposition and "Set as main display" button for secondary displays.
struct ArrangementView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var draggedID: CGDirectDisplayID?
    @State private var dragOffset: CGSize = .zero
    @State private var dragError: String?

    private let canvasHeight: CGFloat = 160

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
            }
            .frame(height: canvasHeight)

            // Drag error feedback
            if let err = dragError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            // "Set as main display" for non-main displays
            ForEach(displayManager.displays.filter { !$0.isMain }) { display in
                Button(action: {
                    Task { @MainActor in
                        let ok = await ArrangementService.shared.setAsMainDisplay(
                            display.displayID,
                            among: displayManager.displays
                        )
                        if ok { displayManager.refreshDisplays() }
                    }
                }) {
                    Label("Set \(display.name) as Main Display", systemImage: "star.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
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
            DisplayThumbnailView(display: display, isDragged: isDragged)
                .frame(width: max(rect.width, 40), height: max(rect.height, 25))
                .position(
                    x: rect.midX + (isDragged ? dragOffset.width : 0),
                    y: rect.midY + (isDragged ? dragOffset.height : 0)
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            draggedID = display.displayID
                            dragOffset = snappedCanvasOffset(for: display, translation: value.translation, canvasSize: canvasSize)
                        }
                        .onEnded { value in
                            applyDrag(for: display, translation: value.translation, canvasSize: canvasSize)
                            draggedID = nil
                            dragOffset = .zero
                        }
                )
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

        // 0.6x leaves free canvas around the thumbnails so displays can be
        // dragged to a new side without leaving the canvas. Keep in sync with canvasScale.
        let scale = min(availW / totalW, availH / totalH) * 0.6
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
        return min((canvasSize.width - padding * 2) / totalW, (canvasSize.height - padding * 2) / totalH) * 0.6
    }

    /// Proposed screen-space rect for the dragged display, snapped to the other displays.
    private func snappedScreenRect(for display: DisplayInfo, translation: CGSize, scale: CGFloat) -> CGRect {
        let proposed = CGDisplayBounds(display.displayID)
            .offsetBy(dx: translation.width / scale, dy: translation.height / scale)
        let others = displayManager.displays
            .filter { $0.displayID != display.displayID }
            .map { CGDisplayBounds($0.displayID) }
        // Threshold is ~10 canvas points, expressed in screen points.
        return snappedRect(proposed, others: others, threshold: 10 / scale)
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
            let ok = await ArrangementService.shared.setPosition(x: newX, y: newY, for: display.displayID)
            if ok {
                displayManager.refreshDisplays()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dragError = "Failed to arrange displays. Please try again."
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

// MARK: - Display Thumbnail

private struct DisplayThumbnailView: View {
    let display: DisplayInfo
    let isDragged: Bool

    var body: some View {
        ZStack {
            // Background fill
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    display.isBuiltin
                    ? AnyShapeStyle(LinearGradient(
                        colors: [.blue.opacity(0.75), .purple.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isDragged ? Color.accentColor : (display.isMain ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.4)),
                            lineWidth: isDragged ? 2 : (display.isMain ? 1.5 : 1)
                        )
                )

            // External display top decorative bar (border feel)
            if !display.isBuiltin {
                VStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 3)
                    Spacer()
                }
                .padding(.horizontal, 3)
                .padding(.top, 3)
            }

            // Display name + main display marker
            VStack(spacing: 2) {
                Text(display.name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(display.isBuiltin ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if display.isMain {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 5))
                        Text("Main")
                            .font(.system(size: 6))
                    }
                    .foregroundColor(display.isBuiltin ? .white.opacity(0.9) : .blue)
                }
            }
            .padding(3)
        }
        .scaleEffect(isDragged ? 1.04 : 1.0)
        .shadow(color: .black.opacity(isDragged ? 0.3 : 0.05), radius: isDragged ? 6 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragged)
    }
}
