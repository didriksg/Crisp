import XCTest

/// Headless tests for the speaker volume maximum taken from a VCP 0x62 reply.
///
/// `DDCVolumeMax` is compiled directly into this test target (see `project.yml`
/// sources), so no `@testable import Crisp` is needed.
final class DDCVolumeMaxTests: XCTestCase {

    /// The Dell S2725DSM replies 0xFF64 for a range of 0 to 100 (#162).
    func testFilledHighByteIsIgnored() {
        XCTAssertEqual(DDCVolumeMax.from(0xFF64), 100)
    }

    /// A plain reply is kept as it is, whatever range the monitor has.
    func testPlainMaximumIsKept() {
        XCTAssertEqual(DDCVolumeMax.from(100), 100)
        XCTAssertEqual(DDCVolumeMax.from(30), 30)
    }

    /// A low byte of 0 would scale every write to 0, which is mute.
    func testZeroLowByteFallsBackToOneHundred() {
        XCTAssertEqual(DDCVolumeMax.from(0xFF00), 100)
    }
}
