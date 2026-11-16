import XCTest

/// Headless tests for the preset Connection capture (#211).
final class DisplayPresetConnectionTests: XCTestCase {

    /// Presets saved before the capture existed must not start connecting or disconnecting.
    func testLegacyPresetJSONDoesNotIncludeConnection() throws {
        let legacy = Data("""
        {"id":"11111111-2222-3333-4444-555555555555","name":"Work","icon":"display",
         "displays":[{"id":"99999999-8888-7777-6666-555555555555",
         "displayUUID":"ABC","brightness":0.65}]}
        """.utf8)
        let preset = try JSONDecoder().decode(DisplayPreset.self, from: legacy)
        XCTAssertFalse(preset.includes(.connection))
        XCTAssertEqual(preset.connectionPlan(online: ["ABC"], disconnected: []), .init())
    }

    /// Off is a stored value, so the preset includes the capture and keeps it through a save.
    func testOffRoundTripsAsIncluded() throws {
        let preset = DisplayPreset(name: "Desk", icon: "desktopcomputer", displays: [
            DisplayPresetEntry(displayUUID: "BUILTIN", connected: false),
            DisplayPresetEntry(displayUUID: "EXT", connected: true)
        ])
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertTrue(decoded.includes(.connection))
        XCTAssertEqual(decoded.displays.map(\.connected), [false, true])
    }

    func testClearDropsTheStoredState() {
        var entry = DisplayPresetEntry(displayUUID: "BUILTIN", connected: false)
        entry.clear(.connection)
        XCTAssertNil(entry.connected)
    }

    /// Only what differs from now changes; a display that is not attached is left alone.
    func testPlanChangesOnlyWhatDiffers() {
        let preset = DisplayPreset(name: "Desk", icon: "desktopcomputer", displays: [
            DisplayPresetEntry(displayUUID: "BUILTIN", connected: false),   // on now: disconnect
            DisplayPresetEntry(displayUUID: "DELL", connected: true),       // off now: reconnect
            DisplayPresetEntry(displayUUID: "AOC", connected: true),        // on already
            DisplayPresetEntry(displayUUID: "HP", connected: false),        // off already
            DisplayPresetEntry(displayUUID: "TV", connected: true),         // not attached
            DisplayPresetEntry(displayUUID: "NONE")                         // not included
        ])
        let plan = preset.connectionPlan(online: ["BUILTIN", "AOC", "NONE"], disconnected: ["DELL", "HP"])
        XCTAssertEqual(plan.reconnect, ["DELL"])
        XCTAssertEqual(plan.disconnect, ["BUILTIN"])
    }

    func testVirtualPresetSwapAndRepeatedApplication() {
        let target = "0000EEEE-1111-2222-3333-444400000000"
        let previous = "0000EEEE-5555-6666-7777-888800000000"
        let preset = DisplayPreset(name: "Virtual", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: target, connected: true),
            DisplayPresetEntry(displayUUID: previous, connected: false)
        ])
        let plan = preset.connectionPlan(online: [previous], disconnected: [target])
        XCTAssertEqual(plan.reconnect, [target])
        XCTAssertEqual(plan.disconnect, [previous])
        XCTAssertEqual(preset.connectionPlan(online: [target], disconnected: [previous]), .init())
    }

    func testConnectionPlanMatchesLegacyVirtualUUIDSuffixes() {
        let target = "0000EEEE-1111-2222-3333-444400000000"
        let previous = "0000EEEE-5555-6666-7777-888800000000"
        let preset = DisplayPreset(name: "Virtual", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: "0000EEEE-1111-2222-3333-4444003F0041", connected: true),
            DisplayPresetEntry(displayUUID: "0000EEEE-5555-6666-7777-888800400042", connected: false)
        ])
        let plan = preset.connectionPlan(
            online: ["0000EEEE-5555-6666-7777-888800410043"], disconnected: [target]
        )
        XCTAssertEqual(plan.reconnect, [target])
        XCTAssertEqual(plan.disconnect, [previous])
        XCTAssertEqual(
            preset.connectionPlan(online: ["0000EEEE-1111-2222-3333-444400420044"], disconnected: [previous]),
            .init()
        )
    }
}
