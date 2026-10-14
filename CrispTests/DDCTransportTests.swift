import XCTest

final class DDCTransportTests: XCTestCase {
    private let null: [UInt8] = [0x6E, 0x80, 0xBE]

    private func reply(current: UInt16 = 60, maximum: UInt16 = 100, code: UInt8 = 0x10) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 2, 0, code, 0,
                              UInt8(maximum >> 8), UInt8(maximum & 255),
                              UInt8(current >> 8), UInt8(current & 255)]
        bytes.append(bytes.reduce(UInt8(0x50), ^))
        return bytes
    }

    private func select(_ standard: [UInt8]?, _ bridge: [UInt8]?) -> (UInt32, [UInt32]) {
        var reads: [UInt32] = []
        let address = DDCTransport.select { address in
            reads.append(address)
            return address == DDCTransport.standard ? standard : bridge
        }
        return (address.address, reads)
    }

    func testOrdinaryTransportDoesNotProbeBridge() {
        for ordinary in [reply(), nil, [0, 0, 0]] {
            let (address, reads) = select(ordinary, reply())
            XCTAssertEqual(address, 0x37)
            XCTAssertEqual(reads, [0x37])
        }
    }

    func testNullReplySelectsVerifiedBridge() {
        let (address, reads) = select(null, reply())
        XCTAssertEqual(address, 0xB7)
        XCTAssertEqual(reads, [0x37, 0xB7])
    }

    func testFailedNegotiationRemainsRetryable() {
        let failed = DDCTransport.select { $0 == 0x37 ? null : nil }
        XCTAssertEqual(failed.address, 0x37)
        XCTAssertFalse(failed.verified)
        let retry = DDCTransport.select { $0 == 0x37 ? null : reply() }
        XCTAssertEqual(retry.address, 0xB7)
        XCTAssertTrue(retry.verified)
    }

    func testInvalidBridgeNeverEnablesBridgeWrites() {
        var corrupt = reply()
        corrupt[10] ^= 1
        let invalid: [[UInt8]?] = [nil, null, Array(reply().prefix(5)), corrupt,
                                   reply(code: 0x12), reply(maximum: 0), reply(current: 101)]
        for response in invalid {
            let (address, reads) = select(null, response)
            XCTAssertEqual(address, 0x37)
            XCTAssertEqual(reads, [0x37, 0xB7])
        }
    }
}
