struct DisplayModeGeometry: Equatable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int

    static func nativeAspect(from modes: [DisplayModeGeometry]) -> Double {
        let unscaled = modes.filter {
            $0.pixelWidth == $0.width && $0.pixelHeight == $0.height
        }
        let candidates = unscaled.isEmpty ? modes : unscaled
        guard let largest = candidates.max(by: {
            $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }), largest.height > 0 else { return 0 }
        return Double(largest.width) / Double(largest.height)
    }

    static func isResolutionMenuEligible(width: Int, height: Int) -> Bool {
        min(width, height) >= 720 && max(width, height) >= 1280
    }

    static func hasSameOrientation(width: Int, height: Int,
                                   as referenceWidth: Int, _ referenceHeight: Int) -> Bool {
        if width == height || referenceWidth == referenceHeight { return true }
        return (width > height) == (referenceWidth > referenceHeight)
    }
}
