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

/// Detects the variable-refresh member of duplicate mode pairs (issue #31).
///
/// On a VRR-capable external, macOS's mode table carries two otherwise identical
/// usable entries for each rate inside the panel's adaptive range: one fixed, one
/// variable. Nothing in the public API tells them apart per mode, so Crisp showed
/// confusing duplicate rows ("165Hz, 165Hz"). Verified against real hardware
/// (AOC Q27G3XMN 48-180Hz panel, macOS 26, live NSScreen refresh-range checks at
/// 180 native, 180 scaled, and 60 HiDPI):
///   - the variable twin always enumerates with the LOWER modeNumber;
///   - at native resolution the fixed twin additionally carries the IOKit
///     safe|default flag bits (0x2|0x4), and those bits are static (they do not
///     follow the user's selection);
///   - non-VRR panels (a DELL U2412M and the built-in ProMotion panel) expose no
///     usable duplicate pairs at all, so this cannot false-positive there.
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
                // Scaled pairs are byte-identical in flags; the variable twin
                // consistently enumerates first.
                variable.insert(pair.min { $0.id < $1.id }!.id)
            }
        }
        return variable
    }
}
