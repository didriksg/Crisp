import XCTest
import CoreGraphics

/// Headless tests for the gamma-adjustment persistence key/migration decision core (#32:
/// color temperature applied to the wrong display after a reboot). `GammaPersistenceKey`
/// compiles directly into this test target, so no `@testable import Crisp` is needed.
final class GammaPersistenceKeyTests: XCTestCase {

    // MARK: - Key construction

    /// The UUID key and the legacy key for the same display never collide.
    func testUUIDKeyIsDistinctFromLegacyKey() {
        let uuidKey = GammaPersistenceKey.uuidKey(for: "1234")
        let legacyKey = GammaPersistenceKey.legacyKey(for: 1234)
        XCTAssertNotEqual(uuidKey, legacyKey)
        XCTAssertTrue(uuidKey.contains("1234"))
        XCTAssertTrue(legacyKey.hasSuffix("1234"))
    }

    /// Two different displayIDs never produce the same legacy key.
    func testLegacyKeysDifferPerDisplayID() {
        XCTAssertNotEqual(GammaPersistenceKey.legacyKey(for: 1), GammaPersistenceKey.legacyKey(for: 2))
    }

    /// Two different UUIDs never produce the same UUID key.
    func testUUIDKeysDifferPerUUID() {
        XCTAssertNotEqual(GammaPersistenceKey.uuidKey(for: "aaa"), GammaPersistenceKey.uuidKey(for: "bbb"))
    }

    // MARK: - Migration: the core issue #32 fix

    /// A live display whose current id has a legacy entry migrates to its UUID key.
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

    /// Two live displays, only one with a matching legacy id: only that one migrates, to its own UUID.
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

    /// A stale legacy entry with no live display is never guessed at.
    func testStaleLegacyEntryWithNoLiveDisplayIsIgnored() {
        let targets = GammaPersistenceKey.migrationTargets(
            liveDisplays: [(id: 1, uuid: "uuid-A")],
            legacyDisplayIDsWithSavedState: [999]
        )
        XCTAssertEqual(targets, [])
    }

    /// After a reboot reassigns displayIDs, a legacy entry saved under the old id must not
    /// migrate onto the display now living under a different id.
    func testReassignedDisplayIDDoesNotMigrateUnderNewIdentity() {
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
        XCTAssertEqual(GammaPersistenceKey.migrationTargets(liveDisplays: [(id: 1, uuid: "uuid-A")],
                                                            legacyDisplayIDsWithSavedState: []), [])
        XCTAssertEqual(GammaPersistenceKey.migrationTargets(liveDisplays: [], legacyDisplayIDsWithSavedState: []), [])
    }
}
