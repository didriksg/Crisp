import XCTest

/// Headless tests for the VRR duplicate-pair detector (issue #31).
///
/// `VariableRefreshModes` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DisplayModeGeometry`). The fixtures mirror the mode tables
/// observed on real hardware: an AOC Q27G3XMN VRR panel (duplicate usable pairs per
/// rate, variable twin first, fixed native twin flagged safe|default) and a DELL
/// U2412M / built-in ProMotion panel (no usable duplicate pairs at all).
final class VariableRefreshModesTests: XCTestCase {

    private func record(_ id: Int32, _ w: Int, _ h: Int, freq: Int, density: Float = 1.0,
                        flags: UInt32 = 0x1) -> VRRModeRecord {
        VRRModeRecord(id: id, width: w, height: h, freq: freq, density: density, flags: flags)
    }

    /// The native 180Hz pair from the AOC: fixed twin carries safe|default (0x7),
    /// so the flag rule picks the other member regardless of ordering.
    func testDefaultFlaggedTwinIsFixed() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(680, 2560, 1440, freq: 180, flags: 0x0200_0001),
            record(681, 2560, 1440, freq: 180, flags: 0x0200_0007),
        ])
        XCTAssertEqual(ids, [680])
    }

    /// Flags beat enumeration order: if the default-flagged (fixed) twin enumerates
    /// FIRST, the variable one is still the unflagged member, not the lower id.
    func testFlagRuleBeatsOrderRule() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(680, 2560, 1440, freq: 180, flags: 0x0200_0007),
            record(681, 2560, 1440, freq: 180, flags: 0x0200_0001),
        ])
        XCTAssertEqual(ids, [681])
    }

    /// Scaled pairs are flag-identical (0x1/0x1); the variable twin is the lower id
    /// (verified live: 386 variable / 387 fixed, 727 variable / 728 fixed).
    func testFlagIdenticalPairFallsBackToLowerID() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(387, 1920, 1080, freq: 180),
            record(386, 1920, 1080, freq: 180),
        ])
        XCTAssertEqual(ids, [386])
    }

    /// Same size and rate at different densities is NOT a pair: a 2560x1440@60 1x mode
    /// and a 2560x1440@60 HiDPI mode are different resolutions to the user.
    func testDifferentDensityIsNotAPair() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(686, 2560, 1440, freq: 60, density: 1.0),
            record(727, 2560, 1440, freq: 60, density: 2.0),
        ])
        XCTAssertEqual(ids, [])
    }

    /// Unusable (0x40000000-flagged) modes never form pairs: the AOC lists many
    /// byte-identical hidden encoding variants that must not trigger detection.
    func testUnusableModesAreIgnored() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(731, 400, 300, freq: 180, density: 2.0, flags: 0x4000_0000),
            record(732, 400, 300, freq: 180, density: 2.0, flags: 0x4000_0000),
        ])
        XCTAssertEqual(ids, [])
    }

    /// Singletons (every rate on a fixed-rate panel) produce nothing: the DELL U2412M
    /// and built-in ProMotion tables have zero usable duplicates.
    func testFixedRatePanelProducesNothing() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(1, 1920, 1200, freq: 60),
            record(2, 1920, 1200, freq: 50),
            record(3, 1600, 1200, freq: 60),
        ])
        XCTAssertEqual(ids, [])
    }

    /// Three-or-more identical usable modes were never observed on hardware; the
    /// detector classifies nothing there rather than guessing.
    func testTripleGroupIsSkipped() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(1, 800, 600, freq: 120),
            record(2, 800, 600, freq: 120),
            record(3, 800, 600, freq: 120),
        ])
        XCTAssertEqual(ids, [])
    }

    /// Multiple pairs across rates each resolve independently (the AOC pairs every
    /// rate inside its 48-180 adaptive range).
    func testEveryRatePairResolvesIndependently() {
        let ids = VariableRefreshModes.variableModeIDs(from: [
            record(680, 2560, 1440, freq: 180, flags: 0x0200_0001),
            record(681, 2560, 1440, freq: 180, flags: 0x0200_0007),
            record(727, 2560, 1440, freq: 60, density: 2.0),
            record(728, 2560, 1440, freq: 60, density: 2.0),
        ])
        XCTAssertEqual(ids, [680, 727])
    }

    func testEmptyInputProducesNothing() {
        XCTAssertEqual(VariableRefreshModes.variableModeIDs(from: []), [])
    }
}
