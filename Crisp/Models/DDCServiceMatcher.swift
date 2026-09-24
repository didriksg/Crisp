import Foundation
import CoreGraphics

/// Pure decision core that pairs DDC I2C channels (`IOAVService`) to the correct
/// `CGDirectDisplayID` on Apple Silicon (PR #13). Owns no IOKit state and performs no
/// `IOAVServiceReadI2C` probes, so it runs headlessly in `XCTestCase`.
///
/// `services` are DDC channels in IORegistry traversal order; `displays` are external
/// `CGDirectDisplayID`s in `CGGetOnlineDisplayList` order. Both are order-sensitive:
/// do not sort either.
enum DDCServiceMatcher {
    /// Vendor/product/serial mirror IORegistry `ProductAttributes`/CG's equivalents.
    /// Location is the stable CoreDisplay/IORegistry path, when macOS exposes it.
    struct Identity: Equatable {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
        let location: String?

        init(vendor: UInt32, product: UInt32, serial: UInt32, location: String? = nil) {
            self.vendor = vendor
            self.product = product
            self.serial = serial
            self.location = location
        }
    }

    struct Result: Equatable {
        /// Service index chosen for each display, keyed by `CGDirectDisplayID`.
        let byDisplayID: [CGDirectDisplayID: Int]
        /// True iff the traversal-order fallback had to guess among >1 indistinguishable
        /// leftover display (the UI surfaces `mappingWarning` only then).
        let ambiguous: Bool
    }

    /// Matches DDC channels to external displays. `nil` in `services` means the
    /// channel's framebuffer exposed no identity.
    static func match(
        services: [Identity?],
        displays: [(id: CGDirectDisplayID, identity: Identity)]
    ) -> Result {
        var serviceByDisplayID: [CGDirectDisplayID: Int] = [:]
        var usedDisplays = Set<CGDirectDisplayID>()
        var unmatched: [Int] = []

        // Strategy 1: stable location, then non-zero serial, then model identity.
        for i in services.indices {
            guard let idty = services[i] else { unmatched.append(i); continue }
            let byLocation = displays.first {
                guard let location = idty.location, !location.isEmpty else { return false }
                return !usedDisplays.contains($0.id) && $0.identity.location == location
            }
            let exact = byLocation ?? displays.first {
                !usedDisplays.contains($0.id)
                    && idty.serial != 0
                    && $0.identity.serial != 0
                    && $0.identity.vendor == idty.vendor
                    && $0.identity.product == idty.product
                    && $0.identity.serial == idty.serial
            }
            let byModel = exact ?? displays.first {
                !usedDisplays.contains($0.id)
                    && $0.identity.vendor == idty.vendor
                    && $0.identity.product == idty.product
            }
            if let matched = byModel {
                serviceByDisplayID[matched.id] = i
                usedDisplays.insert(matched.id)
            } else {
                unmatched.append(i)
            }
        }

        // Strategy 2: traversal-order fallback for whatever identity matching missed.
        let leftovers = displays.map(\.id).filter { !usedDisplays.contains($0) }.sorted()
        for (n, i) in unmatched.enumerated() where n < leftovers.count {
            serviceByDisplayID[leftovers[n]] = i
        }

        // Warn only when the fallback had to guess among >1 indistinguishable displays.
        let ambiguous = !unmatched.isEmpty && leftovers.count > 1

        return Result(byDisplayID: serviceByDisplayID, ambiguous: ambiguous)
    }
}
