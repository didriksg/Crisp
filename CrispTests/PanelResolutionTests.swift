import XCTest

final class PanelResolutionTests: XCTestCase {
    func testManualOverrideWinsEveryAutomaticSource() {
        let result = PanelResolutionResolver.resolve(
            manual: .init(width: 5120, height: 1440),
            edid: .init(width: 3840, height: 2160),
            registry: .init(width: 2560, height: 1440),
            unscaledModes: [.init(width: 1024, height: 768)],
            currentPixels: .init(width: 720, height: 480)
        )
        XCTAssertEqual(result, .init(resolution: .init(width: 5120, height: 1440), source: .manual))
    }

    func testEDIDWinsIncorrectFallbackMode() {
        let result = PanelResolutionResolver.resolve(
            manual: nil,
            edid: .init(width: 3840, height: 2160),
            registry: nil,
            unscaledModes: [.init(width: 1024, height: 768), .init(width: 720, height: 480)],
            currentPixels: .init(width: 720, height: 480)
        )
        XCTAssertEqual(result.resolution, .init(width: 3840, height: 2160))
        XCTAssertEqual(result.source, .edid)
    }

    func testRegistryNativeFormatIsUsedWhenRawEDIDIsUnavailable() {
        let result = PanelResolutionResolver.resolve(
            manual: nil, edid: nil,
            registry: .init(width: 3840, height: 2160),
            unscaledModes: [.init(width: 1024, height: 768)],
            currentPixels: .init(width: 720, height: 480)
        )
        XCTAssertEqual(result.resolution, .init(width: 3840, height: 2160))
        XCTAssertEqual(result.source, .registry)
    }

    func testBaseDetailedTimingParses4KPreferredResolution() {
        XCTAssertEqual(
            EDIDParser.preferredResolution(from: makeEDID(basePreferred: (3840, 2160))),
            .init(width: 3840, height: 2160)
        )
    }

    func testCTANative4KTimingWinsSmallerBasePreferredTiming() {
        XCTAssertEqual(
            EDIDParser.preferredResolution(from: makeEDID(
                basePreferred: (1920, 1080), nativeVIC: 97
            )),
            .init(width: 3840, height: 2160)
        )
    }

    func testCTA720pHighRefreshVICDoesNotPromotePanelTo1080p() {
        for vic: UInt8 in [41, 47] {
            XCTAssertEqual(
                EDIDParser.preferredResolution(from: makeEDID(
                    basePreferred: (1280, 720), nativeVIC: vic
                )),
                .init(width: 1280, height: 720),
                "CTA VIC \(vic) should retain 720p active dimensions"
            )
        }
    }

    func testInvalidEDIDChecksumIsRejected() {
        var bytes = [UInt8](makeEDID(basePreferred: (3840, 2160)))
        bytes[20] ^= 0xff
        XCTAssertNil(EDIDParser.preferredResolution(from: Data(bytes)))
    }

    func testUnreadableEDIDDoesNotEraseEarlierValidResult() {
        var evidence = PanelResolutionEvidence()
        evidence.recordEDID(makeEDID(basePreferred: (3840, 2160)))
        evidence.recordEDID(Data(repeating: 0, count: 128))
        XCTAssertEqual(evidence.edid, .init(width: 3840, height: 2160))
    }

    func test4KLadderContainsPreferredStopsAndHonors6720BackingCap() {
        let sizes = SmoothScalingGeometry.logicalSizes(
            nativeWidth: 3840, nativeHeight: 2160, maximumBackingWidth: 6720)
        XCTAssertTrue(sizes.contains(.init(width: 2880, height: 1620)))
        XCTAssertTrue(sizes.contains(.init(width: 2560, height: 1440)))
        XCTAssertEqual(sizes.first, .init(width: 3360, height: 1890))
        XCTAssertEqual(sizes.last, .init(width: 1920, height: 1080))
        XCTAssertTrue(sizes.allSatisfy { $0.width * 2 <= 6720 })
        XCTAssertTrue(sizes.allSatisfy { abs(Double($0.width) / Double($0.height) - 16.0 / 9.0) < 0.002 })
    }

