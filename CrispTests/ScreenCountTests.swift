import XCTest

/// One test per desk shape measured so far. A new field report about a screen counted
/// wrongly adds a case here before it changes ScreenCount.
final class ScreenCountTests: XCTestCase {
    private func entry(_ id: UInt32, builtin: Bool = false, virtual: Bool = false,
                       vendor: UInt32 = 0x05E3, model: UInt32 = 0x2730) -> ScreenCount.Entry {
        ScreenCount.Entry(id: id, isCrispVirtual: virtual, isBuiltin: builtin, vendor: vendor, model: model)
    }

    private let builtin = ScreenCount.Entry(id: 1, isCrispVirtual: false, isBuiltin: true, vendor: 0x0610, model: 0xA049)
    private let live = ScreenCount.PortNode(hpd: "High", sinkCount: 1)
    private let emptyHDMI = ScreenCount.PortNode(hpd: "Unknown", sinkCount: 0)
    private let emptyCC = ScreenCount.PortNode(hpd: nil, sinkCount: 0)

    private func count(_ entries: [ScreenCount.Entry], portCap: Int?, named: Set<UInt32> = []) -> Int {
        ScreenCount.phantomAwareCount(entries, portCap: portCap) { named.contains($0) }
    }

    // MARK: - EDID shape

    /// The placeholder macOS spawns once the last real display is gone.
    func testPlaceholderIsNotAScreen() {
        XCTAssertTrue(ScreenCount.viewable([entry(9, vendor: 0x756E6B6E, model: 0x76697274)]).isEmpty)
    }

    /// #91: a re-enabled record whose hardware is gone lands online and active as 0/0.
    func testZeroZeroStubIsNotAScreen() {
        XCTAssertTrue(ScreenCount.viewable([entry(2, vendor: 0, model: 0)]).isEmpty)
    }

    /// #238: an aigo portable monitor reports a real vendor and product code 0.
    func testModelZeroMonitorIsAScreen() {
        XCTAssertEqual(ScreenCount.viewable([builtin, entry(2, vendor: 0x6318, model: 0)]).count, 2)
    }

    func testCrispVirtualDisplayIsNotAScreen() {
        XCTAssertEqual(ScreenCount.viewable([builtin, entry(3, virtual: true, vendor: 0xEEEE)]).map(\.id), [1])
    }

    // MARK: - Ports

    /// #195: an empty MacBook Air keeps only its USB-C CC nodes, which count as present.
    func testEmptyUSBCPortsArePresentButNotLive() {
        XCTAssertEqual(ScreenCount.portCap([emptyCC, emptyCC]), 0)
    }

    /// No port nodes at all means the signal is unavailable, not zero plugged in.
    func testNoPortNodesIsNoSignal() {
        XCTAssertNil(ScreenCount.portCap([]))
    }

    /// Either signal alone is enough: measured hpd Low with sink 1 right after an enable, and
    /// hpd High with sink 0 during a wake.
    func testEitherHotPlugOrSinkMarksAPortLive() {
        XCTAssertEqual(ScreenCount.portCap([ScreenCount.PortNode(hpd: "Low", sinkCount: 1)]), 1)
        XCTAssertEqual(ScreenCount.portCap([ScreenCount.PortNode(hpd: "High", sinkCount: 0)]), 1)
        XCTAssertEqual(ScreenCount.portCap([live, emptyHDMI]), 1)
    }

    // MARK: - Blackout rescue count

    /// #112: after an undock while asleep, absent externals come back at wake with real EDID
    /// and no name, and no port carries them.
    func testPhantomsBehindDeadPortsAreNotCounted() {
        XCTAssertEqual(count([entry(2), entry(3)], portCap: 0), 0)
    }

    /// The built-in is never on a port, so the cap never takes it.
    func testBuiltinIsNeverCapped() {
        XCTAssertEqual(count([builtin, entry(2), entry(3)], portCap: 0), 1)
    }

    /// #133: a DisplayLink display has no port node of its own but keeps its product name;
    /// lid open or closed, it must not read as dark.
    func testNamedDisplayLinkDisplayIsNotCapped() {
        XCTAssertEqual(count([entry(4)], portCap: 0, named: [4]), 1)
        XCTAssertEqual(count([builtin, entry(4)], portCap: 0, named: [4]), 2)
        XCTAssertEqual(count([entry(2), entry(4)], portCap: 0, named: [4]), 1)
    }

    /// A real display mid re-enumeration has no name for a moment; with its port live the
    /// name is never asked, so it still counts.
    func testNamelessDisplayOnALivePortCounts() {
        XCTAssertEqual(ScreenCount.phantomAwareCount([entry(2)], portCap: 1, hasProductName: nameNeverAsked), 1)
    }

    /// An ordinary docked desk: the cap changes nothing, and no name is read.
    func testLiveDisplaysAreLeftAlone() {
        XCTAssertEqual(ScreenCount.phantomAwareCount([entry(2), entry(3)], portCap: 2, hasProductName: nameNeverAsked), 2)
        XCTAssertEqual(ScreenCount.phantomAwareCount([builtin, entry(2)], portCap: 2, hasProductName: nameNeverAsked), 2)
    }

    /// The name read costs 2.5 to 8 ms per display, so it runs only when the cap is below the
    /// externals lit.
    private func nameNeverAsked(_ id: UInt32) -> Bool {
        XCTFail("product name read for display \(id) with the port cap not below the externals")
        return false
    }

    /// More live ports than displays must not invent a display.
    func testMorePortsThanDisplaysDoesNotAdd() {
        XCTAssertEqual(count([entry(2)], portCap: 3), 1)
        XCTAssertEqual(count([], portCap: 3), 0)
    }

    /// One of two cables gone: the remaining display still counts.
    func testPartialCapKeepsTheSurvivor() {
        XCTAssertEqual(count([entry(2), entry(3)], portCap: 1), 1)
    }

    /// With no port signal the cap is skipped, so a phantom is counted. Before #195 an empty
    /// Air read this way; it is the accepted cost of never capping on an unseen desk.
    func testUnavailablePortSignalDoesNotCap() {
        XCTAssertEqual(count([entry(2), entry(3)], portCap: nil), 2)
        XCTAssertEqual(count([builtin, entry(2), entry(3)], portCap: nil), 3)
        XCTAssertEqual(count([], portCap: nil), 0)
    }

    /// The shape filter runs before the cap: a #91 stub next to a lit built-in is not counted.
    func testStubIsFilteredBeforeTheCap() {
        XCTAssertEqual(count([builtin, entry(2, vendor: 0, model: 0)], portCap: nil), 1)
    }
}
