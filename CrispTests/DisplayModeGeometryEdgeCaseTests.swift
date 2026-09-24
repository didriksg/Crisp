import XCTest

/// Headless edge-case coverage for `DisplayModeGeometry`: the 720p eligibility floor,
/// square (orientation-neutral) modes, and the all-HiDPI `nativeAspect` fallback, which
/// the sibling `DisplayModeGeometryTests` doesn't reach.
final class DisplayModeGeometryEdgeCaseTests: XCTestCase {

    // MARK: - isResolutionMenuEligible

    /// The HD floor is inclusive: exactly 720p is eligible, in either orientation.
    func testExactly720pIsEligibleInEitherOrientation() {
        XCTAssertTrue(DisplayModeGeometry.isResolutionMenuEligible(width: 1280, height: 720))
        XCTAssertTrue(DisplayModeGeometry.isResolutionMenuEligible(width: 720, height: 1280))
    }

    /// 1080p and a 21:9 ultrawide clear the floor.
    func testCommonHDAndUltrawideAreEligible() {
        XCTAssertTrue(DisplayModeGeometry.isResolutionMenuEligible(width: 1920, height: 1080))
        XCTAssertTrue(DisplayModeGeometry.isResolutionMenuEligible(width: 3440, height: 1440))
        XCTAssertTrue(DisplayModeGeometry.isResolutionMenuEligible(width: 1080, height: 3440))
    }

    /// A short side below 720 is rejected even when the long side is fine.
    func testShortSideBelow720Rejected() {
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 1280, height: 700))
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 700, height: 1280))
    }

    /// A long side below 1280 is rejected even when the short side clears 720.
    func testLongSideBelow1280Rejected() {
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 1024, height: 768))
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 768, height: 1024))
    }

    /// A square mode at/above the floor is eligible; one below the long-side floor is not.
    func testSquareEligibilityUsesSameFloor() {
        XCTAssertTrue(DisplayModeGeometry.isResolutionMenuEligible(width: 1280, height: 1280))
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 1200, height: 1200))
    }

    // MARK: - hasSameOrientation

    /// Landscape matches landscape, not portrait.
    func testLandscapeMatchesLandscapeNotPortrait() {
        XCTAssertTrue(DisplayModeGeometry.hasSameOrientation(
            width: 1920, height: 1080, as: 2560, 1440))
        XCTAssertFalse(DisplayModeGeometry.hasSameOrientation(
            width: 1920, height: 1080, as: 1440, 2560))
    }

    /// A square mode is orientation-neutral: it matches both landscape and portrait.
    func testSquareModeMatchesAnyOrientation() {
        XCTAssertTrue(DisplayModeGeometry.hasSameOrientation(
            width: 1080, height: 1080, as: 1920, 1080))
        XCTAssertTrue(DisplayModeGeometry.hasSameOrientation(
            width: 1080, height: 1080, as: 1080, 1920))
    }

    // MARK: - nativeAspect

    /// No modes → 0, so the caller's <=0 guard skips the filter instead of crashing.
    func testEmptyModesReturnZeroAspect() {
        XCTAssertEqual(DisplayModeGeometry.nativeAspect(from: []), 0)
    }

    /// A single unscaled landscape mode yields its aspect.
    func testSingleUnscaledLandscapeModeAspect() {
        let modes = [DisplayModeGeometry(width: 1920, height: 1080,
                                         pixelWidth: 1920, pixelHeight: 1080)]
        XCTAssertEqual(DisplayModeGeometry.nativeAspect(from: modes),
                       1920.0 / 1080.0, accuracy: 0.001)
    }

    /// A single unscaled portrait mode yields a sub-1.0 aspect.
    func testSingleUnscaledPortraitModeAspect() {
        let modes = [DisplayModeGeometry(width: 1080, height: 1920,
                                         pixelWidth: 1080, pixelHeight: 1920)]
        XCTAssertEqual(DisplayModeGeometry.nativeAspect(from: modes),
                       1080.0 / 1920.0, accuracy: 0.001)
    }

    /// When every mode is HiDPI (no unscaled 1x timing), nativeAspect falls back to the
    /// largest mode instead of returning 0.
    func testAllHiDPIFallbackUsesLargestModeAspect() {
        let modes = [
            DisplayModeGeometry(width: 2560, height: 1440,
                                pixelWidth: 5120, pixelHeight: 2880),
            DisplayModeGeometry(width: 1920, height: 1080,
                                pixelWidth: 3840, pixelHeight: 2160)
        ]
        XCTAssertEqual(DisplayModeGeometry.nativeAspect(from: modes),
                       2560.0 / 1440.0, accuracy: 0.001)
    }

    /// A zero-height mode returns 0 instead of dividing by zero.
    func testZeroHeightModeReturnsZeroAspect() {
        let modes = [DisplayModeGeometry(width: 1920, height: 0,
                                         pixelWidth: 1920, pixelHeight: 0)]
        XCTAssertEqual(DisplayModeGeometry.nativeAspect(from: modes), 0)
    }
}
