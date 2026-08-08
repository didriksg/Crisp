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
///     (order-sensitive — do not sort).
///   - `displays` are the external `CGDirectDisplayID`s in `CGGetOnlineDisplayList`
///     order (Strategy 1's `.first` scan depends on this order; do not sort here).
enum DDCServiceMatcher {
    /// A display's vendor/product/serial identity — mirrors the IORegistry
    /// `ProductAttributes` (`LegacyManufacturerID` / `ProductID` / `SerialNumber`)
    /// which line up with `CGDisplayVendorNumber` / `CGDisplayModelNumber` /
    /// `CGDisplaySerialNumber` for the same physical display.
    struct Identity: Equatable {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    /// One service→display assignment produced by `match`.
    struct Assignment: Equatable {
        let displayID: CGDirectDisplayID
        let serviceIndex: Int
    }

    /// The outcome of a matching pass.
    struct Result: Equatable {
        /// Service→display assignments in ascending service-index order.
        let assignments: [Assignment]
        /// Service indices still unclaimed **after** the Strategy 2 fallback.
        let unmatchedServiceIndices: [Int]
        /// True iff the traversal-order fallback had to guess among >1
        /// indistinguishable leftover display (the UI surfaces `mappingWarning`
        /// only then).
        let ambiguous: Bool
    }

    /// Matches DDC channels to external displays.
    ///
    /// - Parameters:
    ///   - services: DDC channels in IORegistry traversal order; `nil` means the
    ///     channel's nearest framebuffer exposed no identity.
    ///   - displays: external displays in `CGGetOnlineDisplayList` order.
    /// - Returns: the assignments (ascending service order), the post-fallback
    ///   unmatched service indices, and the ambiguity flag.
    ///
    /// - Note: `unmatchedServiceIndices` is the **only** intentional departure from
    ///   line-for-line mimicry of the original method. The original builds an
    ///   `unmatched` scratch array during Strategy 1 and the fallback loop *assigns*
    ///   some of those entries without removing them — but that array is only used to
    ///   drive the fallback and compute `ambiguous`, never returned. The test-visible
    ///   return here instead reports services still unclaimed *after* both strategies
    ///   (a strict improvement: it reflects post-fallback reality, which the original
    ///   throws away).
    static func match(
        services: [Identity?],
        displays: [(id: CGDirectDisplayID, identity: Identity)]
    ) -> Result {
        // `serviceByDisplayID` mirrors the original's `map: [CGDirectDisplayID: IOAVServiceRef]`,
        // keyed by displayID and storing the service *index* in place of the service ref.
        var serviceByDisplayID: [CGDirectDisplayID: Int] = [:]
        var usedDisplays = Set<CGDirectDisplayID>()
        var unmatched: [Int] = []

        // Strategy 1: identity matching (vendor+product+serial, then vendor+product).
        for i in services.indices {
            guard let idty = services[i] else { unmatched.append(i); continue }
            let exact = displays.first {
                !usedDisplays.contains($0.id)
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
        var claimedByFallback = Set<Int>()
        for (n, i) in unmatched.enumerated() where n < leftovers.count {
            serviceByDisplayID[leftovers[n]] = i
            claimedByFallback.insert(i)
        }

        // Warn only when the fallback had to guess among >1 indistinguishable displays.
        let ambiguous = !unmatched.isEmpty && leftovers.count > 1

        // Post-fallback unmatched set: scratch entries the fallback did NOT claim.
        // (See the departure note above — the original returns nothing here.)
        let unmatchedServiceIndices = unmatched.filter { !claimedByFallback.contains($0) }

        // Invert displayID→serviceIndex into ascending service-index order. Each
        // service index appears as a value at most once, so the inversion is sound.
        let assignments = serviceByDisplayID
            .map { Assignment(displayID: $0.key, serviceIndex: $0.value) }
            .sorted { $0.serviceIndex < $1.serviceIndex }

        return Result(
            assignments: assignments,
            unmatchedServiceIndices: unmatchedServiceIndices,
            ambiguous: ambiguous
        )
    }
}
