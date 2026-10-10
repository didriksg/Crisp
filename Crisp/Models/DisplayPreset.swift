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
    /// nil = not included (every preset saved before #188). A stored neutral value is
    /// included and resets the display to neutral on apply.
    var imageAdjustment: GammaAdjustment? = nil
    /// The HDR switch (#198). nil = not included, or a display without the HDR row.
    var hdr: Bool? = nil
    /// Whether the display is on (#211). nil = not included. Off is applied through Crisp's
    /// Disconnect, and an off display stores nothing else.
    var connected: Bool? = nil

    /// Drops a capture's stored value, so applying the preset leaves it alone.
    mutating func clear(_ capture: PresetCapture) {
        switch capture {
        case .resolution: width = nil; height = nil; isHiDPI = nil; refreshRate = nil
        case .brightness: brightness = nil
        case .arrangement: arrangementX = nil; arrangementY = nil
        case .imageAdjustment: imageAdjustment = nil
        case .hdr: hdr = nil
        case .connection: connected = nil
        }
    }

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
    var includesImageAdjustment: Bool { displays.contains { $0.imageAdjustment != nil } }
    var includesHDR: Bool { displays.contains { $0.hdr != nil } }
    var includesConnection: Bool { displays.contains { $0.connected != nil } }

    func includes(_ capture: PresetCapture) -> Bool {
        switch capture {
        case .resolution: includesResolution
        case .brightness: includesBrightness
        case .arrangement: includesArrangement
        case .imageAdjustment: includesImageAdjustment
        case .hdr: includesHDR
        case .connection: includesConnection
        }
    }
}

/// One toggleable attribute the preset row's ⋯ menu can drop or re-add.
enum PresetCapture: String, CaseIterable, Identifiable {
    case resolution, brightness, arrangement, imageAdjustment, hdr, connection
    var id: String { rawValue }
    var label: String {
        switch self {
        case .resolution: "Resolution"
        case .brightness: "Brightness"
        case .arrangement: "Arrangement"
        case .imageAdjustment: "Image Adjustment"
        case .hdr: "HDR"
        case .connection: "Connection"
        }
    }
}

/// The displays a preset's Connection capture turns on and off: only those that differ from
/// now, and never one that is not attached.
struct PresetConnectionPlan: Equatable {
    var reconnect: [String] = []
    var disconnect: [String] = []
}

extension DisplayPreset {
    /// `online` are the lit displays' UUIDs, `disconnected` those Crisp has disconnected.
    func connectionPlan(online: Set<String>, disconnected: Set<String>) -> PresetConnectionPlan {
        var plan = PresetConnectionPlan()
        for entry in displays {
            if entry.connected == true, disconnected.contains(entry.displayUUID) {
                plan.reconnect.append(entry.displayUUID)
            } else if entry.connected == false, online.contains(entry.displayUUID) {
                plan.disconnect.append(entry.displayUUID)
            }
        }
        return plan
    }
}
