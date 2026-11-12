import XCTest

/// `DisplayRotation` compiles directly into this test target (no app host).
final class DisplayRotationTests: XCTestCase {
    func testReadingsMapToTheFourRotations() {
        XCTAssertEqual(DisplayRotation(degrees: 0), .standard)
        XCTAssertEqual(DisplayRotation(degrees: 90), .quarter)
        XCTAssertEqual(DisplayRotation(degrees: 180), .half)
        XCTAssertEqual(DisplayRotation(degrees: 270), .threeQuarter)
        XCTAssertEqual(DisplayRotation(degrees: 89.99), .quarter)
        XCTAssertEqual(DisplayRotation(degrees: 360), .standard)
        XCTAssertEqual(DisplayRotation(degrees: -90), .threeQuarter)
    }
}
