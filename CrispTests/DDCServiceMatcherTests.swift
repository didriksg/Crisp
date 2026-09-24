import XCTest
import CoreGraphics

/// Headless tests for the DDC AVService identity-matching decision core.
/// `DDCServiceMatcher` compiles directly into this test target, so no
/// `@testable import Crisp` is needed.
final class DDCServiceMatcherTests: XCTestCase {

    // MARK: - Strategy 1: exact (vendor + product + serial) matching

    /// One service, one display, identical identity: the happy path.
    func testExactSerialMatchSingleDisplay() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1234)
        let result = DDCServiceMatcher.match(
            services: [idA],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0])
        XCTAssertEqual(unmatchedIndices(services: [idA], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    /// Same vendor/product, different serial: the serial picks the matching display, not the first.
    func testExactSerialMatchPrefersCorrectSerialOverByModel() {
        let svc = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x0005)
        let result = DDCServiceMatcher.match(
            services: [svc],
            displays: [
                (id: 2, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x0006)),
                (id: 1, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x0005))
            ]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0])
        XCTAssertEqual(unmatchedIndices(services: [svc], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Strategy 1 fallback: vendor + product (serial omitted/zero)

    /// IORegistry omitted the serial; vendor+product still matches against CG's real serial.
    func testVendorProductFallbackWhenServiceSerialIsZero() {
        let svc = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0)
        let result = DDCServiceMatcher.match(
            services: [svc],
            displays: [(id: 1, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x9999))]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0])
        XCTAssertEqual(unmatchedIndices(services: [svc], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    /// Serial-0 service: byModel matching picks the display sharing vendor+product, not the first leftover.
    func testByModelFallbackPicksCorrectDisplayNotFallbackOrder() {
        let svc = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0)
        let result = DDCServiceMatcher.match(
            services: [svc],
            displays: [
                (id: 5, identity: .init(vendor: 0x10ac, product: 0x41c0, serial: 0x9999)),
                (id: 2, identity: .init(vendor: 0x9999, product: 0x8888, serial: 0x0001))
            ]
        )
        XCTAssertEqual(result.byDisplayID, [5: 0])
        XCTAssertEqual(unmatchedIndices(services: [svc], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Multi-display Strategy 1

    /// Two distinct monitors both resolve by exact match in the same pass.
    func testTwoDistinctMonitorsBothExactMatch() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let idB = DDCServiceMatcher.Identity(vendor: 0x4c2d, product: 0x2a1f, serial: 0x2)
        let result = DDCServiceMatcher.match(
            services: [idA, idB],
            displays: [(id: 1, identity: idA), (id: 2, identity: idB)]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0, 2: 1])
        XCTAssertEqual(unmatchedIndices(services: [idA, idB], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    /// Two services with identical identity must not both claim the same display.
    func testIdenticalMonitorsShareUsedDisplayGuard() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let result = DDCServiceMatcher.match(
            services: [idA, idA],
            displays: [(id: 1, identity: idA), (id: 2, identity: idA)]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0, 2: 1])
        XCTAssertEqual(unmatchedIndices(services: [idA, idA], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    /// Two monitors sharing a real serial are not flagged ambiguous (a pinned limitation).
    func testIdenticalRealSerialMonitorsPreserveDisplayIterationOrder() {
        let idX = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0xABCD)
        let result = DDCServiceMatcher.match(
            services: [idX, idX],
            displays: [(id: 7, identity: idX), (id: 3, identity: idX)]
        )
        XCTAssertEqual(result.byDisplayID, [7: 0, 3: 1])
        XCTAssertEqual(unmatchedIndices(services: [idX, idX], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    func testLocationWinsWhenIdenticalDisplayOrderIsReversed() {
        let serviceA = DDCServiceMatcher.Identity(
            vendor: 1507, product: 12816, serial: 0, location: "IOService:/dispext0@B0000000"
        )
        let serviceB = DDCServiceMatcher.Identity(
            vendor: 1507, product: 12816, serial: 0, location: "IOService:/dispext1@90000000"
        )
        let result = DDCServiceMatcher.match(
            services: [serviceA, serviceB],
            displays: [
                (id: 2, identity: serviceB),
                (id: 5, identity: serviceA)
            ]
        )

        XCTAssertEqual(result.byDisplayID, [2: 1, 5: 0])
        XCTAssertFalse(result.ambiguous)
    }

    func testMissingLocationsPreserveModelFallback() {
        let service = DDCServiceMatcher.Identity(vendor: 1507, product: 12816, serial: 0)
        let result = DDCServiceMatcher.match(
            services: [service],
            displays: [
                (id: 5, identity: .init(vendor: 1507, product: 12816, serial: 0)),
                (id: 2, identity: .init(vendor: 1, product: 2, serial: 0))
            ]
        )

        XCTAssertEqual(result.byDisplayID, [5: 0])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Strategy 2: traversal-order fallback

    /// No-identity services fall back to the lowest displayIDs first.
    func testTraversalOrderFallbackIsSortedByDisplayID() {
        let any = DDCServiceMatcher.Identity(vendor: 1, product: 1, serial: 1)
        let result = DDCServiceMatcher.match(
            services: [nil, nil],
            displays: [(id: 5, identity: any), (id: 2, identity: any)]
        )
        XCTAssertEqual(result.byDisplayID, [2: 0, 5: 1])
        XCTAssertEqual(unmatchedIndices(services: [nil, nil], result: result), [])
        XCTAssertTrue(result.ambiguous)
    }

    /// More services than displays: the extras are left unmatched, not crashed on.
    func testMoreServicesThanDisplaysTruncatesGracefully() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let result = DDCServiceMatcher.match(
            services: [idA, nil, nil],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0])
        XCTAssertEqual(unmatchedIndices(services: [idA, nil, nil], result: result), [1, 2])
        XCTAssertFalse(result.ambiguous)
    }

    /// A nil-identity service skips exact matching but is still claimed by the fallback.
    func testNilIdentityServiceSkipsStrategy1() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let result = DDCServiceMatcher.match(
            services: [nil],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertEqual(result.byDisplayID, [1: 0])
        XCTAssertEqual(unmatchedIndices(services: [nil], result: result), [])
        XCTAssertFalse(result.ambiguous)
    }

    // MARK: - Ambiguity flag

    /// Ambiguous requires more than one leftover display; one leftover, or zero, is not.
    func testAmbiguousFlagRequiresMoreThanOneLeftover() {
        let idA = DDCServiceMatcher.Identity(vendor: 0x10ac, product: 0x41c0, serial: 0x1)
        let idB = DDCServiceMatcher.Identity(vendor: 0x9999, product: 0x8888, serial: 0x2)
        let any = DDCServiceMatcher.Identity(vendor: 1, product: 1, serial: 1)

        // (a) two no-identity services, two leftovers.
        let ambiguousCase = DDCServiceMatcher.match(
            services: [nil, nil],
            displays: [(id: 1, identity: any), (id: 2, identity: any)]
        )
        XCTAssertTrue(ambiguousCase.ambiguous, "two leftovers should be ambiguous")

        // (b) one service, no matching display: one leftover, despite the unmatched service.
        let singleLeftoverCase = DDCServiceMatcher.match(
            services: [idA],
            displays: [(id: 1, identity: idB)]
        )
        XCTAssertFalse(singleLeftoverCase.ambiguous, "one leftover must not be ambiguous")

        // (c) more services than displays: zero leftovers after the identity claim.
        let zeroLeftoverCase = DDCServiceMatcher.match(
            services: [idA, nil, nil],
            displays: [(id: 1, identity: idA)]
        )
        XCTAssertFalse(zeroLeftoverCase.ambiguous, "zero leftovers must not be ambiguous")
    }

    // MARK: - Empty-input edges

    /// No services, or no displays, must not crash and is never ambiguous.
    func testEmptyInputsProduceEmptyResult() {
        let any = DDCServiceMatcher.Identity(vendor: 1, product: 1, serial: 1)

        // No services → nothing to assign; the lone display is simply unclaimed.
        let noServices = DDCServiceMatcher.match(services: [], displays: [(id: 1, identity: any)])
        XCTAssertEqual(noServices.byDisplayID, [:])
        XCTAssertEqual(unmatchedIndices(services: [], result: noServices), [])
        XCTAssertFalse(noServices.ambiguous)

        // No displays → every service is unmatched; still not ambiguous (0 leftovers).
        let noDisplays = DDCServiceMatcher.match(services: [nil], displays: [])
        XCTAssertEqual(noDisplays.byDisplayID, [:])
        XCTAssertEqual(unmatchedIndices(services: [nil], result: noDisplays), [0])
        XCTAssertFalse(noDisplays.ambiguous)

        // Both empty → trivially empty.
        let bothEmpty = DDCServiceMatcher.match(services: [], displays: [])
        XCTAssertEqual(bothEmpty.byDisplayID, [:])
        XCTAssertEqual(unmatchedIndices(services: [], result: bothEmpty), [])
        XCTAssertFalse(bothEmpty.ambiguous)
    }

    // MARK: - Derived helpers

    /// Service indices no display claimed, recomputed from `Result`'s mapping.
    private func unmatchedIndices(
        services: [DDCServiceMatcher.Identity?],
        result: DDCServiceMatcher.Result
    ) -> [Int] {
        let claimed = Set(result.byDisplayID.values)
        return services.indices.filter { !claimed.contains($0) }
    }
}
