import Foundation
import CoreGraphics

/// Pure key-construction and migration-decision logic for `GammaService`'s persisted
/// per-display adjustments (issue #32: macOS can reassign `CGDirectDisplayID` across
/// reboots/reconnects, so keying storage by displayID alone can apply a saved color
/// temperature to the wrong physical display on a dual-external setup). Mirrors the
/// identity mechanism already used for brightness-key display selection:
/// `DisplayInfo.displayUUID`.
///
/// Owns no `UserDefaults` access itself, so it can be exercised headlessly from an
/// `XCTestCase` (same route as `DDCServiceMatcher`).
enum GammaPersistenceKey {
    private static let base = "crisp.GammaService.savedAdjustment"

    /// Current storage key: keyed by the stable `DisplayInfo.displayUUID`, which
    /// survives a `CGDirectDisplayID` reassignment.
    static func uuidKey(for uuid: String) -> String {
        "\(base).uuid.\(uuid)"
    }

    /// Legacy storage key from before issue #32's fix: keyed by the volatile
    /// `CGDirectDisplayID`. Still consulted once, at migration time, for a display
    /// whose current id happens to still match what was saved under it.
    static func legacyKey(for displayID: CGDirectDisplayID) -> String {
        "\(base).\(displayID)"
    }

    /// One legacy entry that should move to its display's stable UUID key.
    struct MigrationTarget: Equatable {
        let legacyKey: String
        let uuidKey: String
    }

    /// Pure decision core for the legacy-to-UUID migration: which currently online
    /// displays have a legacy, displayID-keyed saved adjustment that should move under
    /// the stable UUID key.
    ///
    /// A display's legacy entry migrates only when its *current* `CGDirectDisplayID` is
    /// in `legacyDisplayIDsWithSavedState` (the caller determines this by checking
    /// storage for exactly the ids the live displays currently have, nothing else).
    /// Legacy keys belonging to a displayID that isn't live right now are never
    /// considered here: guessing at those is exactly the bug being fixed (a stale
    /// entry silently reassigned to the wrong physical display after a reboot).
    static func migrationTargets(
        liveDisplays: [(id: CGDirectDisplayID, uuid: String)],
        legacyDisplayIDsWithSavedState: Set<CGDirectDisplayID>
    ) -> [MigrationTarget] {
        liveDisplays
            .filter { legacyDisplayIDsWithSavedState.contains($0.id) }
            .map { MigrationTarget(legacyKey: legacyKey(for: $0.id), uuidKey: uuidKey(for: $0.uuid)) }
    }
}
