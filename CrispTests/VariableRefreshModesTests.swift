import XCTest

/// Headless tests for the VRR duplicate-pair detector (#31). `VariableRefreshModes`
/// compiles directly into this test target. Fixtures mirror real hardware: a VRR panel
/// with duplicate usable pairs per rate, and a fixed-rate panel with none.
final class VariableRefreshModesTests: XCTestCase {

    private func record(_ id: Int32, _ w: Int, _ h: Int, freq: Int, density: Float = 1.0,
                        flags: UInt32 = 0x1) -> VRRModeRecord {
        VRRModeRecord(id: id, width: w, height: h, freq: freq, density: density, flags: flags)
    }

    /// The fixed twin carries safe|default (0x7); the flag rule picks the other member.
    func testDefaultFlaggedTwinIsFixed() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(680, 2560, 1440, freq: 180, flags: 0x0200_0001),
            record(681, 2560, 1440, freq: 180, flags: 0x0200_0007)
        ])
        XCTAssertEqual(ids, [680])
    }

    /// Flags beat enumeration order: the unflagged member is variable regardless of which enumerates first.
    func testFlagRuleBeatsOrderRule() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(680, 2560, 1440, freq: 180, flags: 0x0200_0007),
            record(681, 2560, 1440, freq: 180, flags: 0x0200_0001)
        ])
        XCTAssertEqual(ids, [681])
    }

    /// Flag-identical scaled pairs fall back to the lower id as the variable twin.
    func testFlagIdenticalPairFallsBackToLowerID() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(387, 1920, 1080, freq: 180),
            record(386, 1920, 1080, freq: 180)
        ])
        XCTAssertEqual(ids, [386])
    }

    /// Same size and rate at different densities is not a pair: different resolutions to the user.
    func testDifferentDensityIsNotAPair() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(686, 2560, 1440, freq: 60, density: 1.0),
            record(727, 2560, 1440, freq: 60, density: 2.0)
        ])
        XCTAssertEqual(ids, [])
    }

    /// Unusable (0x40000000-flagged) modes never form pairs.
    func testUnusableModesAreIgnored() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(731, 400, 300, freq: 180, density: 2.0, flags: 0x4000_0000),
            record(732, 400, 300, freq: 180, density: 2.0, flags: 0x4000_0000)
        ])
        XCTAssertEqual(ids, [])
    }

    /// A fixed-rate panel's table has zero usable duplicates.
    func testFixedRatePanelProducesNothing() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(1, 1920, 1200, freq: 60),
            record(2, 1920, 1200, freq: 50),
            record(3, 1600, 1200, freq: 60)
        ])
        XCTAssertEqual(ids, [])
    }

    /// Three or more identical usable modes: classify nothing rather than guess.
    func testTripleGroupIsSkipped() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(1, 800, 600, freq: 120),
            record(2, 800, 600, freq: 120),
            record(3, 800, 600, freq: 120)
        ])
        XCTAssertEqual(ids, [])
    }

    /// Multiple pairs across rates each resolve independently.
    func testEveryRatePairResolvesIndependently() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(680, 2560, 1440, freq: 180, flags: 0x0200_0001),
            record(681, 2560, 1440, freq: 180, flags: 0x0200_0007),
            record(727, 2560, 1440, freq: 60, density: 2.0),
            record(728, 2560, 1440, freq: 60, density: 2.0)
        ])
        XCTAssertEqual(ids, [680, 727])
    }

    func testEmptyInputProducesNothing() {
        XCTAssertEqual(VariableRefreshModes.variableModeIDs(from: []), [])
    }
}
