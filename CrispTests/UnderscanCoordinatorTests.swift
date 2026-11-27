import CoreGraphics
import Foundation
import XCTest

/// Thread-safe mock backend allowing full deterministic testing without physical monitors.
private final class MockUnderscanBackend: UnderscanBackend, @unchecked Sendable {
    let hostArchitecture: HostArchitecture
    private let lock = NSLock()

    var capabilitiesByDisplayID: [CGDirectDisplayID: UnderscanCapability] = [:]
    var defaultCapability: UnderscanCapability
    var forcedApplyResult: Result<UnderscanApplyOutcome, UnderscanError>? = nil
    var applyDelayNs: UInt64 = 0
    private(set) var appliedCalls: [(displayID: CGDirectDisplayID, rawValue: Int32, force: Bool)] = []
    private(set) var readbackCalls: [CGDirectDisplayID] = []
    var hardwareRawByDisplayID: [CGDirectDisplayID: Int32] = [:]

    init(
        architecture: HostArchitecture = .appleSilicon,
        defaultAvailability: UnderscanAvailability = .nativeSupported(minRaw: 7500, maxRaw: 10000, canReadback: true)
    ) {
        self.hostArchitecture = architecture
        let canReadback: Bool
        if case .nativeSupported(_, _, let rb) = defaultAvailability {
            canReadback = rb
        } else {
            canReadback = false
        }
        self.defaultCapability = UnderscanCapability(
            availability: defaultAvailability,
            architecture: architecture,
            osVersion: "macOS 27.2.1",
            readbackAvailable: canReadback,
            hardwareConfirmedRaw: canReadback ? 10000 : nil
        )
    }

    func probeCapability(for display: DisplayUnderscanDescriptor) -> UnderscanCapability {
        lock.withLock {
            if display.isBuiltin {
                return UnderscanCapability(
                    availability: .builtInRestricted,
                    architecture: hostArchitecture,
                    osVersion: "macOS 27.2.1",
                    readbackAvailable: false,
                    hardwareConfirmedRaw: nil
                )
            }
            if display.isVirtual {
                return UnderscanCapability(
                    availability: .virtualDisplayUnsupported,
                    architecture: hostArchitecture,
                    osVersion: "macOS 27.2.1",
                    readbackAvailable: false,
                    hardwareConfirmedRaw: nil
                )
            }
            if let cap = capabilitiesByDisplayID[display.displayID] {
                if cap.readbackAvailable, let hw = hardwareRawByDisplayID[display.displayID] {
                    return UnderscanCapability(
                        availability: cap.availability,
                        architecture: cap.architecture,
                        osVersion: cap.osVersion,
                        readbackAvailable: true,
                        hardwareConfirmedRaw: hw
                    )
                }
                return cap
            }
            if defaultCapability.readbackAvailable, let hw = hardwareRawByDisplayID[display.displayID] {
                return UnderscanCapability(
                    availability: defaultCapability.availability,
                    architecture: defaultCapability.architecture,
                    osVersion: defaultCapability.osVersion,
                    readbackAvailable: true,
                    hardwareConfirmedRaw: hw
                )
            }
            return defaultCapability
        }
    }

