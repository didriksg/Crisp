import Foundation

/// Refresh-rate label formatter, extracted for headless XCTest. Matches System Settings:
/// 0 renders as `60Hz` (the display-default contract), whole rates render clean, and
/// NTSC fractional rates keep two decimals (`59.94Hz`) so they don't collapse together.
enum RefreshRateFormat {
    static func label(_ refreshRate: Double) -> String {
        // The built-in's variable refresh is relabelled "ProMotion" upstream, so this
        // only ever sees 0 as an external's default timing (see the type doc above).
        guard refreshRate > 0 else { return "60Hz" }
        let rounded = refreshRate.rounded()
        if abs(refreshRate - rounded) < 0.01 { return "\(Int(rounded))Hz" }
        return String(format: "%.2fHz", refreshRate)
    }
}
