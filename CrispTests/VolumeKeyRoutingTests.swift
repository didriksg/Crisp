import XCTest

/// Headless tests for which displays the volume keys drive. `VolumeKeyRouting`
/// compiles directly into this test target, so no `@testable import Crisp` is needed.
final class VolumeKeyRoutingTests: XCTestCase {

    private let left = VolumeKeyRouting.Candidate(name: "LG HDR 4K (1)", uuid: "LEFT")
    private let right = VolumeKeyRouting.Candidate(name: "LG HDR 4K (2)", uuid: "RIGHT")
    private let dell = VolumeKeyRouting.Candidate(name: "DELL U2723QE", uuid: "DELL")

    /// DisplayPort audio: no volume of its own, so macOS can't step it.
    private func display(_ name: String?) -> VolumeKeyRouting.Output {
        .init(name: name, isDisplayAudio: true, hasSystemVolume: false)
    }

    /// The Mac's own speakers: macOS steps these itself.
    private let speakers = VolumeKeyRouting.Output(
        name: "MacBook Pro Speakers", isDisplayAudio: false, hasSystemVolume: true)

    /// A Multi-Output Device spanning both monitors: no system volume either.
    private let multiOutput = VolumeKeyRouting.Output(
        name: "Multi-Output Device", isDisplayAudio: false, hasSystemVolume: false)

    private func targets(
        _ output: VolumeKeyRouting.Output, _ candidates: [VolumeKeyRouting.Candidate],
        _ target: VolumeKeyTarget = .audioOutput, selected: Set<String> = []
    ) -> [Int] {
        VolumeKeyRouting.targets(
            output: output, candidates: candidates, target: target, selectedUUIDs: selected)
    }

    // MARK: - Following the audio output (default)

    /// The IORegistry tie picks one of two identical monitors (#276).
    func testRegistryTieBeatsTheName() {
        var output = display("LG HDR 4K")
        output.displayUUID = "RIGHT"
        XCTAssertEqual(targets(output, [left, right]), [1])
    }

    /// A tie to a display that isn't a candidate (no DDC volume) is ignored.
    func testRegistryTieToANonCandidateFallsBackToTheName() {
        var output = display("LG HDR 4K")
        output.displayUUID = "BUILTIN"
        XCTAssertEqual(targets(output, [left, right]), [0, 1])
    }

    /// An exact name match picks that display alone.
    func testExactNameMatchWins() {
        XCTAssertEqual(targets(display("DELL U2723QE"), [left, dell]), [1])
    }

    /// Two identical monitors: the audio device has no " (n)" suffix, so both
    /// match and both are driven (#276).
    func testSameModelMonitorsAreAllDriven() {
        XCTAssertEqual(targets(display("LG HDR 4K"), [left, right]), [0, 1])
    }

    /// The lone-candidate fallback still needs display audio.
    func testSingleCandidateFallback() {
        XCTAssertEqual(targets(display("Some HDMI Device"), [dell]), [0])
        XCTAssertEqual(targets(speakers, [dell]), [])
    }

    /// Another output, or none, passes the keys through.
    func testUnrelatedOutputPassesThrough() {
        XCTAssertEqual(targets(speakers, [left, right]), [])
        XCTAssertEqual(targets(display(nil), [left, right]), [])
    }

    // MARK: - Selected displays

    func testSelectedDrivesOnlyTheSelection() {
        XCTAssertEqual(targets(display("LG HDR 4K"), [left, right], .selected, selected: ["LEFT"]), [0])
        XCTAssertEqual(targets(display("DELL U2723QE"), [left, dell], .selected, selected: ["LEFT"]), [0])
    }

    /// A Multi-Output Device matches no display by name; selecting both covers it.
    func testSelectionCoversAMultiOutputDevice() {
        XCTAssertEqual(targets(multiOutput, [left, dell]), [])
        XCTAssertEqual(targets(multiOutput, [left, dell], .selected, selected: ["LEFT", "DELL"]), [0, 1])
    }

    /// None of the selection attached: follow the audio output, so the press
    /// still does something.
    func testEmptySelectionFallsBackToTheAudioOutput() {
        XCTAssertEqual(targets(display("DELL U2723QE"), [left, dell], .selected, selected: ["GONE"]), [1])
        XCTAssertEqual(targets(display("LG HDR 4K"), [left, right], .selected), [0, 1])
    }

    /// The selection never takes the keys from an output macOS controls itself.
    func testSelectionLeavesSystemVolumeOutputsAlone() {
        XCTAssertEqual(targets(speakers, [left, right], .selected, selected: ["LEFT"]), [])
    }

    // MARK: - Names

    /// Framebuffer and audio driver paths share their display coprocessor.
    func testDisplayControllerFromRegistryPaths() {
        let display = "IOService:/AppleARMPE/arm-io@10F00000/AppleT600xIO/dispext1@8B000000/AppleCLCD2"
        let audio = "IOService:/AppleARMPE/arm-io@10F00000/AppleT600xIO/dcpext1@8CC00000/AppleDCPExpert"
            + "/RTBuddy(DCPEXT1)/dispext1:dcpav-audio-interface-epic:0/DCPAVAudioInterfaceProxy"
            + "/DCPAVAudioDriver(iop-dcpext1-nub)"
        XCTAssertEqual(VolumeKeyRouting.displayController(inRegistryPath: display), "dispext1")
        XCTAssertEqual(VolumeKeyRouting.displayController(inRegistryPath: audio), "dispext1")
        XCTAssertEqual(VolumeKeyRouting.displayController(inRegistryPath: "IOService:/x/disp0@8A000000/AppleCLCD2"), "disp0")
        XCTAssertNil(VolumeKeyRouting.displayController(inRegistryPath: "IOService:/x/DisplayPort/y"))
    }

    /// Only the trailing " (n)" macOS adds is dropped.
    func testBaseNameDropsOnlyTheTrailingCounter() {
        XCTAssertEqual(VolumeKeyRouting.baseName("LG HDR 4K (2)"), "LG HDR 4K")
        XCTAssertEqual(VolumeKeyRouting.baseName("LG HDR 4K"), "LG HDR 4K")
        XCTAssertEqual(VolumeKeyRouting.baseName("Studio (Display) (12)"), "Studio (Display)")
        XCTAssertEqual(VolumeKeyRouting.baseName("Monitor (A)"), "Monitor (A)")
    }
}
