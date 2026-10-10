import XCTest

final class HiDPIOverrideCommandTests: XCTestCase {
    func testPayloadRoundTripsWithoutAUserTemporaryFile() throws {
        let modes = [Data([0, 0, 15, 0, 0, 0, 8, 112]), Data(repeating: 0, count: 8)]
        let command = try HiDPIOverrideCommand.install(vendor: 0x610, product: 0xabcd, scaledModes: modes)
        let encoded = try XCTUnwrap(command.components(separatedBy: "/usr/bin/printf '%s' '").last?
            .components(separatedBy: "'").first)
        let payload = try XCTUnwrap(Data(base64Encoded: encoded))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: [Data]])
        XCTAssertEqual(plist, ["scale-resolutions": modes])
        XCTAssertTrue(command.contains("DisplayVendorID-610/DisplayProductID-abcd"))
        XCTAssertFalse(command.contains("crisp_hidpi_override.plist"))
        XCTAssertFalse(command.contains(NSTemporaryDirectory()))
        XCTAssertFalse(command.contains("/bin/cp"))
    }

    func testRejectsEmptyOversizedAndMalformedModes() {
        for modes in [[Data](), [Data(repeating: 0, count: 7)], [Data(repeating: 0, count: 9)],
                      Array(repeating: Data(repeating: 0, count: 8), count: 4_097)] {
            XCTAssertThrowsError(try HiDPIOverrideCommand.install(vendor: 1, product: 2, scaledModes: modes))
        }
    }

    func testIdentifiersAreNumericAndCannotSupplyPaths() throws {
        let command = try HiDPIOverrideCommand.install(
            vendor: UInt32.max, product: 0, scaledModes: [Data(repeating: 0, count: 8)])
        XCTAssertTrue(command.contains("DisplayVendorID-ffffffff/DisplayProductID-0"))
    }

    func testAppleScriptLiteralPreservesShellQuotesAndBackslashes() {
        XCTAssertEqual(HiDPIOverrideCommand.appleScriptLiteral("echo \"$stage\" \\"), "echo \\\"$stage\\\" \\\\")
    }

    /// Parse only: never execute the generated installer or request administrator access.
    func testGeneratedShellSyntax() throws {
        let command = try HiDPIOverrideCommand.install(vendor: 1, product: 2, scaledModes: [Data(repeating: 0, count: 8)])
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(command.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