    func applyUnderscan(
        rawValue: Int32,
        to display: DisplayUnderscanDescriptor,
        forceExperimental: Bool
    ) -> Result<UnderscanApplyOutcome, UnderscanError> {
        let delay = lock.withLock { applyDelayNs }
        if delay > 0 {
            Thread.sleep(forTimeInterval: Double(delay) / 1_000_000_000.0)
        }
        return lock.withLock {
            appliedCalls.append((display.displayID, rawValue, forceExperimental))
            if let forced = forcedApplyResult {
                return forced
            }
            let cap = capabilitiesByDisplayID[display.displayID] ?? defaultCapability
            switch cap.availability {
            case .frameworkUnavailable(let fw):
                return .failure(.frameworkUnavailable(fw))
            case .symbolMissing(let sym):
                return .failure(.symbolMissing(sym))
            case .invalidSignature(let sym):
                return .failure(.invalidSignature(sym))
            case .builtInRestricted:
                return .failure(.builtInDisplayBlocked)
            case .virtualDisplayUnsupported:
                return .failure(.virtualDisplayUnsupported)
            case .displayNotFound:
                return .failure(.displayNotFound(display.displayID))
            case .unsupportedHardware(let reason):
                guard forceExperimental else {
                    return .failure(.unsupportedDisplay(reason))
                }
                // Never confirm hardware readback on experimental force path.
                return .success(UnderscanApplyOutcome(submittedRaw: rawValue, confirmedRaw: nil, wasExperimentalForce: true))
            case .nativeSupported(_, _, let canReadback):
                if canReadback {
                    hardwareRawByDisplayID[display.displayID] = rawValue
                }
                return .success(UnderscanApplyOutcome(
                    submittedRaw: rawValue,
                    confirmedRaw: canReadback ? rawValue : nil,
                    wasExperimentalForce: false
                ))
            }
        }
    }

    func readHardwareUnderscan(for display: DisplayUnderscanDescriptor) -> Int32? {
        lock.withLock {
            readbackCalls.append(display.displayID)
            let cap = capabilitiesByDisplayID[display.displayID] ?? defaultCapability
            guard cap.readbackAvailable else { return nil }
            return hardwareRawByDisplayID[display.displayID] ?? cap.hardwareConfirmedRaw
        }
    }

    func resetRecordedCalls() {
        lock.withLock { appliedCalls.removeAll() }
    }
}

