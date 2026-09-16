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

    /// Option+Shift moves a quarter of a stop, the grid macOS gives the built-in.
    func testFinePressMovesAQuarterOfAStop() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 50, up: true, fine: true), 51.5625, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 50, up: false, fine: true), 48.4375, accuracy: 0.0001)
    }

    /// Four fine presses land on the next whole stop, so the two grids stay in step.
    func testFourFinePressesReachTheNextStop() {
        for up in [true, false] {
            var target = 50.0
            for _ in 0..<4 { target = BrightnessKeySteps.next(from: target, up: up, fine: true) }
            XCTAssertEqual(target, up ? 56.25 : 43.75, accuracy: 0.0001)
        }
    }

    /// DDC and gamma read back whole percent, so a fine press counts from the nearest
    /// quarter: 51.5625 read back as 52 must go on to 53.125, not re-send 51.5625.
    func testRoundedReadbackStillAdvancesAFineStep() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 52, up: true, fine: true), 53.125, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 52, up: false, fine: true), 50, accuracy: 0.0001)
    }

    /// Held down across the whole range against whole-percent readbacks, every press
    /// still moves, and the quarters end exactly on 100 and 0.
    func testFineStepsCrossTheRangeWithRoundedReadbacks() {
        for up in [true, false] {
            var readback = up ? 0.0 : 100.0
            for _ in 0..<64 {
                let next = BrightnessKeySteps.next(from: readback, up: up, fine: true).rounded()
                if up {
                    XCTAssertGreaterThan(next, readback)
                } else {
                    XCTAssertLessThan(next, readback)
                }
                readback = next
            }
            XCTAssertEqual(readback, up ? 100 : 0)
        }
    }
}
