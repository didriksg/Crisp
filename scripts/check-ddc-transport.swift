// swiftc -parse-as-library Crisp/Models/DDCTransport.swift scripts/check-ddc-transport.swift \
//   -o /tmp/crisp-ddc-transport-checks && /tmp/crisp-ddc-transport-checks
import Foundation

@main
struct DDCTransportChecks {
    static func main() {
        var valid: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3C]
        valid.append(valid.reduce(UInt8(0x50), ^))
        let null: [UInt8] = [0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE]
        func check(_ standard: [UInt8]?, _ bridge: [UInt8]?, expected: UInt32, reads: Int) {
            var seen: [UInt32] = []
            let result = DDCTransport.select { address in
                seen.append(address)
                return address == 0x37 ? standard : bridge
            }
            precondition(result.address == expected && seen.count == reads)
            precondition(seen.first == 0x37)
        }
        check(valid, nil, expected: 0x37, reads: 1)
        check(nil, valid, expected: 0x37, reads: 1)
        check([0, 0, 0], valid, expected: 0x37, reads: 1)
        check(null, valid, expected: 0xB7, reads: 2)
        check(null, null, expected: 0x37, reads: 2)
        check(null, Array(valid.prefix(5)), expected: 0x37, reads: 2)
        var corrupt = valid; corrupt[10] ^= 1
        check(null, corrupt, expected: 0x37, reads: 2)
        var wrongCode = valid; wrongCode[4] = 0x12; wrongCode[10] ^= 0x02
        check(null, wrongCode, expected: 0x37, reads: 2)
        var zeroMax = valid; zeroMax[7] = 0; zeroMax[10] ^= 0x64
        check(null, zeroMax, expected: 0x37, reads: 2)
        let failed = DDCTransport.select { $0 == 0x37 ? null : nil }
        precondition(failed.address == 0x37 && !failed.verified)
        let retried = DDCTransport.select { $0 == 0x37 ? null : valid }
        precondition(retried.address == 0xB7 && retried.verified)
        print("PASS: normal transport, bounded null-reply fallback, valid bridge, failed/short/corrupt/wrong-command/zero-max replies")
    }
}