@MainActor
final class UnderscanCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: UnderscanStore!

    private let fastTiming = UnderscanTiming(
        sliderThrottleNs: 20_000_000,
        startupStabilizeNs: 15_000_000,
        wakeStabilizeNs: 15_000_000,
        reconnectStabilizeNs: 15_000_000,
        modeChangeStabilizeNs: 15_000_000,
        retryDelaysNs: [10_000_000, 10_000_000],
        maxConsecutiveFailuresBeforeSuspend: 3,
        selfApplySuppressionSeconds: 0.25,
        rollbackTimeoutSeconds: 2,
        rollbackTickNs: 15_000_000
    )

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.reconditum.crisp.coordtests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = UnderscanStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeMonitor(
        id: CGDirectDisplayID = 10,
        uuid: String = "PROART-UUID-1",
        serial: UInt32 = 101,
        location: String? = "port-0",
        isBuiltin: Bool = false,
        isVirtual: Bool = false,
        name: String = "ASUS ProArt PA278QV"
    ) -> DisplayUnderscanDescriptor {
        DisplayUnderscanDescriptor(
            displayID: id,
            cgUUID: uuid,
            vendorNumber: 0x06B3,
            modelNumber: 0x279C,
            serialNumber: serial,
            channelLocation: location,
            isBuiltin: isBuiltin,
            isVirtual: isVirtual,
            displayName: name
        )
    }

    // MARK: - Missing framework, missing symbol, unsupported / built-in / virtual displays

    func testMissingFrameworkIsReportedWithoutCrashing() async {
        let backend = MockUnderscanBackend(defaultAvailability: .frameworkUnavailable(framework: "MonitorPanel.framework"))
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        let state = await coordinator.refreshDisplay(monitor, among: [monitor])
        XCTAssertEqual(state.capability.availability, .frameworkUnavailable(framework: "MonitorPanel.framework"))
        XCTAssertFalse(state.isControlUsable)

        let result = await coordinator.applyPercentage(90, for: monitor, among: [monitor])
        XCTAssertEqual(result, .failure(.frameworkUnavailable("MonitorPanel.framework")))
    }

    func testMissingSymbolIsReportedWithoutCrashing() async {
        let backend = MockUnderscanBackend(defaultAvailability: .symbolMissing(symbol: "MPDisplay.setUnderscan:"))
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        let state = await coordinator.refreshDisplay(monitor, among: [monitor])
        XCTAssertEqual(state.capability.availability, .symbolMissing(symbol: "MPDisplay.setUnderscan:"))
        XCTAssertFalse(state.isControlUsable)

        let result = await coordinator.applyPercentage(90, for: monitor, among: [monitor])
        XCTAssertEqual(result, .failure(.symbolMissing("MPDisplay.setUnderscan:")))
    }

    func testBuiltInAndVirtualDisplaysAreRejected() async {
        let backend = MockUnderscanBackend()
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let builtin = makeMonitor(id: 1, uuid: "BUILTIN", isBuiltin: true, name: "Built-in Display")
        let virtual = makeMonitor(id: 2, uuid: "VIRTUAL", isVirtual: true, name: "Virtual Display")

        let builtinResult = await coordinator.applyPercentage(90, for: builtin, among: [builtin, virtual])
        XCTAssertEqual(builtinResult, .failure(.builtInDisplayBlocked))

        // Force-enable cannot be turned on for built-in displays.
        coordinator.updateSettings(for: builtin, among: [builtin]) {
            $0.forceEnableExperimental = true
            $0.isEnabled = true
        }
        XCTAssertFalse(coordinator.state(for: builtin, among: [builtin]).settings.forceEnableExperimental)

        let virtualResult = await coordinator.applyPercentage(90, for: virtual, among: [builtin, virtual])
        XCTAssertEqual(virtualResult, .failure(.virtualDisplayUnsupported))
    }

    func testUnsupportedDisplayRequiresForceEnableAndExplicitConfirmation() async {
        let backend = MockUnderscanBackend(
            defaultAvailability: .unsupportedHardware(reason: "Not supported on this port")
        )
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        let initial = coordinator.state(for: monitor, among: [monitor])
        XCTAssertFalse(initial.isControlUsable)

        // Direct apply fails cleanly without force-enable.
        let unforced = await coordinator.applyPercentage(92, for: monitor, among: [monitor])
        XCTAssertEqual(unforced, .failure(.unsupportedDisplay("Not supported on this port")))

        // Turning on force-enable still requires explicit risk confirmation before first test.
        coordinator.updateSettings(for: monitor, among: [monitor]) { $0.forceEnableExperimental = true }
        let blocked = await coordinator.applyPercentage(92, for: monitor, among: [monitor])
        XCTAssertEqual(blocked, .failure(.experimentalConfirmationRequired))

        // After confirmation, applies without ever claiming hardware confirmation.
        coordinator.confirmExperimentalRisk(for: monitor, among: [monitor])
        let applied = await coordinator.applyPercentage(92, for: monitor, among: [monitor], triggerRollbackIfExperimental: false)
        guard case .success(let outcome) = applied else {
            return XCTFail("Expected success after confirmation, got \(applied)")
        }
        XCTAssertEqual(outcome.submittedPercentage, 92)
        XCTAssertNil(outcome.confirmedPercentage)
        let state = coordinator.state(for: monitor, among: [monitor])
        XCTAssertEqual(state.requestedPercentage, 92)
        XCTAssertEqual(state.lastSubmittedPercentage, 92)
        XCTAssertNil(state.hardwareConfirmedPercentage)
        XCTAssertEqual(state.status, .submittedUnconfirmed(92))
    }

    // MARK: - Independent monitors, reassigned displayID, identical models

    func testIndependentMonitorConfigurationsAndReassignedDisplayID() async {
        let backend = MockUnderscanBackend()
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitorA = makeMonitor(id: 10, uuid: "UUID-A", serial: 100, location: "port-a", name: "ProArt A")
        let monitorB = makeMonitor(id: 20, uuid: "UUID-B", serial: 200, location: "port-b", name: "ProArt B")

        await coordinator.refreshDisplays([monitorA, monitorB])
        _ = await coordinator.applyPercentage(92, for: monitorA, among: [monitorA, monitorB])
        _ = await coordinator.applyPercentage(84, for: monitorB, among: [monitorA, monitorB])

        XCTAssertEqual(coordinator.state(for: monitorA, among: [monitorA, monitorB]).requestedPercentage, 92)
        XCTAssertEqual(coordinator.state(for: monitorB, among: [monitorA, monitorB]).requestedPercentage, 84)

        // Simulate reboot/reconnection assigning a brand-new CGDirectDisplayID to monitorA.
        let monitorAReassigned = makeMonitor(id: 99, uuid: "UUID-A", serial: 100, location: "port-a", name: "ProArt A")
        backend.hardwareRawByDisplayID[99] = 10000 // macOS reset hardware to 100%
        backend.resetRecordedCalls()

        let task = coordinator.scheduleRestore(for: monitorAReassigned, among: [monitorAReassigned, monitorB], trigger: .reconnect)
        await task?.value

        XCTAssertEqual(backend.appliedCalls.count, 1)
        XCTAssertEqual(backend.appliedCalls.first?.displayID, 99)
        XCTAssertEqual(backend.appliedCalls.first?.rawValue, 9200)
    }

    // MARK: - Sleep/Wake, Disconnect/Reconnect, Resolution changes & Self-apply loop guard

    func testSleepAndWakeRestorationHonorsToggle() async {
        let backend = MockUnderscanBackend()
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        _ = await coordinator.applyPercentage(88, for: monitor, among: [monitor])

        // Simulate macOS resetting hardware to 100% during sleep.
        backend.hardwareRawByDisplayID[monitor.displayID] = 10000
        backend.resetRecordedCalls()

        let wakeTask = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .wake)
        await wakeTask?.value
        XCTAssertEqual(backend.appliedCalls.count, 1)
        XCTAssertEqual(backend.appliedCalls.first?.rawValue, 8800)

        // Disable restoreAfterSleep -> wake must not apply.
        coordinator.updateSettings(for: monitor, among: [monitor]) { $0.restoreAfterSleep = false }
        backend.hardwareRawByDisplayID[monitor.displayID] = 10000
        backend.resetRecordedCalls()

        let skippedTask = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .wake)
        XCTAssertNil(skippedTask)
        XCTAssertTrue(backend.appliedCalls.isEmpty)
    }

    func testDisconnectCancelsPendingRestoreAndReconnectRestores() async {
        let backend = MockUnderscanBackend()
        let onlineBox = OnlineFlagBox(true)
        let timing = UnderscanTiming(
            sliderThrottleNs: 20_000_000,
            startupStabilizeNs: 120_000_000,
            wakeStabilizeNs: 120_000_000,
            reconnectStabilizeNs: 120_000_000,
            modeChangeStabilizeNs: 120_000_000,
            retryDelaysNs: [10_000_000],
            maxConsecutiveFailuresBeforeSuspend: 3,
            selfApplySuppressionSeconds: 0.25,
            rollbackTimeoutSeconds: 2,
            rollbackTickNs: 15_000_000
        )
        let coordinator = UnderscanCoordinator(
            backend: backend,
            store: store,
            timing: timing,
            isDisplayOnline: { _ in onlineBox.isOnline }
        )
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        _ = await coordinator.applyPercentage(90, for: monitor, among: [monitor])
        backend.hardwareRawByDisplayID[monitor.displayID] = 10000
        backend.resetRecordedCalls()

        let pending = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .reconnect)
        onlineBox.isOnline = false
        coordinator.handleDisplayDisconnected(displayID: monitor.displayID)
        await pending?.value
        XCTAssertTrue(backend.appliedCalls.isEmpty, "Disconnect must cancel pending restore")

        // Now monitor comes back online and reconnect restore runs.
        onlineBox.isOnline = true
        let reconnectTask = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .reconnect)
        await reconnectTask?.value
        XCTAssertEqual(backend.appliedCalls.count, 1)
        XCTAssertEqual(backend.appliedCalls.first?.rawValue, 9000)
    }

    func testResolutionChangeRestorationAndSelfApplySuppression() async {
        let backend = MockUnderscanBackend()
        var currentClock = Date(timeIntervalSince1970: 1_000)
        let coordinator = UnderscanCoordinator(
            backend: backend,
            store: store,
            timing: fastTiming,
            isDisplayOnline: { _ in true },
            now: { currentClock }
        )
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        _ = await coordinator.applyPercentage(91, for: monitor, among: [monitor])
        backend.hardwareRawByDisplayID[monitor.displayID] = 10000
        backend.resetRecordedCalls()

        // Immediately after our own apply, mode-change callback is suppressed to prevent loops.
        let suppressed = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .resolutionChange)
        XCTAssertNil(suppressed)

        // Advance past suppression window: real user HiDPI/resolution change triggers restore.
        currentClock = currentClock.addingTimeInterval(2.0)
        let task = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .resolutionChange)
        await task?.value
        XCTAssertEqual(backend.appliedCalls.count, 1)
        XCTAssertEqual(backend.appliedCalls.first?.rawValue, 9100)
    }

    // MARK: - Debouncing, Throttled & Concurrent Slider Changes

    func testDebouncingCoalescesRapidRestoreTriggers() async {
        let backend = MockUnderscanBackend()
        let timing = UnderscanTiming(
            sliderThrottleNs: 20_000_000,
            startupStabilizeNs: 80_000_000,
            wakeStabilizeNs: 80_000_000,
            reconnectStabilizeNs: 80_000_000,
            modeChangeStabilizeNs: 80_000_000,
            retryDelaysNs: [10_000_000],
            maxConsecutiveFailuresBeforeSuspend: 3,
            selfApplySuppressionSeconds: 0.0,
            rollbackTimeoutSeconds: 2,
            rollbackTickNs: 15_000_000
        )
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: timing, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        _ = await coordinator.applyPercentage(87, for: monitor, among: [monitor])
        backend.hardwareRawByDisplayID[monitor.displayID] = 10000
        backend.resetRecordedCalls()

        _ = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .reconnect)
        _ = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .reconnect)
        let last = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .reconnect)
        await last?.value

        XCTAssertEqual(backend.appliedCalls.count, 1, "Rapid triggers must debounce to one native call")
        XCTAssertEqual(backend.appliedCalls.first?.rawValue, 8700)
    }

    func testConcurrentSliderChangesThrottleAndCommitFinalValue() async {
        let backend = MockUnderscanBackend()
        let timing = UnderscanTiming(
            sliderThrottleNs: 60_000_000,
            startupStabilizeNs: 15_000_000,
            wakeStabilizeNs: 15_000_000,
            reconnectStabilizeNs: 15_000_000,
            modeChangeStabilizeNs: 15_000_000,
            retryDelaysNs: [10_000_000],
            maxConsecutiveFailuresBeforeSuspend: 3,
            selfApplySuppressionSeconds: 0.25,
            rollbackTimeoutSeconds: 2,
            rollbackTickNs: 15_000_000
        )
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: timing, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        backend.resetRecordedCalls()

        // Rapid mid-drag scrub events followed by final release at 86%.
        for pct in [98, 96, 94, 92, 90, 88] {
            coordinator.setSliderPercentage(pct, for: monitor, among: [monitor], commitImmediately: false)
        }
        coordinator.setSliderPercentage(86, for: monitor, among: [monitor], commitImmediately: true)

        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(backend.appliedCalls.last?.rawValue, 8600)
        XCTAssertLessThanOrEqual(backend.appliedCalls.count, 2, "Intermediate drag events must be coalesced")
        let finalState = coordinator.state(for: monitor, among: [monitor])
        XCTAssertEqual(finalState.requestedPercentage, 86)
        XCTAssertEqual(finalState.lastSubmittedPercentage, 86)
    }

    // MARK: - Failed Native Calls, Bounded Retries & Automatic Suspension

    func testFailedNativeApplyRecordsErrorWithoutFalsifyingSubmission() async {
        let backend = MockUnderscanBackend()
        backend.forcedApplyResult = .failure(.applyFailed("WindowServer rejected value"))
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        let result = await coordinator.applyPercentage(85, for: monitor, among: [monitor])
        XCTAssertEqual(result, .failure(.applyFailed("WindowServer rejected value")))

        let state = coordinator.state(for: monitor, among: [monitor])
        XCTAssertNil(state.lastSubmittedPercentage)
        XCTAssertEqual(state.status, .failed(.applyFailed("WindowServer rejected value")))
    }

    func testBoundedRetriesAndAutomaticSuspensionAfterRepeatedFailures() async {
        let backend = MockUnderscanBackend()
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        _ = await coordinator.applyPercentage(90, for: monitor, among: [monitor])

        // Now force every subsequent backend call to fail and hardware to report 100%.
        backend.hardwareRawByDisplayID[monitor.displayID] = 10000
        backend.forcedApplyResult = .failure(.applyFailed("IPC failure"))

        for cycle in 1...3 {
            backend.resetRecordedCalls()
            let task = coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .wake)
            XCTAssertNotNil(task, "Cycle \(cycle) should attempt restore")
            await task?.value
            // 1 initial attempt + 2 retryDelays = 3 bounded attempts per cycle.
            XCTAssertEqual(backend.appliedCalls.count, 3)
        }

        let suspended = coordinator.state(for: monitor, among: [monitor])
        XCTAssertTrue(suspended.settings.autoRestoreSuspended)
        XCTAssertEqual(suspended.settings.consecutiveRestoreFailures, 3)
        if case .suspended(let count, _) = suspended.status {
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Expected .suspended status, got \(suspended.status)")
        }

        // Subsequent automatic triggers are ignored while suspended.
        backend.resetRecordedCalls()
        XCTAssertNil(coordinator.scheduleRestore(for: monitor, among: [monitor], trigger: .wake))
        XCTAssertTrue(backend.appliedCalls.isEmpty)

        // Recovery action clears suspension and succeeds once backend recovers.
        backend.forcedApplyResult = nil
        coordinator.resumeAutoRestore(for: monitor, among: [monitor])
        try? await Task.sleep(nanoseconds: 80_000_000)

        let recovered = coordinator.state(for: monitor, among: [monitor])
        XCTAssertFalse(recovered.settings.autoRestoreSuspended)
        XCTAssertEqual(recovered.settings.consecutiveRestoreFailures, 0)
        XCTAssertEqual(recovered.lastSubmittedPercentage, 90)
    }

    // MARK: - Reset, Disable, Global Disable All & Rollback Countdown

    func testResetDisableAndGlobalDisableAllRecovery() async {
        let backend = MockUnderscanBackend()
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitorA = makeMonitor(id: 10, uuid: "A", serial: 1, location: "p0")
        let monitorB = makeMonitor(id: 20, uuid: "B", serial: 2, location: "p1")

        await coordinator.refreshDisplays([monitorA, monitorB])
        _ = await coordinator.applyPercentage(90, for: monitorA, among: [monitorA, monitorB])
        _ = await coordinator.applyPercentage(85, for: monitorB, among: [monitorA, monitorB])

        // Reset monitor A to 100%.
        _ = await coordinator.resetToFullScreen(for: monitorA, among: [monitorA, monitorB])
        XCTAssertEqual(coordinator.state(for: monitorA, among: [monitorA, monitorB]).requestedPercentage, 100)
        XCTAssertEqual(coordinator.state(for: monitorA, among: [monitorA, monitorB]).status, .resetToFullScreen)

        // Disable monitor B stops automatic restoration and resets hardware to 100%.
        await coordinator.disableUnderscan(for: monitorB, among: [monitorA, monitorB])
        XCTAssertFalse(coordinator.state(for: monitorB, among: [monitorA, monitorB]).settings.isEnabled)
        XCTAssertNil(coordinator.scheduleRestore(for: monitorB, among: [monitorA, monitorB], trigger: .wake))

        // Re-enable both then run global Disable All recovery.
        _ = await coordinator.applyPercentage(88, for: monitorA, among: [monitorA, monitorB])
        _ = await coordinator.applyPercentage(82, for: monitorB, among: [monitorA, monitorB])
        await coordinator.disableAllUnderscan(liveDisplays: [monitorA, monitorB])

        XCTAssertFalse(store.settings(forKey: "A").isEnabled)
        XCTAssertFalse(store.settings(forKey: "B").isEnabled)
        XCTAssertEqual(store.settings(forKey: "A").requestedPercentage, 100)
        XCTAssertEqual(store.settings(forKey: "B").requestedPercentage, 100)
        XCTAssertEqual(backend.hardwareRawByDisplayID[10], 10000)
        XCTAssertEqual(backend.hardwareRawByDisplayID[20], 10000)
    }

    func testExperimentalCountdownAutomaticallyRevertsIfNotConfirmed() async {
        let backend = MockUnderscanBackend(
            defaultAvailability: .unsupportedHardware(reason: "Unsupported")
        )
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: fastTiming, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        coordinator.updateSettings(for: monitor, among: [monitor]) { $0.forceEnableExperimental = true }
        coordinator.confirmExperimentalRisk(for: monitor, among: [monitor])

        _ = await coordinator.applyPercentage(90, for: monitor, among: [monitor], triggerRollbackIfExperimental: true)
        XCTAssertNotNil(coordinator.state(for: monitor, among: [monitor]).pendingRollback)

        // Wait past the 2 * 15ms test rollback timer.
        try? await Task.sleep(nanoseconds: 120_000_000)

        let afterRollback = coordinator.state(for: monitor, among: [monitor])
        XCTAssertNil(afterRollback.pendingRollback)
        XCTAssertEqual(afterRollback.requestedPercentage, 100)
        XCTAssertEqual(backend.appliedCalls.last?.rawValue, 10000)
    }

    func testExperimentalKeepCancelsRollbackAndPromotesKnownGoodValue() async {
        let backend = MockUnderscanBackend(
            defaultAvailability: .unsupportedHardware(reason: "Unsupported")
        )
        let timing = UnderscanTiming(
            sliderThrottleNs: 20_000_000,
            startupStabilizeNs: 15_000_000,
            wakeStabilizeNs: 15_000_000,
            reconnectStabilizeNs: 15_000_000,
            modeChangeStabilizeNs: 15_000_000,
            retryDelaysNs: [10_000_000],
            maxConsecutiveFailuresBeforeSuspend: 3,
            selfApplySuppressionSeconds: 0.25,
            rollbackTimeoutSeconds: 3,
            rollbackTickNs: 40_000_000
        )
        let coordinator = UnderscanCoordinator(backend: backend, store: store, timing: timing, isDisplayOnline: { _ in true })
        let monitor = makeMonitor()

        await coordinator.refreshDisplays([monitor])
        coordinator.updateSettings(for: monitor, among: [monitor]) { $0.forceEnableExperimental = true }
        coordinator.confirmExperimentalRisk(for: monitor, among: [monitor])

        _ = await coordinator.applyPercentage(90, for: monitor, among: [monitor], triggerRollbackIfExperimental: true)
        let key = coordinator.stableKey(for: monitor, among: [monitor])
        coordinator.keepExperimentalChange(forKey: key)

        try? await Task.sleep(nanoseconds: 180_000_000)

        let kept = coordinator.state(for: monitor, among: [monitor])
        XCTAssertNil(kept.pendingRollback)
        XCTAssertEqual(kept.requestedPercentage, 90)
        XCTAssertEqual(kept.settings.lastKnownGoodPercentage, 90)
        XCTAssertEqual(backend.appliedCalls.last?.rawValue, 9000)
    }
}

private final class OnlineFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool) { self.flag = value }
    var isOnline: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
