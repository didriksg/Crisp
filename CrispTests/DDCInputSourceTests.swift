import XCTest

/// Headless tests for input select (#196): the capabilities parser, the text a person
/// types for an input, and the capabilities chunk framing.
final class DDCInputSourceTests: XCTestCase {

    /// The full string an AOC Q27G3XMN sent over DisplayPort (2026-10-05). Its ports
    /// are HDMI 1, HDMI 2 and DisplayPort 1, in that order, after a space inside `60(`.
    private let aocCapabilities = "(prot(monitor)type(lcd)model(Q27G3XMN)cmds(01 02 03 07 0C E3 F3)"
        + "vcp(02 04 05 08 10 12 14(01 05 06 08 0B) 16 18 1A 52 60( 11 12 0F) 62 8D(01 02) AC AE B6 C0 "
        + "C6 C8 C9 CA(01 02) CC(02 03 04 05 07 08 09 0A 0D 01 06 0B 12 14 16 1E) "
        + "86(01 02 05 0B 0C 0F 10 11) D6(01 05) DC(00 0B 0C 0D 0E 0F 10) DF E2A020(000204)"
        + "E2A018(0001020304)FF)mswhql(1)asset_eep(40)mccs_ver(2.2))"

    func testRealMonitorStringListsItsPorts() {
        XCTAssertEqual(DDCInputSource.values(inCapabilities: aocCapabilities), [0x11, 0x12, 0x0F])
    }

    /// Strings in the field run codes together, use lower case, and nest other lists
    /// before the input entry.
    func testRunTogetherAndLowerCaseEntries() {
        let caps = "(vcp(02 04 14(05 08 0b) 1a5260(0f1011 1b) aa(01 02)))"
        XCTAssertEqual(DDCInputSource.values(inCapabilities: caps), [0x0F, 0x10, 0x11, 0x1B])
    }

    /// No input entry means the standard list applies, and a `vcpname(...)` list that
    /// names code 60 is not the vcp list.
    func testMissingEntryIsNil() {
        XCTAssertNil(DDCInputSource.values(inCapabilities: "(vcp(02 10 12 62)vcpname(60(Input)))"))
        XCTAssertNil(DDCInputSource.values(inCapabilities: "(prot(monitor)type(lcd))"))
        XCTAssertNil(DDCInputSource.values(inCapabilities: ""))
    }

    func testTypedInputs() {
        let cases: [(String, UInt16?)] = [
            ("HDMI 1", 0x11), ("hdmi2", 0x12), ("DisplayPort 1", 0x0F), ("dp2", 0x10),
            ("usb-c", 0x1B), ("USBC", 0x1B), ("17", 17), ("0x11", 0x11), ("0XD0", 0xD0),
            ("0", nil), ("0x", nil), ("hdmi 9", nil), ("70000", nil), ("", nil)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(DDCInputSource.value(from: text), expected, text)
        }
    }

    /// The input is in the low byte; a monitor that sets the high byte still matches.
    func testCurrentInputIgnoresHighByte() {
        XCTAssertEqual(DDCInputSource.current(fromReply: 0x010F), 0x0F)
    }

    func testCapabilitiesRequestBytes() {
        XCTAssertEqual(DDCCapabilities.request(offset: 0x20), [0x83, 0xF3, 0x00, 0x20, 0x6F])
    }

    func testCapabilitiesReplyFraming() {
        let reply: [UInt8] = [0x6E, 0x85, 0xE3, 0x00, 0x00, 0x61, 0x62, 0x5B]
        XCTAssertEqual(DDCCapabilities.data(fromReply: reply, offset: 0), [0x61, 0x62])
        // A reply for another offset, or with a wrong checksum, is a bad read to retry.
        XCTAssertNil(DDCCapabilities.data(fromReply: reply, offset: 2))
        XCTAssertNil(DDCCapabilities.data(fromReply: [0x6E, 0x85, 0xE3, 0x00, 0x00, 0x61, 0x62, 0x5C], offset: 0))
        // An empty reply is the end of the string.
        XCTAssertEqual(DDCCapabilities.data(fromReply: [0x6E, 0x83, 0xE3, 0x00, 0x02, 0x5C], offset: 2), [])
    }

