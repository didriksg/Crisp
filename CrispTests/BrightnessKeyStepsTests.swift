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

    func testFinePressMovesOneSixthOfANormalStep() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 50, up: true, fine: true), 51.0416667, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 50, up: false, fine: true), 48.9583333, accuracy: 0.0001)
    }

    func testSixFinePressesReachTheNextNormalStop() {
        for up in [true, false] {
            var target = 50.0
            for _ in 0..<6 {
                target = BrightnessKeySteps.next(from: target, up: up, fine: true)
            }
            XCTAssertEqual(target, up ? 56.25 : 43.75, accuracy: 0.0001)
        }
    }

    func testRoundedDDCReadbackDoesNotRepeatThePreviousFineTarget() {
        // 51.0417% is read back as 51%; stepping up must reach 52.0833%,
        // not re-send 51.0417% and leave the physical monitor at 51%.
        XCTAssertEqual(BrightnessKeySteps.next(from: 51, up: true, fine: true), 52.0833333, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 52, up: false, fine: true), 51.0416667, accuracy: 0.0001)
    }

    func testFineStepsTraverseTheWholeRangeWithIntegerReadbacks() {
        for up in [true, false] {
            var readback = up ? 0.0 : 100.0
            for _ in 0..<96 {
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

    func testFinePressStartsFromTheNearestSubstepOffGrid() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 79, up: true, fine: true), 80.2083333, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 79, up: false, fine: true), 78.125, accuracy: 0.0001)
    }

    func testDisablingFineStepsReturnsToTheNormalGrid() {
        let fineTarget = BrightnessKeySteps.next(from: 50, up: true, fine: true)
        XCTAssertEqual(BrightnessKeySteps.next(from: fineTarget, up: true), 56.25, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: fineTarget, up: false), 50, accuracy: 0.0001)
    }

    func testFineStepsPreserveBoostHeadroomAndLeaveClampingToTheCaller() {
        XCTAssertEqual(BrightnessKeySteps.next(from: 100, up: true, fine: true), 101.0416667, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 150, up: true, fine: true), 151.0416667, accuracy: 0.0001)
        XCTAssertEqual(BrightnessKeySteps.next(from: 0, up: false, fine: true), -1.0416667, accuracy: 0.0001)
    }
}
