import XCTest

final class DDCOperationQueuePoolTests: XCTestCase {
    func testBlockedDisplayDoesNotDelayAnotherDisplay() {
        let pool = DDCOperationQueuePool()
        let blockedStarted = DispatchSemaphore(value: 0)
        let releaseBlocked = DispatchSemaphore(value: 0)
        let otherFinished = DispatchSemaphore(value: 0)

        pool.queue(for: 2).async {
            blockedStarted.signal()
            releaseBlocked.wait()
        }
        XCTAssertEqual(blockedStarted.wait(timeout: .now() + 1), .success)

        pool.queue(for: 5).async { otherFinished.signal() }
        XCTAssertEqual(otherFinished.wait(timeout: .now() + 0.5), .success)
        releaseBlocked.signal()
    }

    func testOperationsForOneDisplayRemainSerial() {
        let pool = DDCOperationQueuePool()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)

        pool.queue(for: 2).async {
            firstStarted.signal()
            releaseFirst.wait()
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)

        pool.queue(for: 2).async { secondStarted.signal() }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
    }

    func testHoldParksEveryDisplayUntilReleased() {
        let pool = DDCOperationQueuePool()
        let idle = DispatchSemaphore(value: 0)
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        _ = pool.queue(for: 2)
        _ = pool.queue(for: 5)

        let release = pool.hold(timeout: 5) { idle.signal() }
        XCTAssertEqual(idle.wait(timeout: .now() + 1), .success)

        pool.queue(for: 2).async { first.signal() }
        pool.queue(for: 5).async { second.signal() }
        XCTAssertEqual(first.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertEqual(second.wait(timeout: .now() + 0.1), .timedOut)

        release()
        XCTAssertEqual(first.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(second.wait(timeout: .now() + 1), .success)
    }

    /// A display whose first operation arrives mid-hold must wait like the rest:
    /// WindowServer's enable is what the hold is protecting, and a fresh queue
    /// would otherwise put I2C back on the bus during the transaction.
    func testDisplayFirstSeenDuringHoldIsHeldToo() {
        let pool = DDCOperationQueuePool()
        let idle = DispatchSemaphore(value: 0)
        let newcomer = DispatchSemaphore(value: 0)

        let release = pool.hold(timeout: 5) { idle.signal() }
        XCTAssertEqual(idle.wait(timeout: .now() + 1), .success)

        pool.queue(for: 7).async { newcomer.signal() }
        XCTAssertEqual(newcomer.wait(timeout: .now() + 0.1), .timedOut)

        release()
        XCTAssertEqual(newcomer.wait(timeout: .now() + 1), .success)
    }

    /// Two overlapping holds: each release only frees the queues it parked, so the
    /// second hold still holds the bus after the first one lets go.
    func testOverlappingHoldsReleaseIndependently() {
        let pool = DDCOperationQueuePool()
        let firstIdle = DispatchSemaphore(value: 0)
        let secondIdle = DispatchSemaphore(value: 0)
        let ran = DispatchSemaphore(value: 0)
        _ = pool.queue(for: 2)

        let releaseFirst = pool.hold(timeout: 5) { firstIdle.signal() }
        XCTAssertEqual(firstIdle.wait(timeout: .now() + 1), .success)
        let releaseSecond = pool.hold(timeout: 5) { secondIdle.signal() }

        pool.queue(for: 2).async { ran.signal() }
        releaseFirst()
        XCTAssertEqual(ran.wait(timeout: .now() + 0.1), .timedOut)

        releaseSecond()
        XCTAssertEqual(secondIdle.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(ran.wait(timeout: .now() + 1), .success)
    }
}
