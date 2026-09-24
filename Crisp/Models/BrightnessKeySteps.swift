import Foundation

/// The stops the brightness and volume keys move between: the same sixteen
/// macOS uses, and what the OSD banner's tick dots mark.
///
/// Do not step by a fraction of the range from the current value: it must
/// land on a stop every time, or the dots stop meaning anything.
enum BrightnessKeySteps {
    static let stops = 16.0
    static let step = 100.0 / stops
    /// Quarter-stop grid macOS moves the built-in on when Option+Shift are held.
    static let fineStep = step / 4.0

    /// The next stop above or below `value`, 0...100 (continues past 100 for
    /// Extra Brightness; caller clamps). `fine` moves a quarter-stop, snapped
    /// to the nearest quarter so a rounded readback still advances.
    static func next(from value: Double, up: Bool, fine: Bool = false) -> Double {
        if fine {
            return ((value / fineStep).rounded() + (up ? 1 : -1)) * fineStep
        }
        let index = value / step
        // A value on a stop must move a whole step; a rounded readback near one must too.
        let epsilon = 0.001
        let target = up ? (index + epsilon).rounded(.down) + 1 : (index - epsilon).rounded(.up) - 1
        return target * step
    }
}
