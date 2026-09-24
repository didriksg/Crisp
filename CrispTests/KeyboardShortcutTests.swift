import XCTest

/// Headless tests for the recorded-shortcut model. `KeyboardShortcut` compiles directly
/// into this test target, so no `@testable import Crisp` is needed.
final class KeyboardShortcutTests: XCTestCase {

    // NSEvent.ModifierFlags raw bits, mirrored from the model's private constants.
    private let shift: UInt = 1 << 17
    private let control: UInt = 1 << 18
    private let option: UInt = 1 << 19
    private let command: UInt = 1 << 20

    // MARK: - Validation

    /// A bare key is typing, not a shortcut; registering it would swallow normal input.
    func testNoModifiersIsRejected() {
        XCTAssertNil(KeyboardShortcut(keyCode: 4, nsModifierFlags: 0, keyLabel: "H"))
    }

    /// Shift alone still just types (a capital letter), so it can't anchor a shortcut.
    func testShiftOnlyIsRejected() {
        XCTAssertNil(KeyboardShortcut(keyCode: 4, nsModifierFlags: shift, keyLabel: "H"))
    }

    func testEachAnchorModifierIsAccepted() {
        XCTAssertNotNil(KeyboardShortcut(keyCode: 4, nsModifierFlags: command, keyLabel: "H"))
        XCTAssertNotNil(KeyboardShortcut(keyCode: 4, nsModifierFlags: option, keyLabel: "H"))
        XCTAssertNotNil(KeyboardShortcut(keyCode: 4, nsModifierFlags: control, keyLabel: "H"))
    }

    /// Device-dependent bits (caps lock, function, left/right variants) must not leak
    /// into the Carbon mask.
    func testUnrelatedFlagBitsAreIgnored() {
        let noisy = command | (1 << 16) | (1 << 23) | 0xFF  // capsLock, function, device bits
        let shortcut = KeyboardShortcut(keyCode: 4, nsModifierFlags: noisy, keyLabel: "H")
        XCTAssertEqual(shortcut?.carbonModifiers, KeyboardShortcut.carbonCommand)
    }

    // MARK: - Carbon conversion

    /// The registered mask must be the Carbon Events.h values, not NSEvent bits.
    func testCarbonConversion() {
        let shortcut = KeyboardShortcut(
            keyCode: 4, nsModifierFlags: command | shift | option | control, keyLabel: "H")
        XCTAssertEqual(
            shortcut?.carbonModifiers,
            KeyboardShortcut.carbonCommand | KeyboardShortcut.carbonShift
                | KeyboardShortcut.carbonOption | KeyboardShortcut.carbonControl)
    }

    // MARK: - Display string

    /// Modifier glyphs render in the canonical macOS order ⌃⌥⇧⌘, then the key.
    func testDisplayOrder() {
        let shortcut = KeyboardShortcut(
            keyCode: 4, nsModifierFlags: command | shift | option | control, keyLabel: "H")
        XCTAssertEqual(shortcut?.display, "⌃⌥⇧⌘H")
    }

    func testDisplaySingleModifier() {
        let shortcut = KeyboardShortcut(keyCode: 96, nsModifierFlags: option, keyLabel: "F5")
        XCTAssertEqual(shortcut?.display, "⌥F5")
    }

    // MARK: - Key labels

    /// Special keys map to named glyphs; kVK codes from Carbon Events.h.
    func testSpecialKeyLabels() {
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 123, characters: nil), "←")
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 49, characters: " "), "Space")
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 96, characters: nil), "F5")
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 51, characters: nil), "⌫")
    }

    /// Printable keys use the typed character, uppercased so "h" and "H" read the same.
    func testPrintableKeyLabelUppercases() {
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 4, characters: "h"), "H")
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 18, characters: "1"), "1")
    }

    /// No character and no special mapping: empty label, never a crash.
    func testUnknownKeyLabelIsEmpty() {
        XCTAssertEqual(KeyboardShortcut.keyLabel(keyCode: 999, characters: nil), "")
    }

    // MARK: - Persistence

    /// The stored JSON round-trips exactly (SettingsService persists it via Codable).
    func testCodableRoundTrip() throws {
        let original = KeyboardShortcut(keyCode: 4, nsModifierFlags: command | option, keyLabel: "H")
        let data = try JSONEncoder().encode(XCTUnwrap(original))
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Steal-on-record compares by key code + modifiers only; the label may differ across layouts.
    func testSameKeysIgnoresLabel() throws {
        let a = try XCTUnwrap(KeyboardShortcut(keyCode: 4, nsModifierFlags: command, keyLabel: "H"))
        let b = try XCTUnwrap(KeyboardShortcut(keyCode: 4, nsModifierFlags: command, keyLabel: "И"))
        let c = try XCTUnwrap(KeyboardShortcut(keyCode: 4, nsModifierFlags: option, keyLabel: "H"))
        XCTAssertTrue(a.sameKeys(as: b))
        XCTAssertFalse(a.sameKeys(as: c))
    }
}
