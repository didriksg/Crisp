import Foundation
import IOKit
import CoreGraphics

/// Reads a panel's adaptive-sync floor from the IORegistry so the variable-refresh
/// row can show the full range like System Settings ("Variable (48-180Hz)").
///
/// The DCP display pipe (Apple Silicon) publishes per-timing `TimingElements` on its
/// `IOMobileFramebufferShim` node, each carrying `Minimum`/`MaximumVariableRefreshRate`
/// in 16.16 fixed point. The node's `EDID UUID` is EDID-derived, not the CG display
/// UUID: its first 8 hex digits are the panel's vendor and product ids (verified:
/// 10AC7BA0-... for a DELL U2412M, 05E326B3-... for an AOC Q27G3XMN), so the node is
/// matched on `CGDisplayVendorNumber`/`CGDisplayModelNumber`. Two identical panels
/// share a floor, so prefix ambiguity is harmless. Returns nil when the registry does
/// not expose a range (no VRR timings, or a non-DCP framebuffer), in which case the
/// caller falls back to the "Variable (up to NHz)" wording.
enum VariableRefreshRange {
    static func minimumRate(vendorNumber: UInt32, modelNumber: UInt32) -> Int? {
        // The UUID keeps the EDID's raw byte order: vendor big-endian, product
        // little-endian (CG's modelNumber is the decoded value, so swap it back).
        let prefix = String(format: "%04X%02X%02X",
                            vendorNumber & 0xFFFF, modelNumber & 0xFF, (modelNumber >> 8) & 0xFF)
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOMobileFramebufferShim"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { service = IOIteratorNext(iterator) }
            defer { IOObjectRelease(service) }
            guard let edid = IORegistryEntryCreateCFProperty(service, "EDID UUID" as CFString,
                                                             kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  edid.replacingOccurrences(of: "-", with: "").uppercased().hasPrefix(prefix),
                  let timings = IORegistryEntryCreateCFProperty(service, "TimingElements" as CFString,
                                                                kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]]
            else { continue }
            let floors = timings.compactMap { timing -> Int? in
                guard let maxRate = timing["MaximumVariableRefreshRate"] as? Int, maxRate > 0,
                      let minRate = timing["MinimumVariableRefreshRate"] as? Int, minRate > 0
                else { return nil }
                return minRate / 65536
            }
            return floors.min()
        }
        return nil
    }
}
