import XCTest

final class CombinedBrightnessMathTests: XCTestCase {
    func testCombinedValueMapsToReferenceNits() {
        XCTAssertEqual(
            CombinedBrightnessMath.targetNits(combined: 50, referenceMaxNits: 400),
            200,
            accuracy: 0.001
        )
    }

    func testExternalUsesItsOwnAbsoluteLuminanceRange() {
        XCTAssertEqual(
            CombinedBrightnessMath.targetBrightness(
                combined: 50,
                maxBrightness: 100,
                displayMaxNits: 300,
                referenceMaxNits: 400
            ),
            66.667,
            accuracy: 0.001
        )
    }

    func testExternalValueConvertsBackToReferenceScale() {
        XCTAssertEqual(
            CombinedBrightnessMath.controlValue(
                brightness: 66.667,
                maxBrightness: 100,
                displayMaxNits: 300,
                referenceMaxNits: 400
            ),
            50,
            accuracy: 0.001
        )
    }

    func testLowExternalRangeAccountsForStackedDDCAndGammaDimming() {
        let brightness = CombinedBrightnessMath.targetBrightness(
            combined: 2,
            maxBrightness: 100,
            displayMaxNits: 400,
            referenceMaxNits: 400
        )
        XCTAssertEqual(brightness, sqrt(30), accuracy: 0.001)
        XCTAssertEqual(
            CombinedBrightnessMath.controlValue(
                brightness: brightness,
                maxBrightness: 100,
                displayMaxNits: 400,
                referenceMaxNits: 400
            ),
            2,
            accuracy: 0.001
        )
    }

    func testBuiltinUsesLinearNitsInsteadOfNativeSliderPercent() {
        XCTAssertEqual(
            CombinedBrightnessMath.builtinLinearTarget(
                combined: 50,
                referenceMaxNits: 400,
                builtinMaxNits: 600,
                adjustment: 1
            ),
            1.0 / 3.0,
            accuracy: 0.001
        )
    }

    func testBuiltinFineTuningScalesAbsoluteTarget() {
        XCTAssertEqual(
            CombinedBrightnessMath.builtinLinearTarget(
                combined: 50,
                referenceMaxNits: 400,
                builtinMaxNits: 600,
                adjustment: 0.75
            ),
            0.25,
            accuracy: 0.001
        )
    }

    func testAbsoluteAutoBrightnessInvertsCombinedMapping() {
        XCTAssertEqual(
            CombinedBrightnessMath.externalBrightnessMatchingBuiltin(
                builtinLinear: 1.0 / 3.0,
                builtinMaxNits: 600,
                externalMaxNits: 400,
                builtinAdjustment: 1
            ),
            50,
            accuracy: 0.001
        )
    }

    func testMissingMetadataFallsBackToProportionalMapping() {
        XCTAssertEqual(
            CombinedBrightnessMath.targetBrightness(
                combined: 50,
                maxBrightness: 160,
                displayMaxNits: nil,
                referenceMaxNits: nil
            ),
            80,
            accuracy: 0.001
        )
    }
}
