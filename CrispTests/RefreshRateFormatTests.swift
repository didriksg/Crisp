import XCTest
import CoreGraphics

/// Headless tests for the refresh-rate label formatter.
///
/// `RefreshRateFormat` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DisplayModeGeometry`), so no `@testable import Crisp` is
/// needed. Each test names the behaviour it pins in a trailing comment.
final class RefreshRateFormatTests: XCTestCase {

    // MARK: - Display-default (0 Hz)

    /// CGDisplayMode.refreshRate returns 0 for the panel's default timing. It must render
    /// as the default 60 Hz (honouring `DisplayMode.refreshRate`'s "0 means display
    /// default, shown as 60" contract), not a placeholder, so a real mode never reads as
    /// broken next to its labelled siblings.
    /// Kills mutation: "guard returns the old '-- Hz' placeholder".
    func testZeroRefreshRateRendersAsDefaultSixty() {
        XCTAssertEqual(RefreshRateFormat.label(0), "60Hz")
    }

    /// Negative rates don't occur (CG reports 0 or a positive timing) but the guard must
    /// still map any non-positive value to the default rather than formatting garbage.
    func testNegativeRefreshRateFallsBackToDefault() {
        XCTAssertEqual(RefreshRateFormat.label(-1), "60Hz")
    }

    // MARK: - Whole-number timings

    /// A clean whole rate renders without a decimal, matching System Settings.
    func testWholeNumberRendersWithoutDecimals() {
        XCTAssertEqual(RefreshRateFormat.label(60), "60Hz")
        XCTAssertEqual(RefreshRateFormat.label(144), "144Hz")
        XCTAssertEqual(RefreshRateFormat.label(30), "30Hz")
    }

    /// A rate within the whole-rounding threshold (float noise around an integer) still
    /// collapses to the clean integer label.
    /// Kills mutation: "threshold tightened so 59.999 stops rendering as 60Hz".
    func testNearWholeRateCollapsesToInteger() {
        XCTAssertEqual(RefreshRateFormat.label(59.999), "60Hz")
        XCTAssertEqual(RefreshRateFormat.label(60.005), "60Hz")
    }

    // MARK: - NTSC fractional timings

    /// NTSC fractional timings keep two decimals so they don't collapse onto the
    /// neighbouring whole rate (59.94 vs 60) and duplicate a row, matching System Settings.
    /// Kills mutation: "fractional branch lost, everything rounds to a whole Hz".
    func testNTSCFractionalRatesKeepTwoDecimals() {
        XCTAssertEqual(RefreshRateFormat.label(59.94), "59.94Hz")
        XCTAssertEqual(RefreshRateFormat.label(29.97), "29.97Hz")
        XCTAssertEqual(RefreshRateFormat.label(119.88), "119.88Hz")
    }

    /// Cinema 23.976 rounds to two decimals as 23.98 (NSString %.2f rounding), not the
    /// raw 23.976 and not a collapse to 24.
    func testCinemaRateRoundsToTwoDecimals() {
        XCTAssertEqual(RefreshRateFormat.label(23.976), "23.98Hz")
        XCTAssertEqual(RefreshRateFormat.label(47.952), "47.95Hz")
    }
}
