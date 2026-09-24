import Foundation
import CoreGraphics

struct DisplayPresetEntry: Codable, Identifiable {
    var id = UUID()
    var displayUUID: String       // matches physical display
    // nil == attribute not included in this preset (won't be applied).
    // Old presets always stored these keys, so they decode as "included".
    var width: Int?
    var height: Int?
    var isHiDPI: Bool?
    // ponytail: captured alongside resolution but not yet applied or matched on;
    // here so the future "Refresh rate" toggle can use it (and old presets that
    // predate the toggle already carry it). nil for pre-existing presets.
    var refreshRate: Double? = nil
    var brightness: Double?       // optional brightness 0.0-1.0
    var arrangementX: Double?     // optional position
    var arrangementY: Double?

    var resolutionLabel: String {
        guard let w = width, let h = height else { return "—" }
        return "\(w)×\(h)\((isHiDPI ?? false) ? " HiDPI" : "")"
    }
}

struct DisplayPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var icon: String              // SF Symbol name
    var colorName: String? = nil  // chip color key; nil = default
    var displays: [DisplayPresetEntry]
    /// Applies this preset; old presets decode as nil (#61).
    var shortcut: KeyboardShortcut? = nil

    // Which attributes this preset controls (derived from whether any entry stores one).
    var includesResolution: Bool { displays.contains { $0.width != nil } }
    var includesBrightness: Bool { displays.contains { $0.brightness != nil } }
    var includesArrangement: Bool { displays.contains { $0.arrangementX != nil } }

    func includes(_ capture: PresetCapture) -> Bool {
        switch capture {
        case .resolution: includesResolution
        case .brightness: includesBrightness
        case .arrangement: includesArrangement
        }
    }
}

/// One toggleable attribute the preset row's ⋯ menu can drop or re-add.
enum PresetCapture: String, CaseIterable, Identifiable {
    case resolution, brightness, arrangement
    var id: String { rawValue }
    var label: String {
        switch self {
        case .resolution: "Resolution"
        case .brightness: "Brightness"
        case .arrangement: "Arrangement"
        }
    }
}
