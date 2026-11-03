import XCTest

/// Headless tests for how a preset reaches its saved resolution (#65, #232).
final class DisplayPresetResolutionTests: XCTestCase {
    private func entry(_ w: Int, _ h: Int, hiDPI: Bool?) -> DisplayPresetEntry {
        DisplayPresetEntry(displayUUID: "ABC", width: w, height: h, isHiDPI: hiDPI)
    }

    /// A 5K2K panel: 4096x1728 enumerates only at 1x, and HiDPI at that size is a mirror stop.
    private let ultrawide: [(width: Int, height: Int, isHiDPI: Bool)] = [
        (5120, 2160, false), (4096, 1728, false), (3360, 1418, true), (3360, 1418, false)
    ]
    private let stops: [(width: Int, height: Int)] = [(4096, 1728), (5104, 2153)]

    /// #232: a HiDPI size past the cap goes through the mirror, not to its soft 1x twin.
    func testBeyondCapHiDPIPrefersMirrorOverOneXTwin() {
        XCTAssertEqual(entry(4096, 1728, hiDPI: true).resolutionRoute(modes: ultrawide, mirrorStops: stops), .mirror)
    }

    func testExactModeWins() {
        XCTAssertEqual(entry(3360, 1418, hiDPI: true).resolutionRoute(modes: ultrawide, mirrorStops: stops), .mode(2))
        XCTAssertEqual(entry(4096, 1728, hiDPI: false).resolutionRoute(modes: ultrawide, mirrorStops: stops), .mode(1))
    }

    /// A HiDPI size with no HiDPI mode and no mirror route (smooth scaling turned off since)
    /// still lands on the same size at 1x, as before.
    func testOtherKindIsTheLastResort() {
        XCTAssertEqual(entry(4096, 1728, hiDPI: true).resolutionRoute(modes: ultrawide, mirrorStops: []), .mode(1))
    }

    func testOldPresetWithoutHiDPIFlagReadsAsOneX() {
        XCTAssertEqual(entry(4096, 1728, hiDPI: nil).resolutionRoute(modes: ultrawide, mirrorStops: stops), .mode(1))
    }

    func testMissingSizeIsUnavailable() {
        XCTAssertEqual(entry(1920, 1080, hiDPI: true).resolutionRoute(modes: ultrawide, mirrorStops: stops), .unavailable)
    }

    func testNoResolutionCaptureHasNoRoute() {
        XCTAssertNil(DisplayPresetEntry(displayUUID: "ABC").resolutionRoute(modes: ultrawide, mirrorStops: stops))
    }
}
