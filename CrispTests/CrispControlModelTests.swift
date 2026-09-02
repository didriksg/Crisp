import XCTest

final class CrispControlModelTests: XCTestCase {
    private let display = CrispControlDisplay(
        id: 7,
        name: "Studio Display",
        brightness: 64,
        isBuiltin: false,
        uuid: "11111111-2222-3333-4444-555555555555"
    )
    /// Crisp is holding this one out of the layout: absent from the online list,
    /// so its id is only a last-known value and the uuid is the real handle.
    private let offline = CrispControlDisplay(
        id: 9,
        name: "M32UC",
        brightness: 0,
        isBuiltin: false,
        uuid: "DECC7CEF-5E36-4E9B-8F18-CE11AE5902AD",
        connected: false
    )

    func testParserSupportsEveryCommand() {
        let cases: [([String], CrispControlRequest)] = [
            (["displays", "list"], .init(command: .list)),
            (["brightness", "get", "42"], .init(command: .getBrightness, display: 42)),
            (
                ["brightness", "set", "42", "37.5"],
                .init(command: .setBrightness, display: 42, brightness: 37.5)
            ),
            (["display", "connect", "42"], .init(command: .connectDisplay, selector: "42")),
            (
                ["display", "disconnect", "DECC7CEF-5E36-4E9B-8F18-CE11AE5902AD"],
                .init(command: .disconnectDisplay, selector: "DECC7CEF-5E36-4E9B-8F18-CE11AE5902AD")
            ),
            (["display", "toggle", "42"], .init(command: .toggleDisplay, selector: "42"))
        ]
        for (arguments, request) in cases {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .request(request))
        }
    }

    func testParserReturnsHelpForNoArgumentsAndHelpFlags() {
        for arguments in [[], ["help"], ["--help"], ["-h"]] {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .help, "\(arguments)")
        }
        // The reference must name every command it documents, and the usage line must
        // point at it, so a wrong invocation still leads to the full text.
        for command in [
            "displays list", "brightness get", "brightness set",
            "display connect", "display disconnect", "display toggle", "crispctl help"
        ] {
            XCTAssertTrue(CrispControlCLIModel.help.contains(command), command)
        }
        XCTAssertTrue(CrispControlCLIModel.usage.contains("crispctl help"))
    }

    func testParserRejectsInvalidArityIDsOptionsAndPercent() {
        let cases = [
            ["help", "me"], ["displays"], ["displays", "list", "--json"],
            ["brightness", "get"], ["brightness", "get", "x"],
            ["brightness", "get", "4294967296"], ["brightness", "set", "42"],
            ["brightness", "set", "42", "nan"], ["brightness", "set", "42", "inf"],
            ["brightness", "set", "42", "-0.1"], ["brightness", "set", "42", "100.1"],
            ["display", "toggle"], ["display", "toggle", ""], ["display", "reboot", "42"],
            ["display", "toggle", "42", "now"]
        ]
        for arguments in cases {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .failure)
        }
        for value in ["0", "100"] {
            guard case let .request(request) = CrispControlCLIModel.parse(
                arguments: ["brightness", "set", "42", value]
            ) else { return XCTFail("expected boundary \(value)") }
            XCTAssertEqual(request.brightness, Double(value))
        }
    }

    func testSharedFrameReturnsOneBoundedLFFrame() {
        let frame = Data(#"{"command":"list"}"#.utf8) + Data([0x0A])
        XCTAssertEqual(
            CrispControlFrame.parse(frame + Data("ignored".utf8), maximumBytes: 64, endOfStream: false),
            .frame(frame)
        )
        XCTAssertEqual(
            CrispControlFrame.parse(Data(frame.dropLast()), maximumBytes: 64, endOfStream: false),
            .incomplete
        )
        XCTAssertEqual(
            CrispControlFrame.parse(Data(frame.dropLast()), maximumBytes: 64, endOfStream: true),
            .failure("frame must end with newline")
        )
        XCTAssertEqual(
            CrispControlFrame.parse(Data(repeating: 0x20, count: 4), maximumBytes: 4, endOfStream: false),
            .failure("frame too large")
        )
    }

    func testModelHandlesListAndGet() throws {
        let list = CrispControlModel.handle(Data(#"{"command":"list"}"#.utf8), displays: [display])
        XCTAssertEqual(list.response, .success(displays: [display]))
        XCTAssertNil(list.brightnessChange)

        let get = CrispControlModel.handle(
            Data(#"{"command":"getBrightness","display":7}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(get.response, .success(display: display))
        XCTAssertNil(get.brightnessChange)
    }

    func testSetEncodesOnlyOKAndCreatesRequestedBrightnessChange() {
        let result = CrispControlModel.handle(
            Data(#"{"command":"setBrightness","display":7,"brightness":35}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(result.response, .success())
        XCTAssertEqual(result.brightnessChange, .init(displayID: 7, brightness: 35))
        XCTAssertEqual(
            CrispControlModel.encode(result.response),
            Data(#"{"ok":true}"#.utf8) + Data([0x0A])
        )
    }

    func testModelRejectsMalformedMissingUnknownAndOutOfRangeRequests() {
        let requests = [
            #"{"command":"list""#,
            #"{"command":"getBrightness"}"#,
            #"{"command":"getBrightness","display":8}"#,
            #"{"command":"setBrightness","display":7}"#,
            #"{"command":"setBrightness","display":7,"brightness":101}"#,
            #"{"command":"unknown"}"#
        ]
        for request in requests {
            let result = CrispControlModel.handle(Data(request.utf8), displays: [display])
            XCTAssertFalse(result.response.ok, request)
            XCTAssertNil(result.brightnessChange, request)
        }
    }

    func testBareSuccessIsAcceptedForEveryCommand() {
        for command in commands {
            XCTAssertEqual(classify(#"{"ok":true}"#, command), .success)
        }
    }

    func testSuccessfulResponseWithUnknownFutureFieldIsAcceptedForEveryCommand() {
        let response = #"{"ok":true,"future":{"state":"applied"}}"#
        for command in commands {
            XCTAssertEqual(classify(response, command), .success)
        }
    }

    func testFailedMalformedAndInsufficientResponseClassification() {
        for command in commands {
            XCTAssertEqual(classify(#"{"ok":false,"error":"display not found"}"#, command), .serverFailure)
            XCTAssertEqual(
                classify(#"{"ok":false,"error":"display not found","future":true}"#, command),
                .serverFailure
            )
            XCTAssertEqual(classify(#"{"ok":false}"#, command), .invalid)
            XCTAssertEqual(classify(#"{}"#, command), .invalid)
            XCTAssertEqual(classify(#"{"ok":true"#, command), .invalid)
        }
    }

    private var commands: [CrispControlRequest.Command] {
        [.list, .getBrightness, .setBrightness, .connectDisplay, .disconnectDisplay, .toggleDisplay]
    }

    func testConnectionCommandsResolveByIDAndByUUID() {
        let displays = [display, offline]
        // Toggling a connected display asks for a disconnect...
        let byID = CrispControlModel.handle(
            Data(#"{"command":"toggleDisplay","selector":"7"}"#.utf8), displays: displays
        )
        XCTAssertEqual(byID.connectionChange, .init(uuid: display.uuid, connect: false))
        // ...and toggling a disconnected one asks for the opposite, found by uuid
        // in any case, which is the only handle that survives the disconnect.
        let byUUID = CrispControlModel.handle(
            Data(#"{"command":"toggleDisplay","selector":"decc7cef-5e36-4e9b-8f18-ce11ae5902ad"}"#.utf8),
            displays: displays
        )
        XCTAssertEqual(byUUID.connectionChange, .init(uuid: offline.uuid, connect: true))
        XCTAssertNil(byID.brightnessChange)
    }

    func testAskingForTheStateADisplayIsAlreadyInSucceedsAndChangesNothing() {
        // A button wired to connect or disconnect must be safe to press twice.
        for (request, subject) in [
            (#"{"command":"connectDisplay","selector":"7"}"#, display),
            (#"{"command":"disconnectDisplay","selector":"9"}"#, offline)
        ] {
            let result = CrispControlModel.handle(Data(request.utf8), displays: [display, offline])
            XCTAssertTrue(result.response.ok, request)
            XCTAssertNil(result.connectionChange, request)
            XCTAssertEqual(result.response.display?.uuid, subject.uuid, request)
        }
    }

    func testConnectionResponseReportsTheSettledState() {
        let result = CrispControlModel.handle(
            Data(#"{"command":"disconnectDisplay","selector":"7"}"#.utf8), displays: [display, offline]
        )
        XCTAssertEqual(result.response.display?.connected, false)
        XCTAssertEqual(result.response.display?.id, display.id)
        XCTAssertEqual(result.connectionChange, .init(uuid: display.uuid, connect: false))
    }

    func testConnectionCommandsRejectMissingUnknownAndUnidentifiableDisplays() {
        let anonymous = CrispControlDisplay(id: 3, name: "No UUID", brightness: 10, isBuiltin: false)
        let cases: [(String, [CrispControlDisplay])] = [
            (#"{"command":"toggleDisplay"}"#, [display]),
            (#"{"command":"toggleDisplay","selector":""}"#, [display]),
            (#"{"command":"toggleDisplay","selector":"404"}"#, [display]),
            (#"{"command":"connectDisplay","selector":"nope"}"#, [display]),
            // A display with no stable uuid cannot be found again once it is gone,
            // so refuse rather than hand back a handle that will not work.
            (#"{"command":"disconnectDisplay","selector":"3"}"#, [anonymous])
        ]
        for (request, displays) in cases {
            let result = CrispControlModel.handle(Data(request.utf8), displays: displays)
            XCTAssertFalse(result.response.ok, request)
            XCTAssertNil(result.connectionChange, request)
        }
    }

    func testDisplayRecordFromAnOlderCrispctlStillDecodes() {
        // The help promises forward compatibility; a reply without the newer fields
        // must decode rather than throw.
        let legacy = #"{"id":7,"name":"Studio Display","brightness":64,"isBuiltin":false}"#
        let decoded = try? JSONDecoder().decode(CrispControlDisplay.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded?.uuid, "")
        XCTAssertEqual(decoded?.connected, true)
    }

    private func classify(
        _ json: String,
        _ command: CrispControlRequest.Command
    ) -> CrispControlCLIModel.ResponseResult {
        CrispControlCLIModel.classify(Data(json.utf8), for: command)
    }
}
