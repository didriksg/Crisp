import Foundation

/// The speaker volume maximum that DDC volume writes scale by, from the max
/// field of a VCP 0x62 reply.
///
/// Speaker volume is a one-byte value: ddcutil reads 0x62 from the low byte
/// alone in every MCCS version. Some firmware fills the high byte of the max
/// anyway. The Dell S2725DSM replies 0xFF64 (65380) for a range of 0 to 100
/// (#162), and scaled by that, every level above zero landed past the
/// monitor's top, so the keys and the slider gave only mute or full volume.
enum DDCVolumeMax {
    static func from(_ reported: UInt16) -> UInt16 {
        let low = reported & 0xFF
        // A low byte of 0 would scale every write to 0, which is mute; 100 is
        // what a forced write-only display assumes too.
        return low == 0 ? 100 : low
    }
}
