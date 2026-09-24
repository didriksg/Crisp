import XCTest

/// The capping rule from #112: an external can only be behind a port carrying something,
/// so externals are capped at the number of transport nodes with hot-plug detect asserted.
final class PhantomPortCapTests: XCTestCase {
    private func cap(builtin: Int, external: Int, portCap: Int?) -> Int {
        PhantomPortCap.activeCount(offPort: builtin, onPort: external, portCap: portCap)
    }

    /// The state the rule exists for: after an undock while asleep, absent externals still
    /// report real EDID and no port carries them.
    func testPhantomsBehindDeadPortsAreNotCounted() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: 0), 0)
    }

    /// The built-in survives the cap: it is never on a port, so it isn't a blackout.
    func testBuiltinIsNeverCapped() {
        XCTAssertEqual(cap(builtin: 1, external: 2, portCap: 0), 1)
    }

    /// A DisplayLink dock's display keeps its product name off-port; lid open or closed,
    /// it must not read as dark.
    func testNamedDisplayOffPortIsNeverCapped() {
        XCTAssertEqual(PhantomPortCap.activeCount(offPort: 1, onPort: 0, portCap: 0), 1)
        XCTAssertEqual(PhantomPortCap.activeCount(offPort: 2, onPort: 0, portCap: 0), 2)
        XCTAssertEqual(PhantomPortCap.activeCount(offPort: 1, onPort: 1, portCap: 0), 1)
    }

    /// An ordinary docked desk: the cap changes nothing.
    func testLiveDisplaysAreLeftAlone() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: 2), 2)
        XCTAssertEqual(cap(builtin: 1, external: 1, portCap: 2), 2)
    }

    /// The cap is an upper bound, never a floor: more live ports than displays must not
    /// invent a display.
    func testMorePortsThanDisplaysDoesNotAdd() {
        XCTAssertEqual(cap(builtin: 0, external: 1, portCap: 3), 1)
        XCTAssertEqual(cap(builtin: 0, external: 0, portCap: 3), 0)
    }

    /// One of two cables gone: the remaining display still counts.
    func testPartialCapKeepsTheSurvivor() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: 1), 1)
    }

    /// nil means the signal is unavailable, not zero plugged in; capping on it would black
    /// out desks this rule has never seen.
    func testUnavailableSignalDoesNotCap() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: nil), 2)
        XCTAssertEqual(cap(builtin: 1, external: 2, portCap: nil), 3)
        XCTAssertEqual(cap(builtin: 0, external: 0, portCap: nil), 0)
    }
}
