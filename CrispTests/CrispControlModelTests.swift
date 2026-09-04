import XCTest

final class CrispControlModelTests: XCTestCase {
    private let display = CrispControlDisplay(
        id: 7,
        name: "Studio Display",
        brightness: 64,
        maxBrightness: 100,
        isBuiltin: false,
        uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        resolution: CrispControlResolution(
            logicalWidth: 2560,
            logicalHeight: 1440,
            pixelWidth: 5120,
            pixelHeight: 2880,
            refreshRate: 60,
            isHiDPI: true
        ),
        brightnessBackend: .ddc
    )

    func testParserSupportsSevenControlCommandsByIDAndUUID() {
        let cases: [([String], CrispControlRequest)] = [
            (["display", "list"], .init(command: .list)),
            (["brightness", "get", "42"], .init(command: .getBrightness, selector: "42")),
            (
                ["brightness", "get", "37D8832A-2D66-02CA-B9F7-8F30A301B230"],
                .init(command: .getBrightness, selector: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
            ),
            (
                ["brightness", "set", "42", "37.5"],
                .init(command: .setBrightness, brightness: 37.5, selector: "42")
            ),
            (["brightness", "boost", "get", "42"], .init(command: .getBrightnessBoost, selector: "42")),
            (
                ["brightness", "boost", "get", "37D8832A-2D66-02CA-B9F7-8F30A301B230"],
                .init(command: .getBrightnessBoost, selector: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
            ),
            (
                ["brightness", "boost", "set", "42", "on"],
                .init(command: .setBrightnessBoost, selector: "42", enabled: true)
            ),
            (
                ["brightness", "boost", "set", "37D8832A-2D66-02CA-B9F7-8F30A301B230", "off"],
                .init(
                    command: .setBrightnessBoost,
                    selector: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                    enabled: false
                )
            ),
            (["hdr", "get", "42"], .init(command: .getHDR, selector: "42")),
            (
                ["hdr", "get", "37D8832A-2D66-02CA-B9F7-8F30A301B230"],
                .init(command: .getHDR, selector: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
            ),
            (["hdr", "set", "42", "on"], .init(command: .setHDR, selector: "42", enabled: true)),
            (
                ["hdr", "set", "37D8832A-2D66-02CA-B9F7-8F30A301B230", "off"],
                .init(command: .setHDR, selector: "37D8832A-2D66-02CA-B9F7-8F30A301B230", enabled: false)
            )
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
            "display list", "brightness get <display>", "brightness set <display>",
            "brightness boost get <display>", "brightness boost set <display>",
            "hdr get <display>", "hdr set <display>", "help"
        ] {
            XCTAssertTrue(CrispControlCLIModel.help.contains(command), command)
        }
        XCTAssertTrue(CrispControlCLIModel.usage.contains("crispctl help"))
    }

    func testParserRejectsInvalidArityIDsOptionsAndPercent() {
        let cases = [
            ["help", "me"], ["display"], ["displays", "list"], ["display", "list", "--json"],
            ["brightness", "get"], ["brightness", "get", ""], ["brightness", "set", "42"],
            ["brightness", "set", "42", "nan"], ["brightness", "set", "42", "inf"],
            ["brightness", "set", "42", "-0.1"],
            ["brightness", "boost", "get"], ["brightness", "boost", "get", ""],
            ["brightness", "boost", "get", "42", "extra"],
            ["brightness", "boost", "set", "42"], ["brightness", "boost", "set", "", "on"],
            ["brightness", "boost", "set", "42", "true"],
            ["brightness", "boost", "set", "42", "ON"],
            ["brightness", "boost", "set", "42", "on", "extra"],
            ["hdr", "get"], ["hdr", "get", ""], ["hdr", "get", "42", "extra"],
            ["hdr", "set", "42"], ["hdr", "set", "", "on"],
            ["hdr", "set", "42", "true"], ["hdr", "set", "42", "ON"],
            ["hdr", "set", "42", "on", "extra"]
        ]
        for arguments in cases {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .failure)
        }
        for value in ["0", "100", "100.1", "175"] {
            guard case let .request(request) = CrispControlCLIModel.parse(
                arguments: ["brightness", "set", "42", value]
            ) else { return XCTFail("expected boundary \(value)") }
            XCTAssertEqual(request.brightness, Double(value))
        }
    }

    func testOnlyBoundedTransitionCommandsGetLongerReceiveTimeouts() {
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .setBrightnessBoost), 5)
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .setHDR), 6)
        for command in [
            CrispControlRequest.Command.list, .getBrightness, .setBrightness, .getBrightnessBoost, .getHDR
        ] {
            XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: command), 2)
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
        XCTAssertNil(list.brightnessBoostChange)

        let listJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CrispControlModel.encode(list.response))
                as? [String: Any]
        )
        let listedDisplay = try XCTUnwrap((listJSON["displays"] as? [[String: Any]])?.first)
        XCTAssertEqual(listedDisplay["uuid"] as? String, display.uuid)
        XCTAssertEqual(listedDisplay["maxBrightness"] as? Double, 100)
        XCTAssertEqual(listedDisplay["brightnessBackend"] as? String, "ddc")
        XCTAssertEqual((listedDisplay["resolution"] as? [String: Any])?["logicalWidth"] as? Int, 2560)

        let get = CrispControlModel.handle(
            Data(#"{"command":"getBrightness","display":7}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(get.response, .success(display: display))
        XCTAssertNil(get.brightnessChange)
        XCTAssertNil(get.brightnessBoostChange)

        let getJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CrispControlModel.encode(get.response))
                as? [String: Any]
        )
        let returnedDisplay = try XCTUnwrap(getJSON["display"] as? [String: Any])
        XCTAssertEqual(returnedDisplay["uuid"] as? String, display.uuid)
        XCTAssertEqual(returnedDisplay["maxBrightness"] as? Double, 100)
        XCTAssertEqual(returnedDisplay["brightnessBackend"] as? String, "ddc")
        XCTAssertEqual((returnedDisplay["resolution"] as? [String: Any])?["pixelWidth"] as? Int, 5120)

        // The CLI sends what was typed as a selector: an id, or a uuid in any case.
        for selector in ["7", "37d8832a-2d66-02ca-b9f7-8f30a301b230"] {
            let bySelector = CrispControlModel.handle(
                Data(#"{"command":"getBrightness","selector":"\#(selector)"}"#.utf8),
                displays: [display]
            )
            XCTAssertEqual(bySelector.response, .success(display: display), selector)
        }
    }

    func testResolvePrefersIDThenUUIDCaseInsensitive() {
        let other = CrispControlDisplay(id: 9, name: "Other", brightness: 1, isBuiltin: true, uuid: "9")
        let displays = [display, other]
        XCTAssertEqual(CrispControlModel.resolve(selector: "7", in: displays), display)
        // An all-digit uuid still resolves as an id first.
        XCTAssertEqual(CrispControlModel.resolve(selector: "9", in: displays), other)
        XCTAssertEqual(
            CrispControlModel.resolve(selector: "37d8832a-2d66-02ca-b9f7-8f30a301b230", in: displays),
            display
        )
        XCTAssertNil(CrispControlModel.resolve(selector: "8", in: displays))
        XCTAssertNil(CrispControlModel.resolve(selector: "", in: displays))
    }

    func testModelReturnsCurrentBrightnessBoostStateByLegacyIDAndSelector() throws {
        let state = CrispControlBrightnessBoostState(displayID: 7, eligible: false, enabled: true)
        let requests = [
            #"{"command":"getBrightnessBoost","display":7}"#,
            #"{"command":"getBrightnessBoost","selector":"7"}"#,
            #"{"command":"getBrightnessBoost","selector":"37d8832a-2d66-02ca-b9f7-8f30a301b230"}"#
        ]
        for request in requests {
            let result = CrispControlModel.handle(
                Data(request.utf8),
                displays: [display],
                brightnessBoostState: { id in id == state.displayID ? state : nil }
            )
            XCTAssertEqual(result.response, .success(brightnessBoost: state), request)
            XCTAssertNil(result.brightnessChange, request)
            XCTAssertNil(result.brightnessBoostChange, request)
        }

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CrispControlModel.encode(.success(brightnessBoost: state)))
                as? [String: Any]
        )
        let boost = try XCTUnwrap(json["brightnessBoost"] as? [String: Any])
        XCTAssertEqual(boost["displayID"] as? Int, 7)
        XCTAssertEqual(boost["eligible"] as? Bool, false)
        XCTAssertEqual(boost["enabled"] as? Bool, true)
    }

    func testDisplayMetadataAllowsMissingCurrentResolutionAndLegacyResponses() throws {
        let displayWithoutMode = CrispControlDisplay(
            id: 8,
            name: "Projector",
            brightness: 50,
            isBuiltin: false,
            uuid: "stable-projector",
            resolution: nil,
            brightnessBackend: .unknown
        )
        let encoded = CrispControlModel.encode(.success(displays: [displayWithoutMode]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedDisplay = try XCTUnwrap((json["displays"] as? [[String: Any]])?.first)
        XCTAssertNil(encodedDisplay["resolution"])

        let legacy = #"{"ok":true,"display":{"id":7,"name":"Studio Display","brightness":64,"isBuiltin":false}}"#
        let decoded = try JSONDecoder().decode(CrispControlResponse.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.display?.uuid)
        XCTAssertNil(decoded.display?.resolution)
        XCTAssertNil(decoded.display?.brightnessBackend)
        XCTAssertNil(decoded.display?.maxBrightness)
        XCTAssertNil(decoded.brightnessBoost)
        XCTAssertNil(decoded.hdr)
    }

    func testHDRGetUsesLiveStateAndSetCreatesOneRequestedEffect() throws {
        let state = CrispControlHDRState(displayID: 7, enabled: true)
        let get = CrispControlModel.handle(
            Data(#"{"command":"getHDR","selector":"7"}"#.utf8),
            displays: [display],
            hdrState: { $0 == 7 ? state : nil }
        )
        XCTAssertEqual(get.response, .success(hdr: state))
        XCTAssertNil(get.hdrChange)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CrispControlModel.encode(get.response)) as? [String: Any]
        )
        let hdr = try XCTUnwrap(json["hdr"] as? [String: Any])
        XCTAssertEqual(hdr["displayID"] as? Int, 7)
        XCTAssertEqual(hdr["enabled"] as? Bool, true)

        for (selector, enabled) in [
            ("7", true), ("37d8832a-2d66-02ca-b9f7-8f30a301b230", false)
        ] {
            let set = CrispControlModel.handle(
                Data(#"{"command":"setHDR","selector":"\#(selector)","enabled":\#(enabled)}"#.utf8),
                displays: [display],
                hdrState: { _ in state },
                hdrMutationUUID: { _ in self.display.uuid }
            )
            XCTAssertEqual(set.response, .success())
            XCTAssertEqual(
                set.hdrChange,
                .init(displayID: 7, displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230", enabled: enabled)
            )
        }

        let fallbackDisplay = CrispControlDisplay(
            id: 8, name: "Unknown", brightness: 50, isBuiltin: false,
            uuid: "v1-m2-s3"
        )
        let fallbackState = CrispControlHDRState(displayID: 8, enabled: false)
        let fallbackGet = CrispControlModel.handle(
            Data(#"{"command":"getHDR","display":8}"#.utf8),
            displays: [fallbackDisplay],
            hdrState: { _ in fallbackState }
        )
        XCTAssertEqual(fallbackGet.response, .success(hdr: fallbackState))

        let missingIdentity = CrispControlModel.handle(
            Data(#"{"command":"setHDR","display":8,"enabled":true}"#.utf8),
            displays: [fallbackDisplay],
            hdrState: { _ in fallbackState }
        )
        XCTAssertEqual(missingIdentity.response, .failure("unique live display identity is unavailable"))
        XCTAssertNil(missingIdentity.hdrChange)
    }

    func testHDRRejectsBuiltinAndUnsupportedExternalDisplays() {
        let builtin = CrispControlDisplay(id: 9, name: "Built-in", brightness: 50, isBuiltin: true)
        let builtInResult = CrispControlModel.handle(
            Data(#"{"command":"getHDR","display":9}"#.utf8),
            displays: [builtin],
            hdrState: { _ in .init(displayID: 9, enabled: true) }
        )
        XCTAssertEqual(
            builtInResult.response,
            .failure(
                "explicit HDR is unsupported for built-in displays; use Extra Brightness "
                    + "with 'crispctl brightness boost set <display> on' when eligible"
            )
        )

        let unsupported = CrispControlModel.handle(
            Data(#"{"command":"setHDR","display":7,"enabled":true}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(unsupported.response, .failure("explicit HDR is unsupported for this external display"))
        XCTAssertNil(unsupported.hdrChange)
    }

    func testHDRFallbackSelectorCanGetButCannotSetUsingLiveSystemUUID() {
        let fallbackDisplay = CrispControlDisplay(
            id: 8, name: "Unknown", brightness: 50, isBuiltin: false,
            uuid: "v1-m2-s3"
        )
        let state = CrispControlHDRState(displayID: 8, enabled: false)
        let get = CrispControlModel.handle(
            Data(#"{"command":"getHDR","selector":"V1-M2-S3"}"#.utf8),
            displays: [fallbackDisplay],
            hdrState: { _ in state }
        )
        XCTAssertEqual(get.response, .success(hdr: state))

        let set = CrispControlModel.handle(
            Data(#"{"command":"setHDR","selector":"v1-m2-s3","enabled":true}"#.utf8),
            displays: [fallbackDisplay],
            hdrState: { _ in state },
            hdrMutationUUID: { _ in "37D8832A-2D66-02CA-B9F7-8F30A301B230" }
        )
        XCTAssertEqual(set.response, .failure("unique live display identity does not match selector"))
        XCTAssertNil(set.hdrChange)
    }

    func testHDRSetRequiresAcceptanceAndMatchingLiveReadBack() {
        XCTAssertEqual(
            CrispControlModel.hdrSetResponse(
                displayID: 7, enabled: true, accepted: true, liveEnabled: true
            ),
            .success(hdr: .init(displayID: 7, enabled: true))
        )
        XCTAssertEqual(
            CrispControlModel.hdrSetResponse(
                displayID: 7, enabled: false, accepted: false, liveEnabled: true
            ),
            .failure("HDR request was not accepted")
        )
        let uncertain = CrispControlModel.hdrSetResponse(
            displayID: 7, enabled: false, accepted: true, liveEnabled: true
        )
        XCTAssertFalse(uncertain.ok)
        XCTAssertTrue(uncertain.error?.contains("outcome is uncertain") == true)
        XCTAssertTrue(uncertain.error?.contains("crispctl hdr get <display>") == true)
        XCTAssertEqual(CrispControlCLIModel.classify(CrispControlModel.encode(uncertain), for: .setHDR), .serverFailure)
    }

    func testBoostedListGetAndSetUseTheLiveLogicalRange() throws {
        let boosted = CrispControlDisplay(
            id: 7,
            name: "Studio Display",
            brightness: 135,
            maxBrightness: 160,
            isBuiltin: false
        )
        let enabled = CrispControlBrightnessBoostState(displayID: 7, eligible: true, enabled: true)
        let state: (UInt32) -> CrispControlBrightnessBoostState? = { $0 == 7 ? enabled : nil }

        let list = CrispControlModel.handle(Data(#"{"command":"list"}"#.utf8), displays: [boosted])
        XCTAssertEqual(list.response.displays?.first?.brightness, 135)
        XCTAssertEqual(list.response.displays?.first?.maxBrightness, 160)
        let get = CrispControlModel.handle(
            Data(#"{"command":"getBrightness","display":7}"#.utf8), displays: [boosted]
        )
        XCTAssertEqual(get.response.display?.brightness, 135)
        XCTAssertEqual(get.response.display?.maxBrightness, 160)

        let accepted = CrispControlModel.handle(
            Data(#"{"command":"setBrightness","display":7,"brightness":150}"#.utf8),
            displays: [boosted],
            brightnessBoostState: state
        )
        XCTAssertEqual(accepted.response, .success())
        XCTAssertEqual(accepted.brightnessChange, .init(displayID: 7, brightness: 150))

        let tooHigh = CrispControlModel.handle(
            Data(#"{"command":"setBrightness","display":7,"brightness":161}"#.utf8),
            displays: [boosted],
            brightnessBoostState: state
        )
        XCTAssertEqual(tooHigh.response, .failure("brightness exceeds the live maximum of 160.0"))
        XCTAssertNil(tooHigh.brightnessChange)
    }

    func testBoostedSetRequiresEnabledEligibleStateButNativeRangeDoesNot() {
        let boosted = CrispControlDisplay(
            id: 7, name: "Studio Display", brightness: 100, maxBrightness: 160, isBuiltin: false
        )
        func set(_ value: Double, state: CrispControlBrightnessBoostState?) -> CrispControlResult {
            CrispControlModel.handle(
                Data(#"{"command":"setBrightness","display":7,"brightness":\#(value)}"#.utf8),
                displays: [boosted],
                brightnessBoostState: { _ in state }
            )
        }

        let disabled = set(120, state: .init(displayID: 7, eligible: true, enabled: false))
        XCTAssertEqual(disabled.response, .failure("extra brightness is disabled for this display"))
        XCTAssertNil(disabled.brightnessChange)
        let ineligible = set(120, state: .init(displayID: 7, eligible: false, enabled: true))
        XCTAssertEqual(ineligible.response, .failure("extra brightness is not eligible for this display"))
        XCTAssertNil(ineligible.brightnessChange)

        for value in [0.0, 100.0] {
            XCTAssertEqual(set(value, state: nil).brightnessChange, .init(displayID: 7, brightness: value))
        }
    }

    func testBrightnessBackendClassifierCoversCurrentRouting() {
        XCTAssertEqual(
            CrispControlModel.brightnessBackend(
                isBuiltin: true, hdrSoftwareDimming: false, ddcAvailable: nil
            ),
            .builtin
        )
        XCTAssertEqual(
            CrispControlModel.brightnessBackend(
                isBuiltin: false, hdrSoftwareDimming: false, ddcAvailable: true
            ),
            .ddc
        )
        XCTAssertEqual(
            CrispControlModel.brightnessBackend(
                isBuiltin: false, hdrSoftwareDimming: false, ddcAvailable: false
            ),
            .software
        )
        XCTAssertEqual(
            CrispControlModel.brightnessBackend(
                isBuiltin: false, hdrSoftwareDimming: true, ddcAvailable: true
            ),
            .software
        )
        XCTAssertEqual(
            CrispControlModel.brightnessBackend(
                isBuiltin: false, hdrSoftwareDimming: false, ddcAvailable: nil
            ),
            .unknown
        )
    }

    func testSetEncodesOnlyOKAndCreatesRequestedBrightnessChange() {
        let result = CrispControlModel.handle(
            Data(#"{"command":"setBrightness","display":7,"brightness":35}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(result.response, .success())
        XCTAssertEqual(result.brightnessChange, .init(displayID: 7, brightness: 35))
        XCTAssertNil(result.brightnessBoostChange)
        let bySelector = CrispControlModel.handle(
            Data(#"{"command":"setBrightness","selector":"37D8832A-2D66-02CA-B9F7-8F30A301B230","brightness":35}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(bySelector.brightnessChange, .init(displayID: 7, brightness: 35))
        XCTAssertNil(bySelector.brightnessBoostChange)
        XCTAssertEqual(
            CrispControlModel.encode(result.response),
            Data(#"{"ok":true}"#.utf8) + Data([0x0A])
        )
    }

    func testBrightnessBoostSetCreatesRequestedEffectForOnAndOff() {
        let requests = [
            (#"{"command":"setBrightnessBoost","display":7,"enabled":true}"#, true),
            (
                #"{"command":"setBrightnessBoost","selector":"37d8832a-2d66-02ca-b9f7-8f30a301b230","enabled":false}"#,
                false
            )
        ]
        for (request, enabled) in requests {
            let result = CrispControlModel.handle(
                Data(request.utf8),
                displays: [display]
            )
            XCTAssertEqual(result.response, .success(), request)
            XCTAssertNil(result.brightnessChange, request)
            XCTAssertEqual(result.brightnessBoostChange, .init(displayID: 7, enabled: enabled), request)
        }
    }

    func testBrightnessBoostSetResponseTurnsServiceRefusalIntoServerFailure() {
        XCTAssertEqual(
            CrispControlModel.brightnessBoostSetResponse(enabled: true, accepted: true),
            .success()
        )
        let refused = CrispControlModel.brightnessBoostSetResponse(enabled: true, accepted: false)
        XCTAssertEqual(refused, .failure("extra brightness could not be enabled"))
        XCTAssertEqual(
            CrispControlCLIModel.classify(
                CrispControlModel.encode(refused),
                for: .setBrightnessBoost
            ),
            .serverFailure
        )
        XCTAssertEqual(
            CrispControlModel.brightnessBoostSetResponse(enabled: false, accepted: false),
            .failure("extra brightness could not be disabled")
        )
    }

    func testModelRejectsMalformedMissingUnknownAndOutOfRangeRequests() {
        let requests = [
            #"{"command":"list""#,
            #"{"command":"getBrightness"}"#,
            #"{"command":"getBrightness","display":8}"#,
            #"{"command":"getBrightness","selector":"nope"}"#,
            #"{"command":"setBrightness","selector":"","brightness":35}"#,
            #"{"command":"setBrightness","display":7}"#,
            #"{"command":"getBrightnessBoost"}"#,
            #"{"command":"getBrightnessBoost","display":8}"#,
            #"{"command":"getBrightnessBoost","selector":"nope"}"#,
            #"{"command":"setBrightnessBoost","display":7}"#,
            #"{"command":"setBrightnessBoost","display":8,"enabled":false}"#,
            #"{"command":"setBrightnessBoost","selector":"nope","enabled":false}"#,
            #"{"command":"setBrightnessBoost","display":7,"enabled":"on"}"#,
            #"{"command":"getHDR"}"#,
            #"{"command":"getHDR","display":8}"#,
            #"{"command":"setHDR","display":7}"#,
            #"{"command":"setHDR","display":7,"enabled":"on"}"#,
            #"{"command":"unknown"}"#
        ]
        for request in requests {
            let result = CrispControlModel.handle(Data(request.utf8), displays: [display])
            XCTAssertFalse(result.response.ok, request)
            XCTAssertNil(result.brightnessChange, request)
            XCTAssertNil(result.brightnessBoostChange, request)
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
        [.list, .getBrightness, .setBrightness, .getBrightnessBoost, .setBrightnessBoost, .getHDR, .setHDR]
    }

    private func classify(
        _ json: String,
        _ command: CrispControlRequest.Command
    ) -> CrispControlCLIModel.ResponseResult {
        CrispControlCLIModel.classify(Data(json.utf8), for: command)
    }
}
