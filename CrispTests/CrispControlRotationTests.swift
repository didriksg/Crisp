import XCTest

/// crispctl's rotation commands (#258): which displays they reach, and which they refuse.
final class CrispControlRotationTests: XCTestCase {
    private let display = CrispControlDisplay(
        id: 7, name: "Q27G3XMN", brightness: 56, isBuiltin: false, uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    )

    private func handle(_ request: String, displays: [CrispControlDisplay]? = nil) -> CrispControlResult {
        CrispControlModel.handle(Data(request.utf8), displays: displays ?? [display], rotation: { $0 == 7 ? 90 : nil })
    }

    func testRotationIsReadAndOnlyAnotherRotationIsAChange() {
        XCTAssertEqual(handle(#"{"command":"getRotation","selector":"7"}"#).response.rotation, .init(displayID: 7, degrees: 90))
        XCTAssertEqual(handle(#"{"command":"setRotation","selector":"7","rotation":180}"#).rotationChange,
                       .init(displayID: 7, degrees: 180))
        let same = handle(#"{"command":"setRotation","selector":"7","rotation":90}"#)
        XCTAssertTrue(same.response.ok)
        XCTAssertNil(same.rotationChange)
    }

    func testRotationRefusesWhatThePanelHasNoRowFor() {
        let builtin = CrispControlDisplay(id: 1, name: "Built-in", brightness: 50, isBuiltin: true, uuid: "B")
        let virtual = CrispControlDisplay(id: 8, name: "Virtual", brightness: 50, isBuiltin: false, uuid: "V")
        let held = CrispControlDisplay(id: 9, name: "M32UC", brightness: 0, isBuiltin: false, uuid: "H", connected: false)
        let cases: [(String, String)] = [
            (#"{"command":"setRotation","selector":"1","rotation":90}"#, "rotation is not available for the built-in display"),
            (#"{"command":"getRotation","selector":"8"}"#, "rotation is not available for this display"),
            (#"{"command":"getRotation","selector":"9"}"#, "display is not connected"),
            (#"{"command":"setRotation","selector":"7","rotation":45}"#, "rotation must be 0, 90, 180 or 270"),
            (#"{"command":"getRotation"}"#, "display is required")
        ]
        for (request, error) in cases {
            let result = handle(request, displays: [display, builtin, virtual, held])
            XCTAssertEqual(result.response.error, error, request)
            XCTAssertNil(result.rotationChange, request)
        }
    }

    func testParserTakesOnlyTheFourRotations() {
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "rotation", "set", "7", "270"]),
                       .request(.init(command: .setRotation, selector: "7", rotation: 270)))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "rotation", "set", "7", "45"]),
                       .failure("usage: crispctl display rotation set <display> 0|90|180|270"))
    }
}
