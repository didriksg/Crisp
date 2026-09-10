import XCTest

final class NightShiftTemperatureControllerTests: XCTestCase {
    @MainActor
    func testRefreshFollowsSystemChangesWithoutWriting() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        await controller.refresh()
        XCTAssertEqual(controller.strength, Double(Float(0.3)))
        await backend.setSystemStrength(0.7)
        await controller.refresh()
        XCTAssertEqual(controller.strength, Double(Float(0.7)))
        let writes = await backend.writes
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor
    func testFailedReadClearsTheSnapshot() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        await controller.refresh()
        await backend.setSystemStrength(nil)
        await controller.refresh()
        XCTAssertNil(controller.strength)
        await backend.setSystemStrength(.nan)
        await controller.refresh()
        XCTAssertNil(controller.strength)
    }

    @MainActor
    func testFailedWriteRestoresActualSystemValue() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        await backend.rejectWrites()
        await controller.setStrength(0.9)
        XCTAssertEqual(controller.strength, Double(Float(0.3)))
    }

    @MainActor
    func testWritesClampToSystemRangeAndRejectNonFiniteValues() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        await controller.setStrength(-2)
        await controller.setStrength(4)
        await controller.setStrength(.nan)
        await controller.setStrength(.infinity)
        let writes = await backend.writes
        XCTAssertEqual(writes, [0, 1])
        XCTAssertEqual(controller.strength, 1)
    }

    @MainActor
    func testOldReadCannotUndoANewerWrite() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        await backend.blockNextRead()
        let oldRead = Task { await controller.refresh() }
        await waitUntil { await backend.hasBlockedRead }
        await controller.setStrength(0.8)
        await backend.releaseRead()
        await oldRead.value
        XCTAssertEqual(controller.strength, Double(Float(0.8)))
    }

    @MainActor
    func testDragIgnoresReadbackUntilEditingEnds() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        controller.setEditing(true)
        await controller.setStrength(0.8)
        await backend.setSystemStrength(0.5)
        await controller.refresh()
        XCTAssertEqual(controller.strength, Double(Float(0.8)))
        controller.setEditing(false)
        await controller.refresh()
        XCTAssertEqual(controller.strength, Double(Float(0.5)))
    }

    @MainActor
    func testSlowWriteCoalescesToLatestValueWithoutConcurrentWrites() async {
        let backend = TemperatureBackend()
        let controller = makeController(backend)
        await backend.blockNextWrite()
        let firstWrite = Task { await controller.setStrength(0.2) }
        await waitUntil { await backend.hasBlockedWrite }
        await controller.setStrength(0.4)
        await controller.setStrength(0.9)
        let pendingWrites = await backend.writes
        XCTAssertEqual(pendingWrites, [0.2])
        await backend.releaseWrite()
        await firstWrite.value
        let writes = await backend.writes
        XCTAssertEqual(writes, [0.2, 0.9])
        XCTAssertEqual(controller.strength, Double(Float(0.9)))
    }

    @MainActor
    private func makeController(_ backend: TemperatureBackend) -> NightShiftTemperatureController {
        NightShiftTemperatureController(read: { await backend.read() }, write: { await backend.write($0) })
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Backend did not reach the expected suspension point")
                return
            }
            await Task.yield()
        }
    }
}

private actor TemperatureBackend {
    private var systemStrength: Float? = 0.3
    private var shouldRejectWrites = false
    private var shouldBlockRead = false
    private var shouldBlockWrite = false
    private var blockedRead: CheckedContinuation<Void, Never>?
    private var blockedWrite: CheckedContinuation<Void, Never>?
    private(set) var writes: [Float] = []
    var hasBlockedRead: Bool { blockedRead != nil }
    var hasBlockedWrite: Bool { blockedWrite != nil }

    func setSystemStrength(_ value: Float?) { systemStrength = value }
    func rejectWrites() { shouldRejectWrites = true }
    func blockNextRead() { shouldBlockRead = true }
    func blockNextWrite() { shouldBlockWrite = true }

    func releaseRead() {
        blockedRead?.resume()
        blockedRead = nil
    }

    func releaseWrite() {
        blockedWrite?.resume()
        blockedWrite = nil
    }

    func read() async -> Float? {
        let snapshot = systemStrength
        if shouldBlockRead {
            shouldBlockRead = false
            await withCheckedContinuation { blockedRead = $0 }
        }
        return snapshot
    }

    func write(_ value: Float) async -> Bool {
        writes.append(value)
        if shouldBlockWrite {
            shouldBlockWrite = false
            await withCheckedContinuation { blockedWrite = $0 }
        }
        guard !shouldRejectWrites else { return false }
        systemStrength = value
        return true
    }
}
