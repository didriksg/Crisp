import CoreGraphics
import XCTest

final class DisplayLayoutSnapshotTests: XCTestCase {
    private func display(_ id: CGDirectDisplayID, uuid: String, x: Int, y: Int = 0,
                         width: Int = 1512, height: Int = 982, rotation: Double = 0,
                         isMain: Bool = false) -> DisplayLayoutSnapshot.Display {
        .init(id: id, uuid: uuid, bounds: CGRect(x: x, y: y, width: width, height: height),
              rotation: rotation, isMain: isMain)
    }

    private var saved: DisplayLayoutSnapshot {
        DisplayLayoutSnapshot(displays: [
            display(1, uuid: "builtin", x: 0, isMain: true),
            display(2, uuid: "landscape", x: -1048, y: -1440, width: 2560, height: 1440),
            display(3, uuid: "portrait", x: 1512, y: -1440, width: 1179, height: 2096, rotation: 270)
        ])
    }

    func testRestoresWholeLayoutAfterStaggeredWakeUsingCurrentDisplayIDs() throws {
        let current = [
            display(10, uuid: "builtin", x: 0, isMain: true),
            display(30, uuid: "portrait", x: -1179, y: -1080, width: 1179, height: 2096, rotation: 270),
            display(20, uuid: "landscape", x: 0, y: -1440, width: 2560, height: 1440)
        ]
        let origins = try XCTUnwrap(saved.originsToRestore(in: current))
        XCTAssertEqual(origins.map(\.id), [10, 30, 20])
        XCTAssertEqual(origins.map(\.x), [0, 1512, -1048])
        XCTAssertEqual(origins.map(\.y), [0, -1440, -1440])
    }

    func testDoesNothingWhenLayoutAlreadyMatches() {
        XCTAssertNil(saved.originsToRestore(in: saved.displays))
    }

    func testWaitsForMissingMonitorRatherThanRearrangingSmallerSet() {
        XCTAssertNil(saved.originsToRestore(in: Array(saved.displays.prefix(2))))
    }

    func testDoesNotApplyAtAnotherDeskWithSameDisplayCount() {
        var current = saved.displays
        current[2] = display(3, uuid: "other-monitor", x: -1179, width: 1179, height: 2096, rotation: 270)
        XCTAssertNil(saved.originsToRestore(in: current))
    }

    func testWaitsForResolutionAndRotationToReturn() {
        var current = saved.displays
        current[2] = display(3, uuid: "portrait", x: -202, y: -1080, width: 1920, height: 1080)
        XCTAssertNil(saved.originsToRestore(in: current))
        current[2] = display(3, uuid: "portrait", x: -1179, width: 1179, height: 2096, rotation: 90)
        XCTAssertNil(saved.originsToRestore(in: current))
    }

    func testDoesNotUndoMainDisplayChange() {
        var current = saved.displays
        current[0] = display(1, uuid: "builtin", x: -1512)
        XCTAssertNil(saved.originsToRestore(in: current))
    }

    func testRejectsDuplicateDisplayIdentities() {
        let snapshot = DisplayLayoutSnapshot(displays: [saved.displays[0], saved.displays[0]])
        XCTAssertNil(snapshot.originsToRestore(in: snapshot.displays))
    }
}
