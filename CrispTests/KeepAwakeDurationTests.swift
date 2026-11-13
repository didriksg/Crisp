import XCTest

final class KeepAwakeDurationTests: XCTestCase {
    func testDurationSeconds() {
        XCTAssertNil(KeepAwakeDuration.indefinite.seconds)
        XCTAssertEqual(KeepAwakeDuration.minutes15.seconds, 900)
        XCTAssertEqual(KeepAwakeDuration.minutes30.seconds, 1800)
        XCTAssertEqual(KeepAwakeDuration.hour1.seconds, 3600)
        XCTAssertEqual(KeepAwakeDuration.hours2.seconds, 7200)
    }

    func testRemainingMinutesRoundsUpPositiveSecondsAndClampsZero() {
        XCTAssertEqual(KeepAwakeDuration.remainingMinutes(for: 3600), 60)
        XCTAssertEqual(KeepAwakeDuration.remainingMinutes(for: 3541), 60)
        XCTAssertEqual(KeepAwakeDuration.remainingMinutes(for: 3540), 59)
        XCTAssertEqual(KeepAwakeDuration.remainingMinutes(for: 0.1), 1)
        XCTAssertEqual(KeepAwakeDuration.remainingMinutes(for: 0), 0)
        XCTAssertEqual(KeepAwakeDuration.remainingMinutes(for: -5), 0)
    }

    func testToolsSubtitleReflectsActiveAndRemainingState() {
        XCTAssertNil(KeepAwakeDuration.toolsSubtitle(isActive: false, remainingMinutes: 30))
        let keepAwakeTitle = String(localized: "Keep Awake")
        XCTAssertEqual(KeepAwakeDuration.toolsSubtitle(isActive: true, remainingMinutes: nil), keepAwakeTitle)
        let timed = KeepAwakeDuration.toolsSubtitle(isActive: true, remainingMinutes: 42)
        XCTAssertNotNil(timed)
        XCTAssertTrue(timed?.contains(keepAwakeTitle) == true)
        XCTAssertTrue(timed?.contains("42") == true)
    }
}
