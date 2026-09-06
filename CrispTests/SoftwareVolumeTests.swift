import XCTest
import CoreAudio

final class SoftwareVolumeTests: XCTestCase {
    func testGainAndMuteBounds() {
        XCTAssertEqual(SoftwareVolumePolicy.gain(25), 0.25)
        XCTAssertEqual(SoftwareVolumePolicy.gain(-1), 0)
        XCTAssertEqual(SoftwareVolumePolicy.gain(200), 1)
        XCTAssertEqual(SoftwareVolumePolicy.gain(.nan), 0)
        XCTAssertEqual(SoftwareVolumePolicy.unmutedLevel(nil), 25)
        XCTAssertEqual(SoftwareVolumePolicy.unmutedLevel(40), 40)
        XCTAssertEqual(SoftwareVolumePolicy.unmutedLevel(0), 25)
    }

    func testRoutingRequiresUniqueCurrentDisplayAndActiveSession() {
        XCTAssertNil(SoftwareVolumePolicy.matchingDisplay(audioName: "Monitor", displayNames: ["Monitor", "Monitor"]))
        XCTAssertNil(SoftwareVolumePolicy.matchingDisplay(audioName: "Headphones", displayNames: ["Monitor"]))
        XCTAssertEqual(SoftwareVolumePolicy.matchingDisplay(audioName: "Monitor", displayNames: ["Other", "Monitor"]), 1)
        XCTAssertTrue(SoftwareVolumePolicy.usesSoftware(selectedID: 2, displayID: 2, active: true, routeMatches: true))
        XCTAssertFalse(SoftwareVolumePolicy.usesSoftware(selectedID: 2, displayID: 1, active: true, routeMatches: true))
        XCTAssertFalse(SoftwareVolumePolicy.usesSoftware(selectedID: 2, displayID: 2, active: false, routeMatches: true))
        XCTAssertFalse(SoftwareVolumePolicy.usesSoftware(selectedID: 2, displayID: 2, active: true, routeMatches: false))
    }

    func testActualCallbackGainMuteAndDisabledCleanup() {
        var samples: [Float] = [0.8, -0.4, 0, 0.2]
        var output = [Float](repeating: 9, count: 4)
        samples.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: 16, mData: inputBytes.baseAddress))
                var result = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: 16, mData: outputBytes.baseAddress))
                XCTAssertTrue(SoftwareVolumeProcessBuffers(&input, &result, false, false, 0.25, false))
                let values = outputBytes.bindMemory(to: Float.self)
                XCTAssertEqual(values[0], 0.2, accuracy: 0.00001)
                XCTAssertEqual(values[1], -0.1, accuracy: 0.00001)
                XCTAssertTrue(SoftwareVolumeProcessBuffers(&input, &result, false, false, 0, false))
                XCTAssertTrue(values.allSatisfy { $0 == 0 })
                // Disabled cleanup must ignore stale/missing input and erase all output.
                values[0] = 1
                XCTAssertTrue(SoftwareVolumeProcessBuffers(nil, &result, false, false, 1, true))
                XCTAssertTrue(values.allSatisfy { $0 == 0 })
                inputBytes.bindMemory(to: Float.self)[1] = .nan
                XCTAssertFalse(SoftwareVolumeProcessBuffers(&input, &result, false, false, 1, false))
                XCTAssertTrue(values.allSatisfy { $0 == 0 })
                input.mBuffers.mNumberChannels = 6
                XCTAssertFalse(SoftwareVolumeProcessBuffers(&input, &result, false, false, 1, false))
            }
        }
    }
}
