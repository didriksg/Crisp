import Foundation

/// A recorded global shortcut: a virtual key code plus Carbon modifier flags, with the
/// key's display label captured at record time (layout-dependent, so it can't be
/// re-derived later). Carbon/NSEvent masks are redeclared as raw values so this file
/// stays Foundation-only and compiles into CrispTests without an app host.
struct KeyboardShortcut: Equatable, Codable {
    /// Virtual key code (kVK_*), the value RegisterEventHotKey wants.
    let keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey subset).
    let carbonModifiers: UInt32
    /// Display label for the key itself ("H", "F5", "←"), captured at record time.
    let keyLabel: String

    // Carbon HIToolbox modifier masks (Events.h).
    static let carbonCommand: UInt32 = 0x0100
    static let carbonShift: UInt32 = 0x0200
    static let carbonOption: UInt32 = 0x0800
    static let carbonControl: UInt32 = 0x1000

    // NSEvent.ModifierFlags raw bits.
    private static let nsShift: UInt = 1 << 17
    private static let nsControl: UInt = 1 << 18
    private static let nsOption: UInt = 1 << 19
    private static let nsCommand: UInt = 1 << 20

    /// Fails when the combo has none of ⌘, ⌥, ⌃: a bare key (or shift+key) is
    /// typing, not a shortcut, and registering it would swallow normal input.
    init?(keyCode: UInt16, nsModifierFlags: UInt, keyLabel: String) {
        var carbon: UInt32 = 0
        if nsModifierFlags & Self.nsCommand != 0 { carbon |= Self.carbonCommand }
        if nsModifierFlags & Self.nsShift != 0 { carbon |= Self.carbonShift }
        if nsModifierFlags & Self.nsOption != 0 { carbon |= Self.carbonOption }
        if nsModifierFlags & Self.nsControl != 0 { carbon |= Self.carbonControl }
        guard carbon & (Self.carbonCommand | Self.carbonOption | Self.carbonControl) != 0 else { return nil }
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = carbon
        self.keyLabel = keyLabel
    }

    /// "⌃⌥⇧⌘H": modifier glyphs in the canonical macOS order, then the key.
    var display: String {
        var glyphs = ""
        if carbonModifiers & Self.carbonControl != 0 { glyphs += "⌃" }
        if carbonModifiers & Self.carbonOption != 0 { glyphs += "⌥" }
        if carbonModifiers & Self.carbonShift != 0 { glyphs += "⇧" }
        if carbonModifiers & Self.carbonCommand != 0 { glyphs += "⌘" }
        return glyphs + keyLabel
    }

    /// Same physical combo regardless of the captured label (layouts differ).
    func sameKeys(as other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }

    /// Named glyphs for keys with no printable character, else the typed character
    /// uppercased. `characters` is the event's charactersIgnoringModifiers.
    static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyLabels[keyCode] { return special }
        guard let ch = characters, !ch.isEmpty else { return "" }
        return ch.uppercased()
    }

    /// Virtual key codes (Carbon Events.h kVK_*) for keys without a printable character.
    private static let specialKeyLabels: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 76: "⌤",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20"
    ]
}
