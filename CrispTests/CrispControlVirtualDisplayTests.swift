import XCTest

final class CrispControlVirtualDisplayTests: XCTestCase {
    private let id = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!

    func testCLIParsesSavedIdentityAndCreationOptions() {
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["status"]), .request(.init(command: .status)))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["virtual", "list"]), .request(.init(command: .listVirtualDisplays)))
        let config = CrispControlVirtualDisplayConfig(id: id, name: "Work", width: 1920, height: 1080, autoCreate: false)
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: [
            "virtual", "configure", id.uuidString, "Work", "1920", "1080", "on", "off"
        ]), .request(.init(command: .configureVirtualDisplay, selector: id.uuidString, virtualConfig: config)))
        for (verb, command) in [("ensure", CrispControlRequest.Command.ensureVirtualDisplay), ("disable", .disableVirtualDisplay)] {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["virtual", verb, id.uuidString]),
                           .request(.init(command: command, selector: id.uuidString)))
        }
    }

    func testInvalidCLIAndWireConfigurationCannotSelectAnotherTarget() {
        for args in [
            ["virtual", "ensure", "main"], ["virtual", "disable", "42"],
            ["virtual", "configure", id.uuidString, "Work", "1920.5", "1080", "on", "off"],
            ["virtual", "configure", id.uuidString, "Work", "99999", "1080", "on", "off"],
            ["virtual", "configure", id.uuidString, "Work", "1920", "1080", "yes", "off"]
        ] {
            guard case .failure = CrispControlCLIModel.parse(arguments: args) else { return XCTFail("accepted \(args)") }
        }
        let config = CrispControlVirtualDisplayConfig(name: "Work", width: 1920, height: 1080)
        XCTAssertNil(CrispControlRequest(command: .configureVirtualDisplay, selector: id.uuidString,
                                        virtualConfig: config).virtualConfigID)
        XCTAssertNil(CrispControlRequest(command: .ensureVirtualDisplay, selector: "42").virtualConfigID)
        var invalid = config
        invalid.width = -1
        XCTAssertNil(CrispControlRequest(command: .configureVirtualDisplay, selector: invalid.id.uuidString,
                                        virtualConfig: invalid).virtualConfigID)
    }

    func testDescriptorIdentityIsStableAndDoesNotMatchAnUnrelatedScreen() throws {
        let config = CrispControlVirtualDisplayConfig(id: id, name: "Work", width: 1920, height: 1080)
        XCTAssertEqual(config.productID, 0x12345678)
        XCTAssertEqual(config.serialNumber, 0x9ABCDEF0)
        XCTAssertTrue(config.matchesDescriptor(vendor: 0xEEEE, product: config.productID, serial: config.serialNumber))
        XCTAssertFalse(config.matchesDescriptor(vendor: 1, product: config.productID, serial: config.serialNumber))
        XCTAssertFalse(config.matchesDescriptor(vendor: 0xEEEE, product: config.productID, serial: 1))
        XCTAssertEqual(try JSONDecoder().decode(CrispControlVirtualDisplayConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testRepeatedEnsureAndTimedOutApplyDoNotReserveAnotherObject() {
        var gate = VirtualDisplayCreationGate()
        XCTAssertEqual(gate.begin(id, retained: false), .create)
        XCTAssertEqual(gate.begin(id, retained: false), .inProgress)
        gate.beginApply(id)
        gate.finish(id) // A timeout ended the wait, not the background apply.
        XCTAssertTrue(gate.isBusy(id))
        XCTAssertEqual(gate.begin(id, retained: true), .inProgress)
        gate.finishApply(id)
        XCTAssertFalse(gate.isBusy(id))
        XCTAssertEqual(gate.begin(id, retained: true), .retained)
        XCTAssertEqual(gate.begin(UUID(), retained: false), .create)
    }

    func testPersistenceReadbackAndRejectedWrite() throws {
        let suite = "CrispVirtualTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = CrispControlVirtualDisplayConfig(id: id, name: "Work", width: 1920, height: 1080, autoCreate: false)
        XCTAssertTrue(CrispControlVirtualDisplayConfig.save([config], to: defaults, key: "configs"))
        let data = try XCTUnwrap(defaults.data(forKey: "configs"))
        XCTAssertEqual(try JSONDecoder().decode([CrispControlVirtualDisplayConfig].self, from: data), [config])
        let rejecting = try XCTUnwrap(RejectingVirtualDefaults(suiteName: suite + ".reject"))
        defer { rejecting.removePersistentDomain(forName: suite + ".reject") }
        XCTAssertFalse(CrispControlVirtualDisplayConfig.save([config], to: rejecting, key: "configs"))
    }

    func testFailureRetainsSavedRequestedAndOfflineTruthInJSONAndText() throws {
        let state = CrispControlVirtualDisplay(
            config: .init(id: id, name: "Work", width: 1920, height: 1080), saved: true,
            enableRequested: true, creating: false, retained: true, online: false,
            active: false, ready: false, displayID: 42, resolution: nil, lastError: "apply failed"
        )
        let response = CrispControlResponse(ok: false, virtualDisplay: state, error: "outcome uncertain; do not retry automatically")
        let data = CrispControlModel.encode(response)
        XCTAssertEqual(try JSONDecoder().decode(CrispControlResponse.self, from: data), response)
        XCTAssertEqual(CrispControlCLIModel.classify(data, for: .ensureVirtualDisplay), .serverFailure)
        let text = CrispControlText.render(.init(ok: true, virtualDisplays: [state]), for: .listVirtualDisplays)
        XCTAssertTrue(text.contains(id.uuidString))
        XCTAssertTrue(text.contains("apply failed"))
        let emptyStatus = CrispControlResponse(ok: true, running: true, virtualDisplays: [])
        XCTAssertEqual(CrispControlText.render(emptyStatus, for: .status), "no saved virtual displays")
    }

    func testVirtualWriteBudgetKeepsReadsAndPhysicalCommandsUnchanged() {
        for command in [CrispControlRequest.Command.configureVirtualDisplay, .ensureVirtualDisplay, .disableVirtualDisplay] {
            XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: command), 67)
        }
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .listVirtualDisplays), 2)
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .disconnectDisplay), 30)
    }
}

private final class RejectingVirtualDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {}
}
