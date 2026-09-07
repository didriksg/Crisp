import XCTest

/// Headless tests for the stops the brightness and volume keys move between.
///
/// `BrightnessKeySteps` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DisplayModeGeometry`), so no `@testable import Crisp` is
/// needed.
final class BrightnessKeyStepsTests: XCTestCase {

    /// A value already on a stop moves a whole step, not a hair.
    func testOnAStopMovesOneWholeStep() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 50, up: true), 56.25, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 50, up: false), 43.75, accuracy: 0.0001)
    }

    /// A value off the grid, which is where every display Crisp has never touched starts,
    /// lands on the next stop rather than carrying its offset along.
    /// Kills mutation: "add or subtract the step instead of snapping".
    func testOffTheGridSnapsToTheNextStop() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 79, up: true), 81.25, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 79, up: false), 75, accuracy: 0.0001)
    }

    /// A readback a hair off a stop (DDC and gamma both round) still moves a whole step,
    /// or holding the key would creep by fractions.
    func testNearlyOnAStopStillMovesAWholeStep() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 56.2499, up: true), 62.5, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 56.2501, up: false), 50, accuracy: 0.0001)
    }

    /// The grid carries on past 100 for displays with Extra Brightness; clamping to the
    /// display's own maximum belongs to the caller.
    func testGridContinuesAboveOneHundred() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 100, up: true), 106.25, accuracy: 0.0001)
    }

    /// Below zero is the caller's to clamp too, so the step itself keeps counting down.
    func testBelowZeroIsLeftToTheCaller() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 0, up: false), -6.25, accuracy: 0.0001)
    }
}
