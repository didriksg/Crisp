import IOKit
import XCTest

/// Headless tests for repeating DDC/CI messages per monitor. `DDCMessage` compiles
/// directly into this test target, so no `@testable import Crisp` is needed.
final class DDCMessageTests: XCTestCase {
    private let dell: UInt32 = 0x10AC
    private let aw2725df: UInt32 = 0xA252
    private let aw3423dwf: UInt32 = 0xA212

    private func calls(model: UInt32, results: [IOReturn]) -> (calls: Int, result: IOReturn) {
        var calls = 0
        let result = DDCMessage.send(vendor: dell, model: model) {
            calls += 1
            return results[min(calls, results.count) - 1]
        }
        return (calls, result)
    }

    /// The AW2725DF acts only on the second copy.
    func testAW2725DFGetsTwoCopies() {
        let sent = calls(model: aw2725df, results: [kIOReturnSuccess])
        XCTAssertEqual(sent.calls, 2)
        XCTAssertEqual(sent.result, kIOReturnSuccess)
    }

    /// Repeats stop the AW3423DWF's DDC until a replug.
    func testAW3423DWFGetsOneCopy() {
        XCTAssertEqual(calls(model: aw3423dwf, results: [kIOReturnSuccess]).calls, 1)
    }

    /// Only the AW2725DF repeats, so only it skips the capabilities read.
    func testOnlyAW2725DFRepeats() {
        XCTAssertTrue(DDCMessage.repeats(vendor: dell, model: aw2725df))
        XCTAssertFalse(DDCMessage.repeats(vendor: dell, model: aw3423dwf))
    }

    /// A deaf channel can take seconds per call, so it gets only one.
    func testUnackedMessageIsSentOnce() {
        let sent = calls(model: aw2725df, results: [kIOReturnError])
        XCTAssertEqual(sent.calls, 1)
        XCTAssertEqual(sent.result, kIOReturnError)
    }

    /// The copy the monitor acts on decides the result.
    func testFailedSecondCopyIsReported() {
        XCTAssertEqual(calls(model: aw2725df, results: [kIOReturnSuccess, kIOReturnError]).result, kIOReturnError)
    }
}
