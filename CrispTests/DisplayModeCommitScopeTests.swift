import CoreGraphics
import XCTest

final class DisplayModeCommitScopeTests: XCTestCase {
    func testPhysicalDisplaySelectionPersistsAcrossLoginSessions() {
        XCTAssertEqual(DisplayModeCommitScope.forUserSelection(isVirtualDisplay: false), .permanently)
    }

    func testVirtualDisplaySelectionRemainsSessionScoped() {
        XCTAssertEqual(DisplayModeCommitScope.forUserSelection(isVirtualDisplay: true), .forSession)
    }
}
