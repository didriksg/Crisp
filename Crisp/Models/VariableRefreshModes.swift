import Foundation

/// One raw CGS mode table row, reduced to the fields the VRR detector needs
/// (`CGSDisplayModeDescription`: modeNumber, flags at offset 4, logical size,
/// freq, backing density).
struct VRRModeRecord: Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let freq: Int
    let density: Float
    let flags: UInt32
}

/// Detects the variable-refresh member of duplicate mode pairs (#31): a VRR-capable
/// external's mode table carries two otherwise-identical usable entries per rate, one
/// fixed, one variable, with nothing in the public API telling them apart per mode.
///
/// The variable twin enumerates with the lower modeNumber, except when the fixed twin
/// carries the IOKit safe|default flag bits (0x2|0x4), which are static and mark it
/// instead. Non-VRR panels expose no usable duplicate pairs, so this can't false-positive.
enum VariableRefreshModes {
    /// Mode macOS deems unusable for the desktop GUI (matches isUsableForDesktopGUI == false).
    static let unusableFlag: UInt32 = 0x4000_0000
    /// kDisplayModeDefaultFlag: the display's default (EDID-preferred) timing.
    static let defaultFlag: UInt32 = 0x0000_0004

    /// IDs of the variable member of every usable exact-duplicate pair
    /// (same logical size, same rate, same backing density).
    static func variableModeIDs(from records: [VRRModeRecord]) -> Set<Int32> {
        var groups: [String: [VRRModeRecord]] = [:]
        for record in records where record.flags & unusableFlag == 0 {
            let key = "\(record.width)x\(record.height)@\(record.freq)@\(String(format: "%.2f", record.density))"
            groups[key, default: []].append(record)
        }
        var variable = Set<Int32>()
        // ponytail: only exact pairs are classified; >2 identical usable modes was
        // never observed on real hardware, guess nothing there.
        for pair in groups.values where pair.count == 2 {
            let defaulted = pair.filter { $0.flags & defaultFlag != 0 }
            if defaulted.count == 1 {
                // The default-flagged twin is the fixed one (EDID-preferred timing).
                variable.insert(pair.first { $0.flags & defaultFlag == 0 }!.id)
            } else {
                // Scaled pairs are flag-identical; the variable twin enumerates first.
                variable.insert(pair.min { $0.id < $1.id }!.id)
            }
        }
        return variable
    }
}
