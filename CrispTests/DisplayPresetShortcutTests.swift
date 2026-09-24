import XCTest

/// Headless tests for the preset shortcut field. `DisplayPreset` and `KeyboardShortcut`
/// compile directly into this test target, so no `@testable import Crisp` is needed.
final class DisplayPresetShortcutTests: XCTestCase {

    /// Presets saved before the shortcut feature decode with shortcut nil, not fail.
    func testLegacyPresetJSONDecodesWithNilShortcut() throws {
        let legacy = Data("""
        {"id":"11111111-2222-3333-4444-555555555555","name":"Work","icon":"display",
         "displays":[{"id":"99999999-8888-7777-6666-555555555555",
         "displayUUID":"ABC","width":1920,"height":1080,"isHiDPI":true}]}
        """.utf8)
        let preset = try JSONDecoder().decode(DisplayPreset.self, from: legacy)
        XCTAssertNil(preset.shortcut)
        XCTAssertEqual(preset.name, "Work")
    }

    /// A preset with a shortcut round-trips through the JSON persistence layer.
    func testShortcutRoundTrips() throws {
        var preset = DisplayPreset(name: "Gaming", icon: "gamecontroller.fill", displays: [])
        preset.shortcut = KeyboardShortcut(keyCode: 18, nsModifierFlags: 1 << 20, keyLabel: "1")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: data)
        XCTAssertEqual(decoded.shortcut, preset.shortcut)
    }
}
