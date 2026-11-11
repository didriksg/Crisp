import Foundation

/// The four rotations System Settings offers, for the display card's Rotation row (#258).
enum DisplayRotation: Int, CaseIterable, Identifiable {
    case standard = 0
    case quarter = 90
    case half = 180
    case threeQuarter = 270

    var id: Int { rawValue }

    /// CGDisplayRotation's reading (a Double, in degrees) as one of the four. Any angle
    /// outside them rounds to the nearest; a negative one counts the other way round.
    init(degrees: Double) {
        let quarters = Int((degrees / 90).rounded())
        self = Self(rawValue: ((quarters % 4 + 4) % 4) * 90) ?? .standard
    }

    /// System Settings' own names: "Standard" for 0, the degrees for the rest.
    var label: String {
        self == .standard ? String(localized: "Standard") : "\(rawValue)°"
    }
}