    // MARK: - LG alternate input channel

    /// The standard message keeps its bytes: checksum from 0x6E ^ 0x51 over the payload.
    func testSetVCPBytesFromStandardSource() {
        XCTAssertEqual(DDCSetVCP.bytes(command: 0x10, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        XCTAssertEqual(DDCSetVCP.bytes(command: 0x60, value: 0x11), [0x84, 0x03, 0x60, 0x00, 0x11, 0xC9])
    }

    /// LG's side channel: VCP 0xF4 with the code in the low byte, checksum from 0x6E ^ 0x50.
    func testSetVCPBytesForLGSideChannel() {
        XCTAssertEqual(DDCSetVCP.bytes(command: 0xF4, value: 0xD2, sourceAddress: 0x50), [0x84, 0x03, 0xF4, 0x00, 0xD2, 0x9F])
        XCTAssertEqual(DDCSetVCP.bytes(command: 0xF4, value: 0x90, sourceAddress: 0x50), [0x84, 0x03, 0xF4, 0x00, 0x90, 0xDD])
    }

    /// Intel sends the source address as the packet's first byte (DDCService.intelWriteSynchronous),
    /// so the checksum must equal 0x6E XOR every byte before it, the source address included.
    func testIntelPacketChecksumCoversSourceAddress() {
        for (source, command): (UInt8, UInt8) in [(0x51, 0x60), (0x50, 0xF4)] {
            let packet = [source] + DDCSetVCP.bytes(command: command, value: 0x90, sourceAddress: source)
            XCTAssertEqual(packet.dropLast().reduce(UInt8(0x6E), ^), packet.last, String(format: "source 0x%02X", source))
        }
        let lgHDMI1 = [0x50] + DDCSetVCP.bytes(command: 0xF4, value: 0x90, sourceAddress: 0x50)
        XCTAssertEqual(lgHDMI1, [0x50, 0x84, 0x03, 0xF4, 0x00, 0x90, 0xDD])
    }

    /// An input write picks its channel from the value.
    func testInputMessageChannel() {
        let standard = DDCInputSource.message(for: 0x11)
        XCTAssertEqual([standard.command, UInt8(standard.value), standard.sourceAddress], [0x60, 0x11, 0x51])
        let lg = DDCInputSource.message(for: 0xF4D2)
        XCTAssertEqual(lg.value, 0xD2)
        XCTAssertEqual([lg.command, lg.sourceAddress], [0xF4, 0x50])
    }

    /// LG codes carry 0xF4 in the high byte; a VCP 0x60 value never does.
    func testLGValuesAreFlagged() {
        for value in DDCInputSource.lg { XCTAssertTrue(DDCInputSource.isLG(value), String(format: "0x%04X", value)) }
        for value in DDCInputSource.standard + [0xD2, 0x90, 0x00FF] {
            XCTAssertFalse(DDCInputSource.isLG(value), String(format: "0x%04X", value))
        }
    }

    func testLGInputNamesAndTypedForms() {
        XCTAssertEqual(DDCInputSource.name(for: 0xF4D2), "USB-C (LG)")
        XCTAssertEqual(DDCInputSource.name(for: 0xF490), "HDMI 1 (LG)")
        let cases: [(String, UInt16?)] = [
            ("lg-usbc", 0xF4D2), ("LG USB-C", 0xF4D2), ("lg-hdmi1", 0xF490), ("lg_hdmi2", 0xF491),
            ("lg-dp1", 0xF4D0), ("lg-dp2", 0xF4D1), ("0xF4D1", 0xF4D1),
            ("lg-displayport1", 0xF4D0), ("LG DisplayPort 2", 0xF4D1),
            // An LG code needs a code: 0xF400 alone is not an input.
            ("0xF400", nil), ("62464", nil),
            // The names crispctl prints go back in as they are.
            ("USB-C (LG)", 0xF4D2), ("HDMI 1 (LG)", 0xF490), ("DisplayPort 2 / USB-C (LG)", 0xF4D1),
            // The plain names still mean the standard VCP 0x60 inputs.
            ("usb-c", 0x1B), ("hdmi1", 0x11)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(DDCInputSource.value(from: text), expected, text)
        }
    }
}
