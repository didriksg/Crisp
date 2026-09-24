import Foundation

/// The speaker volume maximum DDC volume writes scale by: take only the low byte
/// of a VCP 0x62 reply. Some firmware fills the high byte wrongly, which would
/// otherwise put every level past the monitor's true top (#162).
enum DDCVolumeMax {
    static func from(_ reported: UInt16) -> UInt16 {
        let low = reported & 0xFF
        // A low byte of 0 would scale every write to mute; 100 is the safe fallback.
        return low == 0 ? 100 : low
    }
}
