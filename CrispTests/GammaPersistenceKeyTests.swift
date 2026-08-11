import XCTest
import CoreGraphics

/// Headless tests for the gamma-adjustment persistence key/migration decision core
/// (issue #32: color temperature applied to the wrong display after a reboot).
///
/// `GammaPersistenceKey` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DDCServiceMatcher`), so no `@testable import Crisp` is needed
/// (that would pull AppKit/IOKit and the private bridging header and defeat headless
/// purity). Each test names the behaviour or mutation it pins in a trailing comment.
final class GammaPersistenceKeyTests: XCTestCase {

    // MARK: - Key construction

    /// The UUID key embeds the display's stable identifier and is distinct from any
    /// legacy displayID key for the same display (no accidental collision between the
    /// two schemes).
    func testUUIDKeyIsDistinctFromLegacyKey() {
        let uuidKey = GammaPersistenceKey.uuidKey(for: "1234")
        let legacyKey = GammaPersistenceKey.legacyKey(for: 1234)
        XCTAssertNotEqual(uuidKey, legacyKey)
        XCTAssertTrue(uuidKey.contains("1234"))
        XCTAssertTrue(legacyKey.hasSuffix("1234"))
    }

    /// Two different displayIDs never produce the same legacy key.
    /// Kills mutation: legacy key construction dropping the displayID from the string.
    func testLegacyKeysDifferPerDisplayID() {
        XCTAssertNotEqual(GammaPersistenceKey.legacyKey(for: 1), GammaPersistenceKey.legacyKey(for: 2))
    }

    /// Two different UUIDs never produce the same UUID key.
    /// Kills mutation: UUID key construction dropping the uuid from the string.
    func testUUIDKeysDifferPerUUID() {
        XCTAssertNotEqual(GammaPersistenceKey.uuidKey(for: "aaa"), GammaPersistenceKey.uuidKey(for: "bbb"))
    }

    // MARK: - Migration: the core issue #32 fix

    /// A live display whose current id has a legacy saved entry migrates: exactly one
    /// target, mapping that display's legacy key to its UUID key.
    func testLiveDisplayWithMatchingLegacyEntryMigrates() {
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 501, uuid: "uuid-A")],
            legacyDisplayIDsWithSavedState: [501]
        )
        XCTAssertEqual(targets, [
            GammaPersistenceKey.MigrationTarget(
                legacyKey: GammaPersistenceKey.legacyKey(for: 501),
                uuidKey: GammaPersistenceKey.uuidKey(for: "uuid-A")
            )
        ])
    }

    /// A live display with no legacy entry produces no migration target: nothing to move.
    func testLiveDisplayWithoutLegacyEntryDoesNotMigrate() {
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 501, uuid: "uuid-A")],
            legacyDisplayIDsWithSavedState: []
        )
        XCTAssertEqual(targets, [])
    }

    /// The core regression this issue reports: two live displays, only one whose current
    /// id matches a legacy entry. Only that one display's legacy state migrates, and it
    /// migrates to *its own* UUID, never the other display's.
    /// Kills mutation: migrating every live display regardless of legacy-entry match, or
    /// pairing the wrong uuid with a legacy key.
    func testOnlyTheDisplayWithAMatchingLegacyIDMigratesOnDualExternalSetup() {
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 1, uuid: "uuid-left"), (id: 2, uuid: "uuid-right")],
            legacyDisplayIDsWithSavedState: [2]
        )
        XCTAssertEqual(targets, [
            GammaPersistenceKey.MigrationTarget(
                legacyKey: GammaPersistenceKey.legacyKey(for: 2),
                uuidKey: GammaPersistenceKey.uuidKey(for: "uuid-right")
            )
        ])
    }

    /// A stale legacy entry whose displayID belongs to no currently online display must
    /// never be guessed at: that display may simply be disconnected, and guessing which
    /// live display it "really" belongs to is the exact bug being fixed (applying a saved
    /// adjustment to the wrong physical display).
    /// Kills mutation: iterating `legacyDisplayIDsWithSavedState` instead of `liveDisplays`,
    /// which would fabricate a target with no real uuid to migrate to.
    func testStaleLegacyEntryWithNoLiveDisplayIsIgnored() {
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 1, uuid: "uuid-A")],
            legacyDisplayIDsWithSavedState: [999]
        )
        XCTAssertEqual(targets, [])
    }

    /// After a reboot reassigns displayIDs (macOS swaps which physical display gets which
    /// id), a legacy entry saved under the *old* id for a display now living under a
    /// different id must not be migrated onto that display: its current id no longer
    /// matches the legacy key, so nothing pairs it with a (possibly wrong) uuid.
    func testReassignedDisplayIDDoesNotMigrateUnderNewIdentity() {
        // Display "uuid-A" used to be id 1 (legacy key saved there); after reboot it is
        // id 2, and nothing saved a legacy entry under id 2.
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 2, uuid: "uuid-A")],
            legacyDisplayIDsWithSavedState: [1]
        )
        XCTAssertEqual(targets, [])
    }

    /// Multiple live displays can each migrate independently in the same pass.
    func testMultipleLiveDisplaysEachMigrateIndependently() {
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 1, uuid: "uuid-A"), (id: 2, uuid: "uuid-B"), (id: 3, uuid: "uuid-C")],
            legacyDisplayIDsWithSavedState: [1, 3]
        )
        XCTAssertEqual(Set(targets), Set([
            GammaPersistenceKey.MigrationTarget(
                legacyKey: GammaPersistenceKey.legacyKey(for: 1),
                uuidKey: GammaPersistenceKey.uuidKey(for: "uuid-A")
            ),
            GammaPersistenceKey.MigrationTarget(
                legacyKey: GammaPersistenceKey.legacyKey(for: 3),
                uuidKey: GammaPersistenceKey.uuidKey(for: "uuid-C")
            )
        ]))
    }

    // MARK: - Empty-input edges

    /// No live displays and/or no legacy state must not crash and must yield no targets.
    func testEmptyInputsProduceNoMigrationTargets() {
        XCTAssertEqual(GammaPersistenceKey.migrationTargets(liveDisplays: [], legacyDisplayIDsWithSavedState: [501]), [])
        XCTAssertEqual(GammaPersistenceKey.migrationTargets(liveDisplays: [(id: 1, uuid: "uuid-A")], legacyDisplayIDsWithSavedState: []), [])
        XCTAssertEqual(GammaPersistenceKey.migrationTargets(liveDisplays: [], legacyDisplayIDsWithSavedState: []), [])
    }
}

/// `MigrationTarget` needs `Hashable` only for the `Set` comparison in
/// `testMultipleLiveDisplaysEachMigrateIndependently`, where migration order is not
/// part of the contract; production code never needs `Set<MigrationTarget>`.
extension GammaPersistenceKey.MigrationTarget: Hashable {}
