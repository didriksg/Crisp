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

    /// A notch narrows the native aspect (~1.54) well below the 16:10 every other Mac
    /// panel meets or exceeds, using the resolution list's 2% tolerance. The lower bound
    /// excludes portrait aspects, where rotated dims make the notch check meaningless.
    static func isNotchedPanelAspect(_ nativeAspect: Double) -> Bool {
        let sixteenTen = 16.0 / 10.0
        return nativeAspect > 1 && (sixteenTen - nativeAspect) / sixteenTen >= 0.02
    }

    /// Whether a mode size belongs to the panel's native-aspect family: on a
    /// notched panel these are the notch-including sizes (1512×982, ...), as
    /// opposed to the 16:10 letterboxed twins (1512×945, ...) that hide it.
    static func matchesNativeAspect(width: Int, height: Int, nativeAspect: Double) -> Bool {
        guard height > 0, nativeAspect > 0 else { return false }
        return abs(Double(width) / Double(height) - nativeAspect) / nativeAspect < 0.02
    }
}
