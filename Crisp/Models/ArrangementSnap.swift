import CoreGraphics

/// Snapping for a display dragged in Arrange Displays. All rects are in global display
/// coordinates (origin top left, y down).
enum ArrangementSnap {
    /// A line through both centers, from the far edge of one display to the far edge of the other.
    struct Guide: Equatable {
        var from: CGPoint
        var to: CGPoint
    }

    struct Result: Equatable {
        var rect: CGRect
        /// Set while the dragged display's center lines up with the display it hugs (#259).
        var centerGuide: Guide?
    }

    /// Hugs the nearest neighbour's side, then slides along that side to line up an edge or
    /// the center with it, whichever is nearest within its leeway. An alignment that would
    /// slide into a third display is dropped.
    static func snapped(_ rect: CGRect, others: [CGRect], edgeThreshold: CGFloat,
                        centerThreshold: CGFloat) -> Result {
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
        let canX = abs(bestDX) <= edgeThreshold
        let canY = abs(bestDY) <= edgeThreshold
        let partner: CGRect
        let sideBySide: Bool
        if canX, !canY || abs(bestDX) <= abs(bestDY), let o = partnerX {
            r.origin.x += bestDX
            partner = o
            sideBySide = true
        } else if canY, let o = partnerY {
            r.origin.y += bestDY
            partner = o
            sideBySide = false
        } else {
            return Result(rect: r)
        }

        // Slide along the shared side: top/bottom (or left/right) edges, or the centers.
        let edges = sideBySide
            ? [partner.minY - r.minY, partner.maxY - r.maxY]
            : [partner.minX - r.minX, partner.maxX - r.maxX]
        let center = sideBySide ? partner.midY - r.midY : partner.midX - r.midX
        let candidates = edges.filter { abs($0) <= edgeThreshold }
            + (abs(center) <= centerThreshold ? [center] : [])
        if let shift = candidates.min(by: { abs($0) < abs($1) }) {
            let slid = sideBySide ? r.offsetBy(dx: 0, dy: shift) : r.offsetBy(dx: shift, dy: 0)
            let overlaps = others.contains { o in
                let shared = o.intersection(slid)
                return shared.width > 0 && shared.height > 0
            }
            if !overlaps { r = slid }
        }

        // Rounding to whole points can leave a center half a point off.
        let centered = sideBySide ? abs(partner.midY - r.midY) <= 0.5 : abs(partner.midX - r.midX) <= 0.5
        guard centered else { return Result(rect: r) }
        let guide = sideBySide
            ? Guide(from: CGPoint(x: min(r.minX, partner.minX), y: partner.midY),
                    to: CGPoint(x: max(r.maxX, partner.maxX), y: partner.midY))
            : Guide(from: CGPoint(x: partner.midX, y: min(r.minY, partner.minY)),
                    to: CGPoint(x: partner.midX, y: max(r.maxY, partner.maxY)))
        return Result(rect: r, centerGuide: guide)
    }
}
