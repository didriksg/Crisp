import Foundation

/// The stops the brightness and volume keys move between: the same sixteen
/// macOS itself uses, and the ones the OSD banner's tick dots mark.
///
/// The keys used to add or subtract a sixteenth of the range from wherever the
/// value happened to be, so a display sitting at 79 percent went to 86, 92 and
/// 98 and never touched a stop. The system's own keys land on one every time,
/// which is what makes its dots mean anything.
enum BrightnessKeySteps {
    static let stops = 16.0
    static let step = 100.0 / stops

    /// The next stop above or below `value`, on the 0...100 scale the keys and
    /// the banner both use. The grid carries on past 100 for displays with
    /// Extra Brightness; clamping to the display's maximum is the caller's.
    static func next(from value: Double, up: Bool) -> Double {
        let index = value / step
        // A value already on a stop has to move a whole step, and one a hair
        // off it, which a rounded readback gives, must not move only the hair.
        let epsilon = 0.001
        let target = up ? (index + epsilon).rounded(.down) + 1 : (index - epsilon).rounded(.up) - 1
        return target * step
    }
}
