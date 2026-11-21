import Foundation

/// Input select over DDC (VCP 0x60, #196): the inputs a monitor lists in its
/// capabilities string, their MCCS names, and the text a person types for one.
/// Measured behaviour (bad reply rate, what macOS does while the monitor shows
/// another source) is in docs/ddc-notes.md (input switching).
enum DDCInputSource {
    static let vcp: UInt8 = 0x60

    /// Offered when the monitor lists no inputs of its own: DisplayPort 1 and 2,
    /// HDMI 1 and 2, and USB-C (0x1B, outside MCCS but what most monitors use).
    static let standard: [UInt16] = [0x0F, 0x10, 0x11, 0x12, 0x1B]

    private static let names: [UInt16: String] = [
        0x01: "VGA 1", 0x02: "VGA 2", 0x03: "DVI 1", 0x04: "DVI 2",
        0x0F: "DisplayPort 1", 0x10: "DisplayPort 2",
        0x11: "HDMI 1", 0x12: "HDMI 2", 0x1B: "USB-C",
        0xF4D0: "DisplayPort 1 (LG)", 0xF4D1: "DisplayPort 2 / USB-C (LG)", 0xF4D2: "USB-C (LG)",
        0xF490: "HDMI 1 (LG)", 0xF491: "HDMI 2 (LG)"
    ]

    // MARK: - LG alternate input channel

    /// Many LG monitors ack a VCP 0x60 input write and ignore it: they switch only on
    /// LG's side channel, VCP 0xF4 sent from source address 0x50 instead of 0x51, with
    /// codes of their own (docs/ddc-notes.md, LG alternate input channel). Crisp keeps
    /// one value per input, so an LG code travels as 0xF400 plus the code: a 0x60 value
    /// is one byte, so the two never collide, and the high byte names the channel.
    static let lgVCP: UInt8 = 0xF4
    static let lgSourceAddress: UInt8 = 0x50
    private static let lgFlag: UInt16 = 0xF400

    /// EDID manufacturer ID of LG Electronics ("GSM"), from CGDisplayVendorNumber.
    static let lgVendor: UInt32 = 0x1E6D

    /// The LG codes offered next to the monitor's own list on an LG display. The USB-C
    /// code differs by model and firmware (0xD1 on some, 0xD2 on others), so both stay.
    static let lg: [UInt16] = [0xF490, 0xF491, 0xF4D0, 0xF4D1, 0xF4D2]

    /// Whether a value is an LG side-channel code rather than a VCP 0x60 value.
    static func isLG(_ value: UInt16) -> Bool { value & 0xFF00 == lgFlag }

    /// The VCP code, value and source address that write an input: VCP 0x60 from 0x51,
    /// or for an LG code, VCP 0xF4 from 0x50 with the code in the low byte.
    static func message(for value: UInt16) -> (command: UInt8, value: UInt16, sourceAddress: UInt8) {
        isLG(value) ? (lgVCP, value & 0xFF, lgSourceAddress) : (vcp, value, 0x51)
    }

    /// The connector name for a value, or nil for one without a common name. The
    /// names are connector trademarks, the same in every language.
    static func name(for value: UInt16) -> String? { names[value] }

    /// The value a monitor reports for its current input. MCCS puts it in the low
    /// byte; some monitors set flags in the high byte.
    static func current(fromReply value: UInt16) -> UInt16 { value & 0xFF }

    /// The values in the `60(...)` entry of a capabilities string's `vcp(...)` list,
    /// in the monitor's order, or nil when the string has no such entry.
    /// Tolerates what real strings do: spaces inside the parentheses, codes run
    /// together without spaces, lower-case hex, and odd tokens like `E2A020(000204)`.
    static func values(inCapabilities capabilities: String) -> [UInt16]? {
        let chars = Array(capabilities.uppercased())
        guard let start = vcpListStart(in: chars) else { return nil }
        var depth = 1
        var token = ""
        var index = start
        while index < chars.count, depth > 0 {
            let char = chars[index]
            index += 1
            switch char {
            case "(":
                let code = String(token.suffix(2))
                token = ""
                // The value list runs to the matching parenthesis.
                var inner = ""
                var level = 1
                while index < chars.count {
                    let next = chars[index]
                    index += 1
                    if next == "(" { level += 1 } else if next == ")" {
                        level -= 1
                        if level == 0 { break }
                    }
                    inner.append(next)
                }
                if code == "60" { return hexValues(inner) }
            case ")":
                depth -= 1
            case " ", "\t", "\n", "\r":
                token = ""
            default:
                token.append(char)
            }
        }
        return nil
    }

