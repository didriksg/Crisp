import XCTest

/// Headless tests for what the Brightness Control row shows. `BrightnessControlRoute`
/// compiles directly into this test target, so no `@testable import Crisp` is needed.
final class BrightnessControlRouteTests: XCTestCase {
    private func row(
        choseSoftware: Bool = false, hdr: Bool = false, ddcAvailable: Bool?, ddcReachable: Bool = false
    ) -> BrightnessControlRoute.Row {
        BrightnessControlRoute.row(
            choseSoftware: choseSoftware, hdr: hdr, ddcAvailable: ddcAvailable, ddcReachable: ddcReachable
        )
    }

    /// Right after launch: the channel is known, no write has settled DDC yet.
    func testMonitorWithChannelShowsHardwareBeforeTheFirstWrite() {
        XCTAssertEqual(row(ddcAvailable: nil, ddcReachable: true),
                       .init(visible: true, shown: .hardware, hardwareSelectable: true, fallback: false))
    }

    func testWorkingMonitorShowsHardware() {
        XCTAssertEqual(row(ddcAvailable: true, ddcReachable: true),
                       .init(visible: true, shown: .hardware, hardwareSelectable: true, fallback: false))
    }

    func testUserChoiceShowsSoftwareAlsoBeforeDDCIsKnown() {
        XCTAssertEqual(row(choseSoftware: true, ddcAvailable: nil),
                       .init(visible: true, shown: .software, hardwareSelectable: true, fallback: false))
    }

    /// Three failed writes after DDC worked: the row stays, so Hardware can be tried again.
    func testMonitorThatLostDDCShowsSoftware() {
        XCTAssertEqual(row(ddcAvailable: false, ddcReachable: true),
                       .init(visible: true, shown: .software, hardwareSelectable: true, fallback: true))
    }

    /// Saved by a click on Software during a fallback: no longer a fallback.
    func testSavedChoiceIsNotAFallback() {
        XCTAssertFalse(row(choseSoftware: true, ddcAvailable: false, ddcReachable: true).fallback)
    }

    func testMonitorWithoutDDCGetsNoRow() {
        XCTAssertFalse(row(ddcAvailable: false).visible)
        XCTAssertFalse(row(ddcAvailable: nil).visible)
    }

    func testHDRShowsSoftwareAndLocksHardware() {
        XCTAssertEqual(row(hdr: true, ddcAvailable: true, ddcReachable: true),
                       .init(visible: true, shown: .software, hardwareSelectable: false, fallback: false))
    }
}
