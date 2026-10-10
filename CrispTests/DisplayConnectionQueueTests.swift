import XCTest

/// Two screens and a disconnect shaped like the real one: the last-screen guard, then a
/// wait (the DDC hold), then the change.
@MainActor
private final class Desk {
    var screens = 2

    func disconnect() async -> Bool {
        guard screens > 1 else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
        screens -= 1
        return true
    }
}

@MainActor
final class DisplayConnectionQueueTests: XCTestCase {
    func testOverlappingDisconnectsCannotTurnOffTheLastScreen() async {
        let queue = DisplayConnectionQueue()
        let desk = Desk()
        let first = Task { await queue.run { await desk.disconnect() } }
        let second = Task { await queue.run { await desk.disconnect() } }
        let results = [await first.value, await second.value]
        XCTAssertEqual(desk.screens, 1)
        XCTAssertEqual(results.filter { $0 }.count, 1)
    }
}
