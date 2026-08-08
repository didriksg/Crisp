import XCTest
import CoreGraphics

/// Headless tests for the DDC AVService identity-matching decision core.
///
/// `DDCServiceMatcher` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DisplayModeGeometry`), so no `@testable import Crisp` is
/// needed — that would pull IOKit + the private bridging header and defeat headless
/// purity. Each test names the mutation it is designed to kill in a trailing comment.
final class DDCServiceMatcherTests: XCTestCase {

    // MARK: - Strategy 1: exact (vendor + product + serial) matching

    /// *Exact match, single.* Happy path: one service, one display, identical identity.
    /// Kills: a matcher that drops the exact-match branch (pair with the serial-0 and
    /// exact-beats-byModel tests below to actually kill that mutation).
    func testExactSerialMatchSingleDisplay() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1234)
        let result = DDCServiceMatcher.match(
            services: [idA],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertEqual(result.assignments, [.init(displayID: 1, serviceIndex: 0)])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    /// Two same-vendor/product displays differ only by serial. The service's serial
    /// pins display 1 (which is NOT first in `displays` order). A matcher that skipped
    /// exact match and only did vendor+product would grab display 2 instead.
    /// Kills mutation: "drop the exact-match branch, only do vendor+product".
    func testExactSerialMatchPrefersCorrectSerialOverByModel() {
        let svc = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x0005)
        let result = DDCServiceMatcher.match(
            services: [svc],
            displays: [
                (id: 2, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x0006)),
                (id: 1, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x0005))
            ]
        )
        XCTAssertEqual(result.assignments, [.init(displayID: 1, serviceIndex: 0)])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Strategy 1 fallback: vendor + product (serial omitted/zero)

    /// *Serial-0 vendor+product fallback.* IORegistry omitted the serial; CG has the real
    /// one. Exact fails, vendor+product matches. (Documents the byModel branch.)
    func testVendorProductFallbackWhenServiceSerialIsZero() {
        let svc = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0)
        let result = DDCServiceMatcher.match(
            services: [svc],
            displays: [(id: 1, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x9999))]
        )
        XCTAssertEqual(result.assignments, [.init(displayID: 1, serviceIndex: 0)])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    /// Serial-0 service; display 5 shares vendor+product, display 2 does not. Correct
    /// byModel matching claims display 5. If byModel were dropped (M1), the service
    /// falls through to Strategy 2 and claims leftovers[0] = display 2 — a mis-pair.
    /// Kills mutation M1: "remove the byModel fallback, keep only exact match".
    func testByModelFallbackPicksCorrectDisplayNotFallbackOrder() {
        let svc = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0)
        let result = DDCServiceMatcher.match(
            services: [svc],
            displays: [
                (id: 5, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x9999)),
                (id: 2, identity: .init(vendor: 0x9999, product: 0x8888, serial: 0x0001))
            ]
        )
        XCTAssertEqual(result.assignments, [.init(displayID: 5, serviceIndex: 0)])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Multi-display Strategy 1

    /// *Two distinct monitors, both exact-match.* Both services resolve on the first pass.
    /// Kills mutation: a matcher that returns after the first assignment.
    func testTwoDistinctMonitorsBothExactMatch() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let idB = DDCServiceMatcher.Identity(vendor: 0x4c2d, product: 0x2a1f, serial: 0x2)
        let result = DDCServiceMatcher.match(
            services: [idA, idB],
            displays: [(id: 1, identity: idA), (id: 2, identity: idB)]
        )
        XCTAssertEqual(result.assignments, [
            .init(displayID: 1, serviceIndex: 0),
            .init(displayID: 2, serviceIndex: 1)
        ])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    /// *Identity match is order-sensitive (used-set guard).* services=[A, A],
    /// displays=[(1, A), (2, A)]: service0 claims display 1, service1 must NOT re-claim
    /// display 1 and instead claims display 2.
    /// Kills mutation M2: "drop `!usedDisplays.contains($0)`" → would give [(1, 0), (1, 1)].
    func testIdenticalMonitorsShareUsedDisplayGuard() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let result = DDCServiceMatcher.match(
            services: [idA, idA],
            displays: [(id: 1, identity: idA), (id: 2, identity: idA)]
        )
        XCTAssertEqual(result.assignments, [
            .init(displayID: 1, serviceIndex: 0),
            .init(displayID: 2, serviceIndex: 1)
        ])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    /// *Two identical monitors (same real serial).* Documents the known limitation: this
    /// is NOT flagged ambiguous (a deliberate product decision, pinned here, not changed).
    /// Also pins that Strategy 1's `.first` scan honors the given `displays` order —
    /// service0 claims display 7 (first), service1 claims display 3.
    /// Kills mutation M4: "sort `displays` before the Strategy 1 scan" → would flip to
    /// [(3, 0), (7, 1)].
    func testIdenticalRealSerialMonitorsPreserveDisplayIterationOrder() {
        let idX = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0xABCD)
        let result = DDCServiceMatcher.match(
            services: [idX, idX],
            displays: [(id: 7, identity: idX), (id: 3, identity: idX)]
        )
        XCTAssertEqual(result.assignments, [
            .init(displayID: 7, serviceIndex: 0),
            .init(displayID: 3, serviceIndex: 1)
        ])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Strategy 2: traversal-order fallback

    /// *Traversal-order fallback, two no-identity services.* leftovers are sorted
    /// ascending, so service0 gets the smaller displayID (2), service1 the larger (5).
    /// Kills mutation: sorting leftovers descending, skipping the sort, or zipping in
    /// service order without sorting.
    func testTraversalOrderFallbackIsSortedByDisplayID() {
        let any = DDCServiceMatcher.Identity(vendor: 1, product: 1, serial: 1)
        let result = DDCServiceMatcher.match(
            services: [nil, nil],
            displays: [(id: 5, identity: any), (id: 2, identity: any)]
        )
        XCTAssertEqual(result.assignments, [
            .init(displayID: 2, serviceIndex: 0),
            .init(displayID: 5, serviceIndex: 1)
        ])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertTrue(result.ambiguous)
    }

    /// *More services than displays (truncation).* service0 exact-matches display 1;
    /// services 1 and 2 have nil identity and no leftover to claim.
    /// Kills mutation: a fallback loop that assigns past `leftovers.count` (index-out-of-
    /// bounds crash), or a matcher that reports `unmatchedServiceIndices` pre-fallback.
    func testMoreServicesThanDisplaysTruncatesGracefully() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let result = DDCServiceMatcher.match(
            services: [idA, nil, nil],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertEqual(result.assignments, [.init(displayID: 1, serviceIndex: 0)])
        XCTAssertEqual(result.unmatchedServiceIndices, [1, 2])
        XCTAssertFalse(result.ambiguous)
    }

    /// A single nil-identity service: Strategy 1 skips it, but Strategy 2 assigns it the
    /// sole leftover (display 1). It is therefore NOT in the post-fallback unmatched set
    /// (the documented departure from the original's scratch array), and with one leftover
    /// it is not ambiguous.
    /// Kills mutation: crashing on `nil`; including nil-identity services in
    /// `unmatchedServiceIndices` even after the fallback claims them; or forgetting to run
    /// Strategy 2 for services that skipped Strategy 1.
    func testNilIdentityServiceSkipsStrategy1() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let result = DDCServiceMatcher.match(
            services: [nil],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertEqual(result.assignments, [.init(displayID: 1, serviceIndex: 0)])
        XCTAssertEqual(result.unmatchedServiceIndices, [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Ambiguity flag

    /// *Ambiguity flag requires >1 leftover.* Three sub-cases pin the exact contract.
    /// Kills mutation M3: flipping `leftovers.count > 1` to `> 0` (sub-case (b) flips to
    /// true); also kills flipping `!unmatched.isEmpty` to `unmatched.isEmpty` (sub-case
    /// (a) flips to false) and computing ambiguity from `services.count` instead of
    /// `leftovers.count` (sub-cases (b) and (c) break).
    func testAmbiguousFlagRequiresMoreThanOneLeftover() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let idB = DDCServiceMatcher.Identity(vendor: 0x9999, product: 0x8888, serial: 0x2)
        let any = DDCServiceMatcher.Identity(vendor: 1, product: 1, serial: 1)

        // (a) two no-identity services, two leftover displays → ambiguous (guess among >1).
        let ambiguousCase = DDCServiceMatcher.match(
            services: [nil, nil],
            displays: [(id: 1, identity: any), (id: 2, identity: any)]
        )
        XCTAssertTrue(ambiguousCase.ambiguous, "two leftovers should be ambiguous")

        // (b) one service, no matching display → exactly one leftover → NOT ambiguous
        //     even though one service is unmatched.
        let singleLeftoverCase = DDCServiceMatcher.match(
            services: [idA],
            displays: [(id: 1, identity: idB)]
        )
        XCTAssertFalse(singleLeftoverCase.ambiguous, "one leftover must not be ambiguous")

        // (c) more services than displays → zero leftovers after identity claim → NOT ambiguous.
        let zeroLeftoverCase = DDCServiceMatcher.match(
            services: [idA, nil, nil],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertFalse(zeroLeftoverCase.ambiguous, "zero leftovers must not be ambiguous")
    }

    // MARK: - Empty-input edges

    /// No services and/or no displays must not crash and must yield an empty result
    /// (never ambiguous — there are never >1 leftover to guess among). The no-services
    /// case is production-reachable: an external display is present but the IOKit walk
    /// found zero working DDC channels, so `ordered`/`identities` (and thus `services`)
    /// are empty while `displays` is not.
    func testEmptyInputsProduceEmptyResult() {
        let any = DDCServiceMatcher.Identity(vendor: 1, product: 1, serial: 1)

        // No services → nothing to assign; the lone display is simply unclaimed.
        let noServices = DDCServiceMatcher.match(services: [], displays: [(id: 1, identity: any)])
        XCTAssertEqual(noServices.assignments, [])
        XCTAssertEqual(noServices.unmatchedServiceIndices, [])
        XCTAssertFalse(noServices.ambiguous)

        // No displays → every service is unmatched; still not ambiguous (0 leftovers).
        let noDisplays = DDCServiceMatcher.match(services: [nil], displays: [])
        XCTAssertEqual(noDisplays.assignments, [])
        XCTAssertEqual(noDisplays.unmatchedServiceIndices, [0])
        XCTAssertFalse(noDisplays.ambiguous)

        // Both empty → trivially empty.
        let bothEmpty = DDCServiceMatcher.match(services: [], displays: [])
        XCTAssertEqual(bothEmpty.assignments, [])
        XCTAssertEqual(bothEmpty.unmatchedServiceIndices, [])
        XCTAssertFalse(bothEmpty.ambiguous)
    }
}
