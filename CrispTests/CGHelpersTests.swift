import Foundation
import XCTest

final class CGHelpersTests: XCTestCase {
    func testStartedMandatoryOperationReportsCompletionAfterTimeout() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lateCompletion = DispatchSemaphore(value: 0)

        let task = Task {
            await CGHelpers.runMandatoryWithTimeout(
                seconds: 0.05,
                operation: {
                    started.signal()
                    release.wait()
                    return true
                },
                lateCompletion: { result in
                    if result { lateCompletion.signal() }
                })
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(nanoseconds: 80_000_000)
        if case .timedOut = await task.value {} else {
            XCTFail("started mandatory operation should time out for its caller")
        }

        release.signal()
        XCTAssertEqual(lateCompletion.wait(timeout: .now() + 1), .success)
    }

    func testTimedOutQueuedOperationIsSkippedWithoutOverlappingBlocker() async {
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let queuedBodyRan = DispatchSemaphore(value: 0)

        let blocker = Task {
            await CGHelpers.runWithTimeout(seconds: 0.05, fallback: false) {
                blockerStarted.signal()
                releaseBlocker.wait()
                return true
            }
        }
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        let queued = Task {
            await CGHelpers.runWithTimeout(seconds: 0.05, fallback: false) {
                queuedBodyRan.signal()
                return true
            }
        }
        let compensationRan = DispatchSemaphore(value: 0)
        let lateCompletionRan = DispatchSemaphore(value: 0)
        let compensation = Task {
            await CGHelpers.runMandatoryWithTimeout(
                seconds: 0.05,
                operation: {
                    compensationRan.signal()
                    return true
                },
                lateCompletion: { result in
                    if result { lateCompletionRan.signal() }
                })
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        let blockerResult = await blocker.value
        let queuedResult = await queued.value
        XCTAssertFalse(blockerResult)
        XCTAssertFalse(queuedResult)
        releaseBlocker.signal()

        // Mandatory cleanup times out for its caller while queued, but cannot be
        // skipped: once the blocker drains, it runs and reports the late result.
        let compensationResult = await compensation.value
        if case .timedOut = compensationResult {} else {
            XCTFail("mandatory queued operation should time out for its caller")
        }
        XCTAssertEqual(compensationRan.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(lateCompletionRan.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(queuedBodyRan.wait(timeout: .now()), .timedOut)
    }
}
