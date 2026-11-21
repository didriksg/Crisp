import XCTest

final class CrispVirtualDisplayIdentityTests: XCTestCase {
    func testIdentityUsesTheDescriptorsProductAndSerial() {
        XCTAssertEqual(
            CrispVirtualDisplayIdentity.uuid(productID: 0x11223344, serialNumber: 0x55667788),
            "0000EEEE-1122-3344-5566-778800000000"
        )
    }

    func testRecreatedVirtualDisplayMatchesItsSavedPreset() {
        let savedUUID = "0000EEEE-1122-3344-5566-7788003F0041"
        let entry = DisplayPresetEntry(displayUUID: savedUUID)
        XCTAssertTrue(entry.matchesDisplay(uuid: "0000EEEE-1122-3344-5566-778800400042"))
        XCTAssertTrue(entry.matchesDisplay(uuid: "0000eeee-1122-3344-5566-778800000000"))
        XCTAssertEqual(entry.displayUUID, savedUUID)
    }

    func testDifferentVirtualDisplaysDoNotMatch() {
        let entry = DisplayPresetEntry(displayUUID: "0000EEEE-1122-3344-5566-7788003F0041")
        XCTAssertFalse(entry.matchesDisplay(uuid: "0000EEEE-1122-3345-5566-7788003F0041"))
        XCTAssertFalse(entry.matchesDisplay(uuid: "0000EEEE-1122-3344-5566-7789003F0041"))
    }

    func testOtherVendorsAndMalformedIDsRemainUnchanged() {
        for value in ["00001234-1122-3344-5566-7788003F0041", "0000EEEE-not-a-uuid", "BUILTIN"] {
            XCTAssertEqual(CrispVirtualDisplayIdentity.canonicalUUID(value), value)
        }
    }

    func testSavingDoesNotRewriteLegacyUUIDs() throws {
        let savedUUID = "0000EEEE-1122-3344-5566-7788003F0041"
        let entry = DisplayPresetEntry(displayUUID: savedUUID, connected: true)
        let decoded = try JSONDecoder().decode(DisplayPresetEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.displayUUID, savedUUID)
        XCTAssertTrue(decoded.matchesDisplay(uuid: "0000EEEE-1122-3344-5566-778800000000"))
    }
}
