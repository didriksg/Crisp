import XCTest

/// The reporter's #259 shapes: a MacBook under a larger external, and side by side.
final class ArrangementSnapTests: XCTestCase {
    private let big = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let laptopWidth: CGFloat = 1512
    private let laptopHeight: CGFloat = 982
    private let edge: CGFloat = 200   // the 10 canvas point edge leeway at the desk's scale
    private let center: CGFloat = 80  // the 4 canvas point center leeway

    private func snap(_ rect: CGRect, _ others: [CGRect]) -> ArrangementSnap.Result {
        ArrangementSnap.snapped(rect, others: others, edgeThreshold: edge, centerThreshold: center)
    }

    func testStackedNearCenterLinesUpHorizontalCenters() {
        let below = CGRect(x: 560, y: 1440, width: laptopWidth, height: laptopHeight)
        let result = snap(below, [big])
        XCTAssertEqual(result.rect.midX, big.midX)
        XCTAssertEqual(result.rect.minY, big.maxY)
        XCTAssertEqual(result.centerGuide, ArrangementSnap.Guide(
            from: CGPoint(x: 1280, y: 0), to: CGPoint(x: 1280, y: 1440 + laptopHeight)))
    }

    func testSideBySideNearCenterLinesUpVerticalCenters() {
        let left = CGRect(x: -laptopWidth, y: 260, width: laptopWidth, height: laptopHeight)
        let result = snap(left, [big])
        XCTAssertEqual(result.rect.midY, big.midY)
        XCTAssertEqual(result.rect.maxX, big.minX)
        XCTAssertEqual(result.centerGuide, ArrangementSnap.Guide(
            from: CGPoint(x: -laptopWidth, y: 720), to: CGPoint(x: 2560, y: 720)))
    }

    /// Between the edge and center zones the display stays where it was dropped.
    func testOutsideBothLeewaysStaysPut() {
        let below = CGRect(x: 350, y: 1440, width: laptopWidth, height: laptopHeight)
        let result = snap(below, [big])
        XCTAssertEqual(result.rect, below)
        XCTAssertNil(result.centerGuide)
    }

    /// Edge alignment still works near an edge, with no guide.
    func testNearEdgeAlignsEdgeWithoutGuide() {
        let below = CGRect(x: 50, y: 1440, width: laptopWidth, height: laptopHeight)
        let result = snap(below, [big])
        XCTAssertEqual(result.rect.minX, 0)
        XCTAssertNil(result.centerGuide)
    }

    /// Same size: the edges and centers line up at once, and the guide shows it.
    func testEqualSizeShowsGuide() {
        let below = CGRect(x: 30, y: 1440, width: 2560, height: 1440)
        let result = snap(below, [big])
        XCTAssertEqual(result.rect.minX, 0)
        XCTAssertNotNil(result.centerGuide)
    }

    /// The #259 stack: external, MacBook centered under it, 1600x900 virtual display under that.
    func testThreeStackCentersTheBottomDisplayOnTheMiddleOne() {
        let middle = CGRect(x: 524, y: 1440, width: laptopWidth, height: laptopHeight)
        let virtual = CGRect(x: 470, y: 1440 + laptopHeight, width: 1600, height: 900)
        let result = snap(virtual, [big, middle])
        XCTAssertEqual(result.rect.midX, middle.midX)
        XCTAssertEqual(result.rect.minY, middle.maxY)
        XCTAssertNotNil(result.centerGuide)
    }

    /// A center alignment that would slide into a third display is dropped.
    func testCenterThatWouldOverlapAnotherDisplayIsDropped() {
        let left = CGRect(x: 0, y: 1440, width: 550, height: 600)
        let below = CGRect(x: 600, y: 1440, width: laptopWidth, height: laptopHeight)
        let result = snap(below, [big, left])
        XCTAssertNil(result.centerGuide)
        XCTAssertEqual(result.rect, below)
    }
}
