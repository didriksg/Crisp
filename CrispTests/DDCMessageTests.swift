import IOKit
import XCTest

/// Headless tests for repeating DDC/CI messages per monitor. `DDCMessage` compiles
/// directly into this test target, so no `@testable import Crisp` is needed.
final class DDCMessageTests: XCTestCase {
    private let dell: UInt32 = 0x10AC
    private let aw2725df: UInt32 = 0xA252
    private let aw3423dwf: UInt32 = 0xA212
    private let otherModel: UInt32 = 0x1234

    private func calls(model: UInt32, results: [IOReturn]) -> (calls: Int, result: IOReturn) {
        var calls = 0
        let result = DDCMessage.send(vendor: dell, model: model) {
            calls += 1
            return results[min(calls, results.count) - 1]
        }
        return (calls, result)
    }

    /// Both Alienwares act only on the second copy.
    func testAlienwaresGetTwoCopies() {
        for model in [aw2725df, aw3423dwf] {
            let sent = calls(model: model, results: [kIOReturnSuccess])
            XCTAssertEqual(sent.calls, 2)
            XCTAssertEqual(sent.result, kIOReturnSuccess)
        }
    }

    func testOtherMonitorGetsOneCopy() {
        XCTAssertEqual(calls(model: otherModel, results: [kIOReturnSuccess]).calls, 1)
    }

    /// Writes stop the Alienwares' DDC, so only input select reaches them.
    func testAlienwaresAllowOnlyInputSelect() {
        for model in [aw2725df, aw3423dwf] {
            XCTAssertTrue(DDCMessage.allows(vendor: dell, model: model, command: 0x60))
            XCTAssertFalse(DDCMessage.allows(vendor: dell, model: model, command: 0x10))
            XCTAssertFalse(DDCMessage.allows(vendor: dell, model: model, command: 0x62))
        }
        XCTAssertTrue(DDCMessage.allows(vendor: dell, model: otherModel, command: 0x10))
    }

    /// The Alienwares stopped answering doubled reads with the default shape.
    func testAlienwaresGetLongerReplyWaitAndExactLength() {
        let alienware = DDCMessage.replyShape(vendor: dell, model: aw3423dwf)
        XCTAssertEqual(alienware.wait, 0.05)
        XCTAssertEqual(alienware.length, 11)
        let other = DDCMessage.replyShape(vendor: dell, model: otherModel)
        XCTAssertEqual(other.wait, 0.04)
        XCTAssertEqual(other.length, 12)
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
