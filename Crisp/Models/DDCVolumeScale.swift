import Foundation

/// Maps 0–100% volume onto raw VCP 0x62 values, capped by the per-display
/// DDC Value Range setting for finer keyboard and slider adjustments.
enum DDCVolumeScale {
    /// The scale's top: the ceiling under the hardware maximum, and at least 1
    /// so a corrupt stored zero cannot turn every write into mute.
    static func effectiveMax(hardwareMax: UInt16, ceiling: UInt16?) -> UInt16 {
        max(1, min(hardwareMax, ceiling ?? hardwareMax))
    }

    /// A user ceiling clamped into 1...hardwareMax.
    static func clampedCeiling(_ value: Int, hardwareMax: UInt16) -> UInt16 {
        UInt16(max(1, min(Int(hardwareMax), value)))
    }

    /// 0–100% to the raw write for the given scale, rounded and clamped.
    static func raw(fromPercent percent: Double, effectiveMax: UInt16) -> UInt16 {
        let clamped = max(0, min(100, percent))
        let raw = (clamped / 100.0 * Double(effectiveMax)).rounded()
        return UInt16(max(0, min(Double(effectiveMax), raw)))
    }

    /// A raw read as 0–100% of the scale. A level above the scale's top (a
    /// ceiling lowered under the monitor's current volume) reads as full.
    static func percent(fromRaw raw: UInt16, effectiveMax: UInt16) -> Double {
        guard effectiveMax > 0 else { return 0 }
        return min(1.0, Double(raw) / Double(effectiveMax)) * 100.0
    }
}
