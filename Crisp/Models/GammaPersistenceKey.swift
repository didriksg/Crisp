import Foundation
import CoreGraphics

/// Key-construction and migration logic for `GammaService`'s persisted per-display
/// adjustments (#32: a displayID-only key can apply saved color temperature to the
/// wrong display after macOS reassigns `CGDirectDisplayID`). Mirrors
/// `DisplayInfo.displayUUID`'s identity mechanism; owns no `UserDefaults` access.
enum GammaPersistenceKey {
    private static let base = "crisp.GammaService.savedAdjustment"

    /// Keyed by the stable `DisplayInfo.displayUUID`, which survives reassignment.
    static func uuidKey(for uuid: String) -> String {
        "\(base).uuid.\(uuid)"
    }

    /// Keyed by the volatile `CGDirectDisplayID`, from before #32's fix; consulted
    /// only at migration time.
    static func legacyKey(for displayID: CGDirectDisplayID) -> String {
        "\(base).\(displayID)"
    }

    /// One legacy entry that should move to its display's stable UUID key. Hashable
    /// (not just Equatable) so tests can compare migration batches order-independently.
    struct MigrationTarget: Hashable {
        let legacyKey: String
        let uuidKey: String
    }

    /// Which online displays have a legacy, displayID-keyed adjustment that should move
    /// to the stable UUID key. Only migrates a display whose *current* id matches a
    /// legacy entry; a legacy id with no live display is never guessed at (#32).
    static func migrationTargets(
        liveDisplays: [(id: CGDirectDisplayID, uuid: String)],
        legacyDisplayIDsWithSavedState: Set<CGDirectDisplayID>
    ) -> [MigrationTarget] {
        liveDisplays
            .filter { legacyDisplayIDsWithSavedState.contains($0.id) }
            .map { MigrationTarget(legacyKey: legacyKey(for: $0.id), uuidKey: uuidKey(for: $0.uuid)) }
    }
}
