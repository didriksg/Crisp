import XCTest

final class PresetResolutionRoutingTests: XCTestCase {
    func testBeyondCapHiDPIPresetBeatsSameSizePhysicalLoDPI() {
        let route = PresetResolutionRouter.route(
            width: 3840, height: 1080, isHiDPI: true,
            candidates: [
                .init(width: 3840, height: 1080, isHiDPI: false),
                .init(width: 3360, height: 945, isHiDPI: true)
            ],
            beyondCapStops: [.init(width: 3840, height: 1080)]
        )
        XCTAssertEqual(route, .mirror)
    }

    func testEnumeratedHiDPIPresetUsesPhysicalMode() {
        let route = PresetResolutionRouter.route(
            width: 2560, height: 1440, isHiDPI: true,
            candidates: [
                .init(width: 2560, height: 1440, isHiDPI: false),
                .init(width: 2560, height: 1440, isHiDPI: true)
            ],
            beyondCapStops: []
        )
        XCTAssertEqual(route, .physical(index: 1))
    }
}
