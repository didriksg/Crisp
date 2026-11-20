import XCTest

final class KeepAwakeDurationTests: XCTestCase {
    func testSecondsAndOrder() {
        XCTAssertNil(KeepAwakeDuration.untilTurnedOff.seconds)
        XCTAssertEqual(KeepAwakeDuration.allCases.compactMap(\.seconds),
                       [900, 1800, 3600, 7200, 14400, 28800])
    }

    func testLabelsHaveNoZeroUnits() {
        XCTAssertFalse(KeepAwakeDuration.hour1.label.contains("0"))
        XCTAssertTrue(KeepAwakeDuration.minutes15.label.contains("15"))
    }
}
