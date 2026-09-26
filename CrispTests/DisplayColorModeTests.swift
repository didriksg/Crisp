import Foundation
import XCTest

final class DisplayColorModeTests: XCTestCase {
    private func mode(id: UInt64 = 1, width: Int = 2560, height: Int = 1440,
                      refresh: Double = 60, depth: Int = 10,
                      encoding: String = "RGBFullRange", hdr: String = "SDR") -> DisplayColorMode {
        DisplayColorMode(id: id, width: width, height: height, refreshRate: refresh,
                         bitDepth: depth, colorMode: encoding, hdrMode: hdr)
    }

    private func timing(width: Int = 2560, height: Int = 1440,
                        pixelWidth: Int = 5120, pixelHeight: Int = 2880,
                        refresh: Double = 60) -> DisplayTiming {
        DisplayTiming(width: width, height: height, pixelWidth: pixelWidth,
                      pixelHeight: pixelHeight, refreshRate: refresh)
    }

    func testSavedFormatMatchesReassignedIDAndCaseInsensitiveNames() {
        let saved = SavedColorMode(mode(), timing: timing())
        XCTAssertTrue(saved.matches(mode(id: 99, encoding: "rgbfullrange", hdr: "sdr")))
    }

    func testSavedFormatRejectsDifferentGeometryDepthEncodingAndHDR() {
        let saved = SavedColorMode(mode(), timing: timing())
        let incompatible = [mode(width: 1920), mode(height: 1080), mode(depth: 8),
                            mode(encoding: "RGBLimitedRange"), mode(hdr: "HDR10")]
        for candidate in incompatible {
            XCTAssertFalse(saved.matches(candidate), candidate.summary)
        }
    }

    func testPrivateRefreshRateMatchingHasTightTolerance() {
        let saved = SavedColorMode(mode(), timing: nil)
        XCTAssertTrue(saved.matches(mode(refresh: 60.019)))
        XCTAssertFalse(saved.matches(mode(refresh: 60.021)))
        XCTAssertFalse(saved.matches(mode(refresh: 59.94)))
        XCTAssertFalse(saved.matches(mode(refresh: 0)))
    }

    func testCompatibleTimingAllowsDifferentFormatsButPreservesGeometryAndHDR() {
        let current = mode()
        XCTAssertTrue(current.sameTiming(as: mode(id: 2, depth: 8, encoding: "YCbCr422LimitedRange", hdr: "sdr")))
        XCTAssertTrue(current.sameTiming(as: mode(refresh: 60.019)))
        XCTAssertFalse(current.sameTiming(as: mode(refresh: 60.021)))
        XCTAssertFalse(current.sameTiming(as: mode(width: 1920)))
        XCTAssertFalse(current.sameTiming(as: mode(height: 1080)))
        XCTAssertFalse(current.sameTiming(as: mode(hdr: "HDR10")))
    }

    func testPublicTimingMatchesFractionalRateAndDefaultRate() {
        XCTAssertTrue(timing().matches(timing(refresh: 59.94)))
        XCTAssertTrue(timing().matches(timing(refresh: 0)))
        XCTAssertTrue(timing(refresh: 0).matches(timing(refresh: 144)))
        XCTAssertFalse(timing().matches(timing(refresh: 59)))
        XCTAssertFalse(timing().matches(timing(refresh: 120)))
    }

    func testPublicTimingRequiresBothLogicalAndPixelGeometry() {
        let saved = timing()
        XCTAssertFalse(saved.matches(timing(width: 1920)))
        XCTAssertFalse(saved.matches(timing(height: 1080)))
        XCTAssertFalse(saved.matches(timing(pixelWidth: 2560)))
        XCTAssertFalse(saved.matches(timing(pixelHeight: 1440)))
    }

    func testSavedTimingRejectsMissingOrDifferentCurrentTiming() {
        let saved = SavedColorMode(mode(), timing: timing())
        XCTAssertTrue(saved.matchesCurrentTiming(timing(refresh: 59.94)))
        XCTAssertFalse(saved.matchesCurrentTiming(nil))
        XCTAssertFalse(saved.matchesCurrentTiming(timing(pixelWidth: 2560)))
    }

    func testSavedChoiceRoundTripsWithoutVolatileID() throws {
        let saved = SavedColorMode(mode(id: 123), timing: timing())
        let data = try JSONEncoder().encode(saved)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["id"])
        let decoded = try JSONDecoder().decode(SavedColorMode.self, from: data)
        XCTAssertTrue(decoded.matches(mode(id: 999)))
        XCTAssertTrue(decoded.matchesCurrentTiming(timing()))
        XCTAssertFalse(decoded.matchesCurrentTiming(timing(refresh: 120)))
    }

    func testExistingPreferencePayloadRemainsReadable() throws {
        let data = Data("""
        {"width":2560,"height":1440,"refreshRate":60,"bitDepth":10,
         "colorMode":"RGBFullRange","hdrMode":"SDR",
         "timing":{"width":2560,"height":1440,"pixelWidth":5120,"pixelHeight":2880,"refreshRate":60}}
        """.utf8)
        let decoded = try JSONDecoder().decode(SavedColorMode.self, from: data)
        XCTAssertTrue(decoded.matches(mode(id: 999)))
        XCTAssertTrue(decoded.matchesCurrentTiming(timing()))
    }

    func testLegacyChoiceWithoutTimingRemainsReadable() throws {
        let data = Data("""
        {"width":2560,"height":1440,"refreshRate":60,"bitDepth":10,
         "colorMode":"RGBFullRange","hdrMode":"SDR"}
        """.utf8)
        let decoded = try JSONDecoder().decode(SavedColorMode.self, from: data)
        XCTAssertTrue(decoded.matchesCurrentTiming(nil))
        XCTAssertTrue(decoded.matchesCurrentTiming(timing(refresh: 120)))
    }

    func testMalformedPreferenceFailsDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(SavedColorMode.self, from: Data("{}".utf8)))
    }

    func testEncodingLabelsRecognizeChromaSubsamplingRegardlessOfCase() {
        let encodings = [("YCbCr444FullRange", "YCbCr 4:4:4"),
                         ("ycbcr422limitedrange", "YCbCr 4:2:2"),
                         ("YCbCr420", "YCbCr 4:2:0"), ("YCbCr", "YCbCr"),
                         ("rgbFullRange", "RGB"), ("UnknownFormat", "UnknownFormat")]
        for (raw, label) in encodings {
            XCTAssertEqual(mode(encoding: raw).colorEncoding, label)
        }
    }

    func testRangeAndDetailLabels() {
        XCTAssertEqual(mode().rangeLabel, String(localized: "Full Range"))
        XCTAssertEqual(mode(encoding: "rgblimitedrange").rangeLabel, String(localized: "Limited Range"))
        XCTAssertNil(mode(encoding: "RGB").rangeLabel)
        XCTAssertEqual(mode(hdr: "").detailLabel, "RGB · \(String(localized: "Full Range"))")
        XCTAssertEqual(mode(encoding: "RGB", hdr: "HDR10").detailLabel, "HDR10 · RGB")
        XCTAssertEqual(mode(encoding: "", hdr: "").detailLabel, "")
    }

    func testSnapshotRequiresAnAlternativeID() {
        let current = mode()
        XCTAssertFalse(DisplayColorModeSnapshot(current: current, compatibleModes: []).canSet)
        XCTAssertFalse(DisplayColorModeSnapshot(current: current, compatibleModes: [current]).canSet)
        XCTAssertTrue(DisplayColorModeSnapshot(current: current, compatibleModes: [current, mode(id: 2)]).canSet)
    }
}