    func testUncappedUltrawideLadderRetainsMirrorOnlyStops() {
        let sizes = SmoothScalingGeometry.logicalSizes(nativeWidth: 5120, nativeHeight: 1440)
        let beyondCap = sizes.filter { $0.width > 3360 && $0.width < 5120 }
        XCTAssertEqual(beyondCap.count, 109)
        XCTAssertEqual(beyondCap.first, .init(width: 5104, height: 1436))
        XCTAssertEqual(beyondCap.last, .init(width: 3376, height: 950))
    }

    func testVeryWideMirrorGridIsWindowedBelowModeObjectCeiling() {
        let stops = stride(from: 7184, through: 3360, by: -16).map {
            PanelResolution(width: $0, height: Int((Double($0) * 2160 / 7680).rounded()))
        }
        let required = PanelResolution(width: 5600, height: 1575)
        let bounded = MirrorModeGeometry.boundedStops(
            stops, including: required, maximumCount: 190)

        XCTAssertEqual(stops.count, 240)
        XCTAssertEqual(bounded.count, 190)
        XCTAssertTrue(bounded.contains(required))
        XCTAssertLessThanOrEqual(bounded.count * 2, 380)
    }

    func testMirrorGridForceIncludesRequestedOffGridStop() {
        let stops = (0..<240).map {
            PanelResolution(width: 7184 - $0 * 16, height: 2021 - $0 * 4)
        }
        let required = PanelResolution(width: 6001, height: 1688)
        let bounded = MirrorModeGeometry.boundedStops(
            stops, including: required, maximumCount: 190)

        XCTAssertEqual(bounded.count, 190)
        XCTAssertTrue(bounded.contains(required))
        XCTAssertTrue(bounded.contains(.init(width: 6016, height: 1729)))
        XCTAssertTrue(bounded.contains(.init(width: 6000, height: 1725)))
    }

    func testMirrorGridCentersNumericallyEvenWhenCandidatesAreUnordered() {
        let stops = (0..<240).map {
            PanelResolution(width: 7184 - $0 * 16, height: 2021 - $0 * 4)
        }
        let required = stops[120]
        let bounded = MirrorModeGeometry.boundedStops(
            Array(stops.reversed()), including: required, maximumCount: 190)

        XCTAssertEqual(bounded.first, stops[25])
        XCTAssertEqual(bounded.last, stops[214])
        XCTAssertEqual(bounded[95], required)
    }

    func testMirrorGridClampsWindowAtNumericEnds() {
        let stops = (0..<240).map {
            PanelResolution(width: 7184 - $0 * 16, height: 2021 - $0 * 4)
        }

        let upper = MirrorModeGeometry.boundedStops(
            stops, including: stops[0], maximumCount: 190)
        let lower = MirrorModeGeometry.boundedStops(
            stops, including: stops[239], maximumCount: 190)

        XCTAssertEqual(upper, Array(stops[0..<190]))
        XCTAssertEqual(lower, Array(stops[50..<240]))
    }

    private func makeEDID(basePreferred: (Int, Int), nativeVIC: UInt8? = nil) -> Data {
        var base = [UInt8](repeating: 0, count: 128)
        base[0..<8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]
        base[18] = 1
        base[19] = 4
        base[24] = 0x02
        encodeDetailedTiming(basePreferred, into: &base, at: 54)
        base[126] = nativeVIC == nil ? 0 : 1
        setChecksum(&base)

        guard let nativeVIC else { return Data(base) }
        var cta = [UInt8](repeating: 0, count: 128)
        cta[0] = 0x02
        cta[1] = 0x03
        cta[2] = 6
        cta[4] = 0x41
        cta[5] = nativeVIC | 0x80
        setChecksum(&cta)
        return Data(base + cta)
    }

    private func encodeDetailedTiming(_ resolution: (Int, Int), into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = 1
        bytes[offset + 1] = 1
        bytes[offset + 2] = UInt8(resolution.0 & 0xff)
        bytes[offset + 4] = UInt8((resolution.0 >> 8) << 4)
        bytes[offset + 5] = UInt8(resolution.1 & 0xff)
        bytes[offset + 7] = UInt8((resolution.1 >> 8) << 4)
    }

    private func setChecksum(_ bytes: inout [UInt8]) {
        bytes[127] = UInt8((256 - bytes[0..<127].reduce(0, { $0 + Int($1) }) % 256) % 256)
    }
}
