import Foundation

enum CrispVirtualDisplayIdentity {
    static let vendorID: UInt32 = 0xEEEE

    static func uuid(productID: UInt32, serialNumber: UInt32) -> String {
        String(
            format: "%08X-%04X-%04X-%04X-%04X00000000",
            vendorID, productID >> 16, productID & 0xFFFF,
            serialNumber >> 16, serialNumber & 0xFFFF
        )
    }

    static func canonicalUUID(_ value: String) -> String {
        guard let parsed = UUID(uuidString: value),
              parsed.uuidString.hasPrefix("0000EEEE-") else { return value }
        return String(parsed.uuidString.prefix(28)) + "00000000"
    }
}
