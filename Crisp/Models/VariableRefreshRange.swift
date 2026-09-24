import Foundation
import IOKit
import CoreGraphics

/// Reads a panel's adaptive-sync floor from the IORegistry so the variable-refresh
/// row can show the full range like System Settings ("Variable (48-180Hz)"). Matches
/// the `IOMobileFramebufferShim` node by its EDID-derived vendor+product prefix (two
/// identical panels share a floor, so ambiguity is harmless); `TimingElements` gives
/// the range in 16.16 fixed point. Returns nil with no range; caller uses "up to NHz".
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