    /// Index just past `vcp(`, skipping names that only end in "vcp" (`vcpname(`
    /// starts the same way, but a longer word before it is not the list).
    private static func vcpListStart(in chars: [Character]) -> Int? {
        let marker: [Character] = ["V", "C", "P", "("]
        guard chars.count >= marker.count else { return nil }
        for index in 0...(chars.count - marker.count) where Array(chars[index..<index + marker.count]) == marker {
            if index > 0, chars[index - 1].isLetter { continue }
            return index + marker.count
        }
        return nil
    }

    /// Two-digit hex values, split on spaces and on every second digit of a run.
    private static func hexValues(_ text: String) -> [UInt16] {
        var values: [UInt16] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            let digits = Array(word)
            guard digits.count.isMultiple(of: 2) else { continue }
            for pair in stride(from: 0, to: digits.count, by: 2) {
                if let value = UInt16(String(digits[pair...pair + 1]), radix: 16), value != 0,
                   !values.contains(value) {
                    values.append(value)
                }
            }
        }
        return values
    }

    /// The value for what a person typed: a connector name in any case and spacing
    /// ("HDMI 1", "hdmi1", "dp2", "usb-c"), an LG side-channel name ("lg-usbc",
    /// "lg-hdmi1"), a decimal number ("17", as m1ddc takes it) or a hex number ("0x11",
    /// or "0xF4D2" for an LG code). nil for anything else or for 0.
    static func value(from text: String) -> UInt16? {
        let compact = text.lowercased().filter { !" -_".contains($0) }
        if let named = aliases[compact] { return named }
        let parsed = compact.hasPrefix("0x") ? UInt16(compact.dropFirst(2), radix: 16) : UInt16(compact)
        guard let parsed, parsed != 0 else { return nil }
        return parsed
    }

    private static let aliases: [String: UInt16] = {
        var aliases: [String: UInt16] = [
            "dp1": 0x0F, "dp2": 0x10,
            "lghdmi1": 0xF490, "lghdmi2": 0xF491, "lgdp1": 0xF4D0, "lgdp2": 0xF4D1, "lgusbc": 0xF4D2
        ]
        for (value, name) in names { aliases[name.lowercased().filter { !" -".contains($0) }] = value }
        return aliases
    }()
}

/// A Set VCP Feature message (DDC/CI 1.1): the bytes after the source address,
/// checksum included. The checksum starts from the 0x6E destination XOR the source
/// address, which is 0x51 for every message except LG's input side channel (0x50).
enum DDCSetVCP {
    static func bytes(command: UInt8, value: UInt16, sourceAddress: UInt8 = 0x51) -> [UInt8] {
        let payload: [UInt8] = [0x84, 0x03, command, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return payload + [payload.reduce(UInt8(0x6E) ^ sourceAddress, ^)]
    }
}

/// The capabilities string travels in chunks: a request names an offset, the reply
/// carries up to 32 bytes from there, and an empty reply ends the string (DDC/CI 1.1,
/// Capabilities Request 0xF3 and Reply 0xE3).
enum DDCCapabilities {
    /// The request bytes after the 0x51 sub-address, checksum included.
    static func request(offset: Int) -> [UInt8] {
        let payload: [UInt8] = [0x83, 0xF3, UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF)]
        return payload + [payload.reduce(UInt8(0x6E ^ 0x51), ^)]
    }

    /// Bytes to read for one reply: header, offset, 32 data bytes and the checksum.
    static let replyLength = 38

    /// The data in one reply, empty at the end of the string, or nil for a reply that
    /// fails the header, the offset echo, the length or the checksum.
    static func data(fromReply reply: [UInt8], offset: Int) -> [UInt8]? {
        guard reply.count >= 6, reply[0] == 0x6E, reply[2] == 0xE3 else { return nil }
        let length = Int(reply[1] & 0x7F)
        guard length >= 3, length <= 35, reply.count > length + 2,
              Int(reply[3]) << 8 | Int(reply[4]) == offset else { return nil }
        let checksum = reply[0..<(length + 2)].reduce(UInt8(0x50), ^)
        guard checksum == reply[length + 2] else { return nil }
        return Array(reply[5..<(length + 2)])
    }
}
