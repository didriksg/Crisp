import XCTest
import CoreGraphics

/// `DDCTopologyChange` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DDCServiceMatcher`), so no `@testable import Crisp` is needed.

final class DDCTopologyChangeTests: XCTestCase {
    private let aoc = "1050/12345/0/IOService:/AppleARMPE/dcp0"
    private let dell = "4268/16843/9911/IOService:/AppleARMPE/dcp1"

    func testUnchangedChannelsAreLeftAlone() {
        let map: [CGDirectDisplayID: String] = [1: aoc, 2: dell]
        XCTAssertTrue(DDCTopologyChange.changedChannels(previous: map, current: map).isEmpty)
    }

    /// The regression this exists for: display 2 replugs while display 1 has a write in
    /// flight. Only 2 may be invalidated, or 1's pending target is dropped mid-drag.
    func testOnlyTheRepluggedDisplayIsInvalidated() {
        let previous: [CGDirectDisplayID: String] = [1: aoc, 2: dell]
        let current: [CGDirectDisplayID: String] = [1: aoc, 3: dell]
        XCTAssertEqual(
            DDCTopologyChange.changedChannels(previous: previous, current: current),
            [2, 3]
        )
    }

    /// Two identical monitors differ only by location, so a swap must catch both.
    func testIdenticalMonitorsSwappingIDsAreBothInvalidated() {
        let first = "1050/12345/0/IOService:/AppleARMPE/dcp0"
        let second = "1050/12345/0/IOService:/AppleARMPE/dcp1"
        let previous: [CGDirectDisplayID: String] = [1: first, 2: second]
        let current: [CGDirectDisplayID: String] = [1: second, 2: first]
        XCTAssertEqual(
            DDCTopologyChange.changedChannels(previous: previous, current: current),
            [1, 2]
        )
    }

    /// A rearrangement in System Settings is a .movedFlag with no identity change.
    func testRearrangingDisplaysInvalidatesNothing() {
        let previous: [CGDirectDisplayID: String] = [1: aoc, 2: dell]
        XCTAssertTrue(
            DDCTopologyChange.changedChannels(previous: previous, current: previous).isEmpty
        )
    }

    func testFirstRefreshInvalidatesEveryKnownDisplay() {
        let current: [CGDirectDisplayID: String] = [1: aoc, 2: dell]
        XCTAssertEqual(
            DDCTopologyChange.changedChannels(previous: [:], current: current),
            [1, 2]
        )
    }
}
