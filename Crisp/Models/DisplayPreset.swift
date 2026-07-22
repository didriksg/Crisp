import Foundation
import CoreGraphics

struct DisplayPresetEntry: Codable, Identifiable {
    var id = UUID()
    var displayUUID: String       // matches physical display
    var width: Int
    var height: Int
    var isHiDPI: Bool
    var brightness: Double?       // optional brightness 0.0-1.0
    var arrangementX: Double?     // optional position
    var arrangementY: Double?
}

struct DisplayPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var icon: String              // SF Symbol name
    var colorName: String? = nil  // chip color key; nil = default
    var isBuiltin: Bool = false
    var displays: [DisplayPresetEntry]
}
