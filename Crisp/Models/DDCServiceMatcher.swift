import Foundation
import CoreGraphics

/// Pure decision core that pairs DDC I2C channels (`IOAVService`) to the correct
/// `CGDirectDisplayID` on Apple Silicon.
///
/// This is the post-enumeration matching logic extracted verbatim in semantics from
/// `DDCService.buildAVServiceMapByProximity()` (the rewrite shipped in PR #13 to fix
/// wrong-display brightness on Apple Silicon, where the old upward parent-chain walk
/// failed because a display's identity lives in a *sibling* `dispextN` node, not an
/// ancestor). The matcher owns no IOKit state and performs no `IOAVServiceReadI2C`
/// probes, so it can be exercised headlessly from an `XCTestCase`.
///
/// Inputs mirror exactly what the runtime method feeds it:
///   - `services` are the working DDC channels in **IORegistry traversal order**
///     (order-sensitive: do not sort).
///   - `displays` are the external `CGDirectDisplayID`s in `CGGetOnlineDisplayList`
///     order (Strategy 1's `.first` scan depends on this order; do not sort here).
enum DDCServiceMatcher {
    /// A display's vendor/product/serial identity mirrors the IORegistry
    /// `ProductAttributes` (`LegacyManufacturerID` / `ProductID` / `SerialNumber`)
    /// which line up with `CGDisplayVendorNumber` / `CGDisplayModelNumber` /
    /// `CGDisplaySerialNumber` for the same physical display. Location is the
    /// stable CoreDisplay/IORegistry path when macOS exposes it.
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

    /// The outcome of a matching pass.
    struct Result: Equatable {
        /// Service index chosen for each display, keyed by `CGDirectDisplayID`.
        let byDisplayID: [CGDirectDisplayID: Int]
        /// True iff the traversal-order fallback had to guess among >1 indistinguishable
        /// leftover display (the UI surfaces `mappingWarning` only then).
        let ambiguous: Bool
    }

    /// Matches DDC channels to external displays.
    ///
    /// - Parameters:
    ///   - services: DDC channels in IORegistry traversal order; `nil` means the
    ///     channel's nearest framebuffer exposed no identity.
    ///   - displays: external displays in `CGGetOnlineDisplayList` order.
    /// - Returns: the displayID-keyed service-index mapping and the ambiguity flag.
    static func match(
        services: [Identity?],
        displays: [(id: CGDirectDisplayID, identity: Identity)]
    ) -> Result {
        // `serviceByDisplayID` mirrors the original's `map: [CGDirectDisplayID: IOAVServiceRef]`,
        // keyed by displayID and storing the service *index* in place of the service ref.
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
