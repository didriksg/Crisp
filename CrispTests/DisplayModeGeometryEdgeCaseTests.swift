import XCTest

/// Headless edge-case coverage for `DisplayModeGeometry`.
///
/// `DisplayModeGeometry` is compiled directly into this test target (see `project.yml`
/// sources). The sibling `DisplayModeGeometryTests` pins the portrait-menu behaviour; the
/// cases here pin the boundaries it doesn't reach — the 720p eligibility floor, square
/// (orientation-neutral) modes, and the all-HiDPI `nativeAspect` fallback — so each branch
/// keeps its documented behaviour. Each test names the mutation/edge it pins in a
/// trailing comment.
final class DisplayModeGeometryEdgeCaseTests: XCTestCase {

    // MARK: - isResolutionMenuEligible

    /// The HD floor is inclusive: exactly 720p (short side 720, long side 1280) is the
    /// minimum the menu offers, in either orientation.
    /// Kills mutation: ">= downgraded to strict >, dropping exactly-720p".
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

    /// A short side below 720 is rejected even when the long side is fine (e.g. a
    /// 1280x700 mode just under the floor).
    /// Kills mutation: "short-side check dropped".
    func testShortSideBelow720Rejected() {
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 1280, height: 700))
        XCTAssertFalse(DisplayModeGeometry.isResolutionMenuEligible(width: 700, height: 1280))
    }

    /// A long side below 1280 is rejected even when the short side clears 720 (e.g. the
    /// 4:3 XGA 1024x768, which is sub-HD on its long side).
    /// Kills mutation: "long-side check dropped, only the short side gates eligibility".
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

    /// Same-orientation landscape vs landscape is true; landscape vs portrait is false.
    /// Kills mutation: "comparison inverted, landscape modes start matching portrait refs".
    func testLandscapeMatchesLandscapeNotPortrait() {
        XCTAssertTrue(DisplayModeGeometry.hasSameOrientation(
            width: 1920, height: 1080, as: 2560, 1440))
        XCTAssertFalse(DisplayModeGeometry.hasSameOrientation(
            width: 1920, height: 1080, as: 1440, 2560))
    }

    /// A square mode is orientation-neutral: it matches both a landscape and a portrait
    /// reference so the resolution menu still offers 1:1 modes regardless of rotation.
    /// Pins current behaviour against a regression to "square matches nothing".
    func testSquareModeMatchesAnyOrientation() {
        XCTAssertTrue(DisplayModeGeometry.hasSameOrientation(
            width: 1080, height: 1080, as: 1920, 1080))
        XCTAssertTrue(DisplayModeGeometry.hasSameOrientation(
            width: 1080, height: 1080, as: 1080, 1920))
    }

    // MARK: - nativeAspect

    /// No modes → 0 (the caller treats <=0 as "no aspect known" and skips the filter).
    /// Kills mutation: "empty-input guard removed, force-unwraps the max".
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

    /// When every reported mode is HiDPI (no unscaled 1x timing, e.g. an Apple Retina
    /// panel in CG), `nativeAspect` falls back to the full set and still derives the
    /// aspect from the largest mode. The largest HiDPI mode is the native-aspect twin,
    /// so the returned aspect is the panel's true 16:9.
    /// Pins the all-HiDPI fallback against a regression to "returns 0 when nothing is 1x".
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

    /// A zero-height mode must not produce a divide-by-zero/NaN: the guard returns 0.
    /// Kills mutation: "height > 0 guard removed".
    func testZeroHeightModeReturnsZeroAspect() {
        let modes = [DisplayModeGeometry(width: 1920, height: 0,
                                         pixelWidth: 1920, pixelHeight: 0)]
        XCTAssertEqual(DisplayModeGeometry.nativeAspect(from: modes), 0)
    }
}
