import Foundation

/// Pure refresh-rate label formatter, extracted from `DisplayMode.refreshRateString`
/// for headless XCTest (the rest of `DisplayMode` reaches private CGS APIs through the
/// bridging header, which the test target does not carry — see `project.yml`). Mirrors
/// what System Settings shows:
///   - a zero ("display default") rate renders as `60Hz`, honouring the
///     `DisplayMode.refreshRate` contract ("0 means display default, shown as 60");
///   - whole-number timings render clean (`60Hz`);
///   - NTSC fractional timings keep two decimals (`59.94Hz`, `47.95Hz`) so they don't
///     collapse onto the neighbouring whole rate and show up as duplicate rows.
enum RefreshRateFormat {
    /// Formats a refresh rate (in Hz) for display.
    static func label(_ refreshRate: Double) -> String {
        // CGDisplayMode.refreshRate reports 0 for the display's default timing. macOS
        // treats that as the panel default (60 Hz for external monitors), so render it
        // as 60 Hz rather than a placeholder that reads as broken next to real rates.
        // The built-in's variable refresh is relabelled to "ProMotion" upstream.
        guard refreshRate > 0 else { return "60Hz" }
        let rounded = refreshRate.rounded()
        if abs(refreshRate - rounded) < 0.01 { return "\(Int(rounded))Hz" }
        return String(format: "%.2fHz", refreshRate)
    }
}
