import XCTest
import CoreGraphics

/// Headless tests for the refresh-rate label formatter. `RefreshRateFormat` compiles
/// directly into this test target, so no `@testable import Crisp` is needed.
final class RefreshRateFormatTests: XCTestCase {

    // MARK: - Display-default (0 Hz)

    /// 0 (display default) renders as `60Hz`, not a placeholder.
    func testZeroRefreshRateRendersAsDefaultSixty() {
        XCTAssertEqual(RefreshRateFormat.label(0), "60Hz")
    }

    /// A negative rate (shouldn't occur) still falls back to the default, not garbage.
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

    /// Float noise around an integer (59.999) still collapses to the clean integer label.
    func testNearWholeRateCollapsesToInteger() {
        XCTAssertEqual(RefreshRateFormat.label(59.999), "60Hz")
        XCTAssertEqual(RefreshRateFormat.label(60.005), "60Hz")
    }

    // MARK: - NTSC fractional timings

    /// NTSC fractional rates keep two decimals so they don't collapse onto the whole rate.
    func testNTSCFractionalRatesKeepTwoDecimals() {
        XCTAssertEqual(RefreshRateFormat.label(59.94), "59.94Hz")
        XCTAssertEqual(RefreshRateFormat.label(29.97), "29.97Hz")
        XCTAssertEqual(RefreshRateFormat.label(119.88), "119.88Hz")
    }

    /// Cinema 23.976 rounds to 23.98, not a collapse to 24.
    func testCinemaRateRoundsToTwoDecimals() {
        XCTAssertEqual(RefreshRateFormat.label(23.976), "23.98Hz")
        XCTAssertEqual(RefreshRateFormat.label(47.952), "47.95Hz")
    }
}
