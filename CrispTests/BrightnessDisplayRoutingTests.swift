import XCTest

/// Headless routing cases: a looks-like screen has a different ID from the
/// physical panel whose brightness must change.
final class BrightnessDisplayRoutingTests: XCTestCase {
    private let builtin = BrightnessDisplayRouting.Route(physicalID: 1, mirrorSourceID: nil)
    private let dell = BrightnessDisplayRouting.Route(physicalID: 2, mirrorSourceID: 200)

    func testNativeExternalScreenTargetsItsPhysicalPanel() {
        XCTAssertEqual(BrightnessDisplayRouting.physicalID(for: 2, routes: [builtin, dell]), 2)
    }

    func testScaledScreenTargetsDellRatherThanBuiltin() {
        XCTAssertEqual(BrightnessDisplayRouting.physicalID(for: 200, routes: [builtin, dell]), 2)
    }

    func testBuiltinScreenStillTargetsBuiltin() {
        XCTAssertEqual(BrightnessDisplayRouting.physicalID(for: 1, routes: [builtin, dell]), 1)
    }

    func testDisconnectedPanelDoesNotClaimItsOldVirtualScreen() {
        XCTAssertNil(BrightnessDisplayRouting.physicalID(for: 200, routes: [builtin]))
    }

    func testInactiveMirrorDoesNotClaimAnUnrelatedVirtualScreen() {
        let nativeDell = BrightnessDisplayRouting.Route(physicalID: 2, mirrorSourceID: nil)
        XCTAssertNil(BrightnessDisplayRouting.physicalID(for: 200, routes: [builtin, nativeDell]))
    }

    func testEachScaledExternalTargetsItsOwnPanel() {
        let other = BrightnessDisplayRouting.Route(physicalID: 3, mirrorSourceID: 300)
        XCTAssertEqual(BrightnessDisplayRouting.physicalID(for: 200, routes: [builtin, dell, other]), 2)
        XCTAssertEqual(BrightnessDisplayRouting.physicalID(for: 300, routes: [builtin, dell, other]), 3)
    }

    func testAmbiguousVirtualScreenDoesNotChooseAnArbitraryPanel() {
        let other = BrightnessDisplayRouting.Route(physicalID: 3, mirrorSourceID: 200)
        XCTAssertNil(BrightnessDisplayRouting.physicalID(for: 200, routes: [builtin, dell, other]))
    }

    func testDirectScreenMatchWinsOverMirrorAssociation() {
        let mirrored = BrightnessDisplayRouting.Route(physicalID: 3, mirrorSourceID: 1)
        XCTAssertEqual(BrightnessDisplayRouting.physicalID(for: 1, routes: [builtin, mirrored]), 1)
    }
}
