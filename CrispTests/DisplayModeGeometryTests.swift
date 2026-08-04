import XCTest

final class DisplayModeGeometryTests: XCTestCase {
    func testPortraitNativeAspectIgnoresLargerLandscapeHiDPIBacking() {
        let modes = [
            DisplayModeGeometry(
                width: 1440, height: 2560,
                pixelWidth: 1440, pixelHeight: 2560
            ),
            DisplayModeGeometry(
                width: 2560, height: 1440,
                pixelWidth: 5120, pixelHeight: 2880
            )
        ]

        XCTAssertEqual(
            DisplayModeGeometry.nativeAspect(from: modes),
            1440.0 / 2560.0,
            accuracy: 0.001
        )
    }

    func testPortraitRetinaPointIsEligibleForResolutionMenu() {
        XCTAssertTrue(
            DisplayModeGeometry.isResolutionMenuEligible(width: 720, height: 1280)
        )
    }

    func testPortraitMenuRejectsLandscapeModes() {
        XCTAssertFalse(
            DisplayModeGeometry.hasSameOrientation(
                width: 1920, height: 1080, as: 1440, 2560
            )
        )
        XCTAssertTrue(
            DisplayModeGeometry.hasSameOrientation(
                width: 1080, height: 1920, as: 1440, 2560
            )
        )
    }
}
