import XCTest

final class DDCOperationGenerationTests: XCTestCase {
    func testNewRequestMakesOlderRequestStaleWithinSameTopology() {
        var generations = DDCOperationGeneration()
        let first = generations.nextRequest(for: 5)
        let second = generations.nextRequest(for: 5)

        XCTAssertTrue(generations.isCurrentTopology(first, for: 5))
        XCTAssertFalse(generations.isLatestRequest(first, for: 5))
        XCTAssertTrue(generations.isLatestRequest(second, for: 5))
    }

    func testInvalidationRejectsCompletionFromPreviousTopology() {
        var generations = DDCOperationGeneration()
        let beforeReconnect = generations.nextRequest(for: 5)

        generations.invalidate(displayID: 5)
        let afterReconnect = generations.nextRequest(for: 5)

        XCTAssertFalse(generations.isCurrentTopology(beforeReconnect, for: 5))
        XCTAssertFalse(generations.isLatestRequest(beforeReconnect, for: 5))
        XCTAssertTrue(generations.isLatestRequest(afterReconnect, for: 5))
    }
}
