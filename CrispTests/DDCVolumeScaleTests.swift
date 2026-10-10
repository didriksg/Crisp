import XCTest

/// Headless tests for the DDC volume scale mapping. `DDCVolumeScale` compiles
/// directly into this test target, so no `@testable import Crisp` is needed.
final class DDCVolumeScaleTests: XCTestCase {

    // MARK: - Effective maximum

    /// No ceiling keeps the hardware maximum.
    func testNoCeilingKeepsTheHardwareMaximum() {
        XCTAssertEqual(DDCVolumeScale.effectiveMax(hardwareMax: 100, ceiling: nil), 100)
        XCTAssertEqual(DDCVolumeScale.effectiveMax(hardwareMax: 30, ceiling: nil), 30)
    }

    /// The ceiling caps the scale; one above the hardware max cannot raise it.
    func testCeilingCapsAndNeverRaises() {
        XCTAssertEqual(DDCVolumeScale.effectiveMax(hardwareMax: 100, ceiling: 25), 25)
        XCTAssertEqual(DDCVolumeScale.effectiveMax(hardwareMax: 30, ceiling: 100), 30)
    }

    /// A corrupt stored zero cannot collapse the scale to mute.
    func testZeroCeilingFallsBackToOne() {
        XCTAssertEqual(DDCVolumeScale.effectiveMax(hardwareMax: 100, ceiling: 0), 1)
    }

    // MARK: - Raw writes

    /// Percent maps linearly onto the scale and rounds.
    func testRawWriteOnACappedScale() {
        XCTAssertEqual(DDCVolumeScale.raw(fromPercent: 0, effectiveMax: 25), 0)
        XCTAssertEqual(DDCVolumeScale.raw(fromPercent: 100, effectiveMax: 25), 25)
        XCTAssertEqual(DDCVolumeScale.raw(fromPercent: 50, effectiveMax: 25), 13)  // 12.5 rounds up
        XCTAssertEqual(DDCVolumeScale.raw(fromPercent: 25, effectiveMax: 100), 25)
    }

    /// Out-of-range percentages clamp to the scale.
    func testRawWriteClamps() {
        XCTAssertEqual(DDCVolumeScale.raw(fromPercent: -5, effectiveMax: 100), 0)
        XCTAssertEqual(DDCVolumeScale.raw(fromPercent: 150, effectiveMax: 100), 100)
    }

    /// The sixteen key stops spread over a capped scale move one or two raw
    /// values a press where the uncapped 100-value scale gave six.
    func testKeyStopsStepFinelyOnACappedScale() {
        var previous = DDCVolumeScale.raw(fromPercent: 0, effectiveMax: 25)
        for stop in 1...16 {
            let raw = DDCVolumeScale.raw(fromPercent: Double(stop) / 16.0 * 100.0, effectiveMax: 25)
            XCTAssertGreaterThan(raw, previous)
            XCTAssertLessThanOrEqual(raw - previous, 2)
            previous = raw
        }
        XCTAssertEqual(previous, 25)
    }

    // MARK: - Readbacks

    /// Raw reads come back as a percentage of the scale.
    func testPercentFromRaw() {
        XCTAssertEqual(DDCVolumeScale.percent(fromRaw: 13, effectiveMax: 25), 52, accuracy: 0.001)
        XCTAssertEqual(DDCVolumeScale.percent(fromRaw: 0, effectiveMax: 25), 0)
        XCTAssertEqual(DDCVolumeScale.percent(fromRaw: 100, effectiveMax: 100), 100)
    }

    /// A level above the scale's top (a ceiling lowered under the monitor's
    /// current volume) reads as full.
    func testReadbackAboveTheCeilingReadsFull() {
        XCTAssertEqual(DDCVolumeScale.percent(fromRaw: 60, effectiveMax: 25), 100)
    }

    // MARK: - User ceilings

    func testClampedCeiling() {
        XCTAssertEqual(DDCVolumeScale.clampedCeiling(0, hardwareMax: 100), 1)
        XCTAssertEqual(DDCVolumeScale.clampedCeiling(25, hardwareMax: 100), 25)
        XCTAssertEqual(DDCVolumeScale.clampedCeiling(200, hardwareMax: 100), 100)
    }
}
