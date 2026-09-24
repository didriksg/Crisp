import AppKit
import CoreImage

/// The macOS 27 capsule's tuning table: the glass filter's inputs and the
/// clock every part of the entry and exit runs on. OSDBannerPanel reads them.
/// Measured: see docs/osd-notes.md (Glass entry and exit timing, Glass blur,
/// bend and tint, Glass shimmer). Change a value by remeasuring, not by taste.
@available(macOS 26.0, *)
extension OSDBannerService {
    static let glassExitInset = CGSize(width: 18, height: 4)
    static let glassWindowInDuration: TimeInterval = 0.02
    static let glassInDuration: TimeInterval = 0.62
    static let glassInCurve = CAMediaTimingFunction(controlPoints: 0.3, 0.12, 0.3, 1)
    static let glassContentInDuration: TimeInterval = 0.72
    static let glassContentInCurve = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.3, 1)
    static let glassGrowInDuration: TimeInterval = 0.48
    static let glassGrowInCurve = CAMediaTimingFunction(controlPoints: 0, 0.55, 0.25, 1)
    static let glassRimInDuration: TimeInterval = 0.55
    static let glassRimInCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    static let glassRimStart = 0.0
    static let glassHighlight = (open: 0.4, closed: 0.0)
    static let glassSettleInDuration: TimeInterval = 0.7
    static let glassSettleInCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.2, 0.45, 1)
    static let glassBlurInCurve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.5, 1)
    static let glassOutDuration: TimeInterval = 0.5
    static let glassBlurOutDuration: TimeInterval = 0.3
    static let glassTintOutDuration: TimeInterval = 0.35
    static let glassBendOutDuration: TimeInterval = 0.35
    static let glassRimOutDuration: TimeInterval = 0.35
    static let glassOutCurve = CAMediaTimingFunction(controlPoints: 0.15, 0.25, 0.3, 1)
    static let glassWindowOutDuration: TimeInterval = 0.5
    static let glassWindowOutCurve = CAMediaTimingFunction(controlPoints: 0.35, 0.25, 0.45, 1)
    /// The dark variant of the system's own glass filter, the closest fit.
    static let glassVariant = 2
    nonisolated static let glassBackdropScale = 1.0
    static let glassBlurStep = 0.3
    static let glassBlurStepDuration: TimeInterval = 0.06
    static let glassBlurRiseDelay: TimeInterval = 0.18
    static let glassBlurRiseDuration: TimeInterval = 0.45
    nonisolated static let glassInputs: [String: Double] = [
        "inputRefractionOpacity": 1,
        "inputBlurOpacity0": 0.8,
        "inputInnerRefractionHeight": 14,
        "inputFaceColorMatrixWhite": 0.79,
        "inputFaceColorMatrixBlack": 0.073,
        "inputFaceColorMatrixSaturation": 1.4
    ]
    /// Open and closed are the same: the lens is full from the first frame,
    /// and closed is only where the exit ends.
    static let glassBlur = (open: 0.95, closed: 0.95)
    static let glassBend = (open: -75.0, closed: 0.0)
    static var glassBendInDuration: TimeInterval { glassRefractionHeightDuration }
    static let glassBendInCurve = CAMediaTimingFunction(controlPoints: 0.05, 0.5, 0.3, 1)
    static let glassRefractionHeight = (open: 15.0, closed: 0.0)
    static let glassRefractionHeightDuration: TimeInterval = 0.44
    /// Closed is nothing: the face brings the entry in, not the window.
    static let glassTint = (open: 0.88, closed: 0.0)
    static let glassShimmerScale = 0.45
    static let glassShimmerDelay: TimeInterval = 0.20
    static let glassShimmerDuration: TimeInterval = 0.30
    static let glassShimmerReturnDelay: TimeInterval = 0.50
    static let glassShimmerReturnDuration: TimeInterval = 0.20
}
