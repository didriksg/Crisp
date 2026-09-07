import XCTest

/// The capping rule from #112: an external display can only be behind a port that is
/// carrying something, so the count of externals is capped at the number of transport
/// nodes with hot-plug detect asserted.
final class PhantomPortCapTests: XCTestCase {
    private func cap(builtin: Int, external: Int, portCap: Int?) -> Int {
        PhantomPortCap.activeCount(offPort: builtin, onPort: external, portCap: portCap)
    }

    /// The state the rule exists for. After an undock while asleep CG reports the two
    /// absent externals as active with real 16-bit EDID, and no port carries them.
    func testPhantomsBehindDeadPortsAreNotCounted() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: 0), 0)
    }

    /// The same desk with the built-in still on is not a blackout, and the built-in is
    /// not on a port, so it survives the cap.
    func testBuiltinIsNeverCapped() {
        XCTAssertEqual(cap(builtin: 1, external: 2, portCap: 0), 1)
    }

    /// A DisplayLink desk: the dock's display keeps its product name while no port
    /// carries it, and the only transport node the machine exposes is its own empty HDMI
    /// port. Lid closed it is the only screen, lid open it sits beside the built-in;
    /// neither may read as dark. (offPort carries it, like the built-in.)
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

    /// The cap is an upper bound, never a floor: more live ports than displays is the
    /// normal state of a dock with a spare socket, and must not invent a display.
    func testMorePortsThanDisplaysDoesNotAdd() {
        XCTAssertEqual(cap(builtin: 0, external: 1, portCap: 3), 1)
        XCTAssertEqual(cap(builtin: 0, external: 0, portCap: 3), 0)
    }

    /// One of two cables gone: the remaining display still counts, so the desk is not
    /// treated as dark.
    func testPartialCapKeepsTheSurvivor() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: 1), 1)
    }

    /// nil means the machine exposes no transport nodes at all, i.e. the signal is not
    /// available rather than zero. Capping on that would black out a desk the rule has
    /// never seen, so it must pass everything through untouched.
    func testUnavailableSignalDoesNotCap() {
        XCTAssertEqual(cap(builtin: 0, external: 2, portCap: nil), 2)
        XCTAssertEqual(cap(builtin: 1, external: 2, portCap: nil), 3)
        XCTAssertEqual(cap(builtin: 0, external: 0, portCap: nil), 0)
    }
}
