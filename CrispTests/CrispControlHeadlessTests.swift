import XCTest

final class CrispControlHeadlessTests: XCTestCase {
    private let physical = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    private let config = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!

    func testCLIRequiresStablePhysicalConfigAndSessionIdentities() {
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["headless", "status"]),
                       .request(.init(command: .headlessStatus)))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["headless", "start", physical.lowercased(), config.uuidString]),
                       .request(.init(command: .headlessStart, selector: physical, headlessConfigID: config)))
        for (verb, command) in [("confirm", CrispControlRequest.Command.headlessConfirm), ("restore", .headlessRestore)] {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["headless", verb, config.uuidString]),
                           .request(.init(command: command, selector: config.uuidString)))
        }
        for args in [["headless", "start", "1", config.uuidString], ["headless", "start", physical, "1"],
                     ["headless", "restore", "all"], ["headless", "confirm", config.uuidString, "extra"]] {
            guard case .failure = CrispControlCLIModel.parse(arguments: args) else { return XCTFail("accepted \(args)") }
        }
    }

    func testConfirmCannotAcceptAStaleTokenExpiredTrialOrUnknownNativeState() {
        var session = CrispControlHeadlessSession(id: UUID(), physicalUUID: physical, virtualConfigID: config)
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: false))
        session.phase = .awaitingConfirmation
        XCTAssertTrue(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: false))
        XCTAssertFalse(session.canConfirm(UUID(), expired: false, virtualReady: true, physicalOnline: false))
        XCTAssertFalse(session.canConfirm(session.id, expired: true, virtualReady: true, physicalOnline: false))
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: false, physicalOnline: false))
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: nil))
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: true))
        session.phase = .restoring
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: false))
    }

    func testConfirmationEndsTrialButNeverDisablesVirtualLossRecovery() {
        var session = CrispControlHeadlessSession(id: UUID(), physicalUUID: physical, virtualConfigID: config)
        session.phase = .awaitingConfirmation
        XCTAssertNotNil(session.recoveryReason(expired: true, virtualReady: true))
        session.phase = .active
        XCTAssertNil(session.recoveryReason(expired: true, virtualReady: true))
        XCTAssertNotNil(session.recoveryReason(expired: false, virtualReady: false))
        session.phase = .recoveryFailed
        XCTAssertTrue(session.needsRecovery)
        XCTAssertNil(session.recoveryReason(expired: true, virtualReady: false)) // no blind retry loop
        session.phase = .restored
        XCTAssertFalse(session.needsRecovery)
    }

    func testConfirmedSessionReuseStillRequiresCurrentDisplayReadiness() {
        var session = CrispControlHeadlessSession(id: UUID(), physicalUUID: physical, virtualConfigID: config)
        session.phase = .active
        XCTAssertTrue(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: false))
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: false, physicalOnline: false))
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: nil))
        XCTAssertFalse(session.canConfirm(session.id, expired: false, virtualReady: true, physicalOnline: true))
    }

    func testJSONPreservesRecoveryFailureAndUnknownPhysicalState() throws {
        var session = CrispControlHeadlessSession(id: UUID(), physicalUUID: physical, virtualConfigID: config)
        session.phase = .recoveryFailed
        let state = CrispControlHeadlessState(session: session, physicalOnline: nil, virtualReady: true,
                                             lastError: "native transaction still in flight")
        let response = CrispControlResponse(ok: false, headless: state, error: "recovery not verified")
        let data = CrispControlModel.encode(response)
        XCTAssertEqual(try JSONDecoder().decode(CrispControlResponse.self, from: data), response)
        XCTAssertEqual(CrispControlCLIModel.classify(data, for: .headlessRestore), .serverFailure)
        let text = CrispControlText.render(response, for: .headlessStatus)
        XCTAssertTrue(text.contains("recoveryFailed"))
        XCTAssertTrue(text.contains("physicalOnline=unknown"))
    }

    func testMissingUUIDRecoveryRequiresTheRecordedIDAndHardwareDescriptor() {
        let expected = CrispControlPhysicalIdentity(displayID: 1, uuid: physical, vendor: 1552,
                                                    product: 41038, serial: 4251086178, isBuiltin: true)
        let hidden = CrispControlPhysicalIdentity(displayID: 1, uuid: nil, vendor: 1552,
                                                  product: 41038, serial: 4251086178, isBuiltin: true)
        XCTAssertTrue(expected.canRecoverRecorded(hidden))
        for other in [
            CrispControlPhysicalIdentity(displayID: 2, uuid: nil, vendor: 1552,
                                         product: 41038, serial: 4251086178, isBuiltin: true),
            CrispControlPhysicalIdentity(displayID: 1, uuid: config.uuidString, vendor: 1552,
                                         product: 41038, serial: 4251086178, isBuiltin: true),
            CrispControlPhysicalIdentity(displayID: 1, uuid: nil, vendor: 1552,
                                         product: 41038, serial: 123, isBuiltin: true),
            CrispControlPhysicalIdentity(displayID: 1, uuid: nil, vendor: 0,
                                         product: 0, serial: 0, isBuiltin: false)
        ] { XCTAssertFalse(expected.canRecoverRecorded(other)) }
    }

    func testWireRequestAndTimeoutBudgets() throws {
        let request = CrispControlRequest(command: .headlessStart, selector: physical, headlessConfigID: config)
        XCTAssertEqual(try JSONDecoder().decode(CrispControlRequest.self, from: CrispControlModel.encode(request)), request)
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .headlessStatus), 2)
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .headlessStart), 45)
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .headlessRestore), 67)
        XCTAssertEqual(CrispControlCLIModel.receiveTimeoutSeconds(for: .disconnectDisplay), 30)
    }

    func testUUIDLessExternalRecoveryNeedsANonzeroSerial() {
        func screen(uuid: String?, serial: UInt32) -> CrispControlPhysicalIdentity {
            .init(displayID: 2, uuid: uuid, vendor: 123, product: 456, serial: serial, isBuiltin: false)
        }
        XCTAssertFalse(screen(uuid: physical, serial: 0).canRecoverRecorded(screen(uuid: nil, serial: 0)))
        XCTAssertTrue(screen(uuid: physical, serial: 789).canRecoverRecorded(screen(uuid: nil, serial: 789)))
        // A real UUID still identifies a serial-less screen without that fallback.
        XCTAssertTrue(screen(uuid: physical, serial: 0).canRecoverRecorded(screen(uuid: physical, serial: 0)))
    }
}
