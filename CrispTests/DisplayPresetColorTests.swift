import XCTest

/// Headless tests for the preset color capture (#226).
final class DisplayPresetColorTests: XCTestCase {

    /// Presets saved before the capture existed must not start changing the color.
    func testLegacyPresetJSONDoesNotIncludeColor() throws {
        let legacy = Data("""
        {"id":"11111111-2222-3333-4444-555555555555","name":"Work","icon":"display",
         "displays":[{"id":"99999999-8888-7777-6666-555555555555",
         "displayUUID":"ABC","brightness":0.65,"hdr":true}]}
        """.utf8)
        let preset = try JSONDecoder().decode(DisplayPreset.self, from: legacy)
        XCTAssertFalse(preset.includes(.color))
    }

    func testBothKindsRoundTrip() throws {
        let entries = [DisplayPresetEntry(displayUUID: "XDR", color: .referencePreset(index: 8, name: "Design & Print (P3-D50)")),
                       DisplayPresetEntry(displayUUID: "EXT", color: .profile(path: "/Library/ColorSync/Profiles/Displays/x.icc")),
                       DisplayPresetEntry(displayUUID: "OFF")]
        let preset = DisplayPreset(name: "Print", icon: "printer", displays: entries)
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertTrue(decoded.includes(.color))
        XCTAssertEqual(decoded.displays.map(\.color), entries.map(\.color))
    }

    func testClearDropsColor() {
        var entry = DisplayPresetEntry(displayUUID: "XDR", color: .profile(path: "/x.icc"))
        entry.clear(.color)
        XCTAssertNil(entry.color)
    }

    private let factory: [(index: Int, name: String)] = [
        (0, "Apple XDR Display (P3-1600 nits)"), (8, "Design & Print (P3-D50)"), (11, "My Custom")
    ]

    func testSavedNumberWithItsNameIsUsed() {
        XCTAssertEqual(PresetColor.referencePresetIndex(index: 8, name: "Design & Print (P3-D50)", in: factory), 8)
    }

    /// A custom preset deleted and another made in its place: find the saved one by name.
    func testNumberReusedByAnotherPresetFallsBackToName() {
        let reused: [(index: Int, name: String)] = [(11, "Someone Else"), (12, "My Custom")]
        XCTAssertEqual(PresetColor.referencePresetIndex(index: 11, name: "My Custom", in: reused), 12)
    }

    /// A deleted preset, or names in another system language: nothing is applied.
    func testUnknownNameIsSkipped() {
        XCTAssertNil(PresetColor.referencePresetIndex(index: 8, name: "Design et impression", in: factory))
        XCTAssertNil(PresetColor.referencePresetIndex(index: 11, name: "Gone", in: [(11, "Other")]))
    }
}
