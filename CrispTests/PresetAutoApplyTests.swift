import XCTest

final class PresetAutoApplyTests: XCTestCase {
    private func preset(_ name: String, displays: [String]?, brightness: Double = 0.5) -> DisplayPreset {
        var preset = DisplayPreset(name: name, icon: "display", displays: [
            DisplayPresetEntry(displayUUID: name, brightness: brightness)
        ])
        preset.autoApplyDisplayUUIDs = displays
        return preset
    }

    func testLegacyPresetsRemainManual() throws {
        let json = Data("""
        {"id":"11111111-2222-3333-4444-555555555555","name":"Desk","icon":"display","displays":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: json)
        XCTAssertNil(decoded.autoApplyDisplayUUIDs)
        XCTAssertNil(PresetAutoApplyPolicy.match(in: [decoded], externalDisplays: ["A"]))
    }

    func testBindingRoundTripsWithoutChangingCapturedValues() throws {
        let original = preset("Office", displays: ["B", "A"], brightness: 0.8)
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.autoApplyDisplayUUIDs, ["B", "A"])
        XCTAssertEqual(decoded.displays.first?.brightness, 0.8)
    }

    func testOfficeHomeAndAdditionalSetupMatchByIdentity() {
        let office = preset("Office", displays: ["A", "B"])
        let home = preset("Home", displays: ["C"])
        let travel = preset("Travel", displays: ["D"])
        let presets = [office, home, travel]
        XCTAssertEqual(PresetAutoApplyPolicy.match(in: presets, externalDisplays: ["B", "A"])?.id, office.id)
        XCTAssertEqual(PresetAutoApplyPolicy.match(in: presets, externalDisplays: ["C"])?.id, home.id)
        XCTAssertEqual(PresetAutoApplyPolicy.match(in: presets, externalDisplays: ["D"])?.id, travel.id)
    }

    func testPartialUnknownMixedAndEmptySetupsDoNotApply() {
        let presets = [preset("Office", displays: ["A", "B"]), preset("Home", displays: ["C"])]
        let setups: [Set<String>] = [[], ["A"], ["X"], ["A", "B", "X"], ["A", "B", "C"]]
        for setup in setups {
            XCTAssertNil(PresetAutoApplyPolicy.match(in: presets, externalDisplays: setup))
        }
    }

    func testAnEmptyTriggerNeverMeansLaptopOnly() {
        XCTAssertNil(PresetAutoApplyPolicy.match(in: [preset("Empty", displays: [])], externalDisplays: []))
    }

    func testAmbiguousImportedBindingsDoNotDependOnOrder() {
        let first = preset("Day", displays: ["A", "B"])
        let second = preset("Night", displays: ["B", "A"])
        XCTAssertNil(PresetAutoApplyPolicy.match(in: [first, second], externalDisplays: ["A", "B"]))
        XCTAssertNil(PresetAutoApplyPolicy.match(in: [second, first], externalDisplays: ["A", "B"]))
    }

    func testChoosingAnotherDefaultOnlyReplacesTheSameSetup() {
        let day = preset("Day", displays: ["A", "B"])
        let night = preset("Night", displays: nil)
        let home = preset("Home", displays: ["C"])
        let updated = PresetAutoApplyPolicy.setting(night.id, in: [day, night, home], externalDisplays: ["B", "A"])
        XCTAssertNil(updated[0].autoApplyDisplayUUIDs)
        XCTAssertEqual(updated[1].autoApplyDisplayUUIDs, ["A", "B"])
        XCTAssertEqual(updated[2].autoApplyDisplayUUIDs, ["C"])
        XCTAssertEqual(updated[1].displays.first?.brightness, night.displays.first?.brightness)
    }

    func testDisablingKeepsOtherDefaultsAndSavedValues() {
        let office = preset("Office", displays: ["A"])
        let home = preset("Home", displays: ["B"])
        let updated = PresetAutoApplyPolicy.setting(office.id, in: [office, home], externalDisplays: nil)
        XCTAssertNil(updated[0].autoApplyDisplayUUIDs)
        XCTAssertEqual(updated[0].displays.first?.brightness, office.displays.first?.brightness)
        XCTAssertEqual(updated[1].autoApplyDisplayUUIDs, ["B"])
    }

    func testMissingTargetCannotDisableAnotherPreset() {
        let office = preset("Office", displays: ["A"])
        let updated = PresetAutoApplyPolicy.setting(UUID(), in: [office], externalDisplays: ["A"])
        XCTAssertEqual(updated[0].autoApplyDisplayUUIDs, ["A"])
    }

    func testUpdatesAndRenamesUseLatestValuesWithoutASeparateRegistry() {
        var office = preset("Office", displays: ["A"])
        office.name = "Work"
        office.displays[0].brightness = 0.7
        let selected = PresetAutoApplyPolicy.match(in: [office], externalDisplays: ["A"])
        XCTAssertEqual(selected?.name, "Work")
        XCTAssertEqual(selected?.displays.first?.brightness, 0.7)
    }

    func testDeletedPresetNoLongerMatches() {
        XCTAssertNil(PresetAutoApplyPolicy.match(in: [], externalDisplays: ["A"]))
    }

    func testValueRecaptureCanMoveBindingToANewDock() {
        let office = preset("Office", displays: ["A"])
        let updated = PresetAutoApplyPolicy.setting(office.id, in: [office], externalDisplays: ["B"])
        XCTAssertNil(PresetAutoApplyPolicy.match(in: updated, externalDisplays: ["A"]))
        XCTAssertEqual(PresetAutoApplyPolicy.match(in: updated, externalDisplays: ["B"])?.id, office.id)
    }

    func testSameTopologyDoesNotReapplyAfterResolutionOrManualBrightnessChanges() {
        var state = PresetAutoApplyState()
        XCTAssertTrue(state.observe(["A", "B"]))
        XCTAssertFalse(state.observe(["B", "A"]))
        XCTAssertFalse(state.observe(["A", "B"]))
    }

    func testUnplugReconnectAndWakeRequestAnotherEvaluation() {
        var state = PresetAutoApplyState()
        XCTAssertTrue(state.observe(["A"]))
        XCTAssertTrue(state.observe([]))
        XCTAssertTrue(state.observe(["A"]))
        XCTAssertTrue(state.observe(["A"], force: true))
        XCTAssertFalse(state.observe(["A"]))
    }
}
