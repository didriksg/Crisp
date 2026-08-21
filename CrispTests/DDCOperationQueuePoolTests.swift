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
}
