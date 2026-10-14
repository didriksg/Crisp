/// IOAVService uses bit 7 of the chip address to select the HDMI bridge path.
/// Probe it only after a DDC NULL reply, and require a valid brightness reply
/// before using it for writes. An I2C acknowledgement alone is not sufficient.
enum DDCTransport {
    static let standard: UInt32 = 0x37
    static let hdmiBridge: UInt32 = 0xB7

    struct Selection {
        let address: UInt32
        let verified: Bool
    }

    static func select(readBrightness: (UInt32) -> [UInt8]?) -> Selection {
        guard let reply = readBrightness(standard) else {
            return Selection(address: standard, verified: false)
        }
        if validBrightnessReply(reply) { return Selection(address: standard, verified: true) }
        guard reply.starts(with: [0x6E, 0x80, 0xBE]),
              let bridged = readBrightness(hdmiBridge), validBrightnessReply(bridged) else {
            return Selection(address: standard, verified: false)
        }
        return Selection(address: hdmiBridge, verified: true)
    }

    private static func validBrightnessReply(_ reply: [UInt8]) -> Bool {
        guard reply.count >= 11,
              reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
              reply[3] == 0, reply[4] == 0x10,
              reply.prefix(10).reduce(UInt8(0x50), ^) == reply[10] else { return false }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return maximum > 0 && current <= maximum
    }
}
