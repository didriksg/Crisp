import CoreGraphics
import Foundation

/// Per-display persistence store for native underscan settings.
/// Backed by an injectable `UserDefaults` so production uses `UserDefaults.standard`
/// (automatically scoped to the app's bundle identifier) and automated tests run in
/// complete isolation.
final class UnderscanStore: @unchecked Sendable {
    static let storageKey = "crisp.underscan.v1.displays"
    static let migrationVersionKey = "crisp.underscan.v1.migrated"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [String: DisplayUnderscanSettings] {
        lock.withLock {
            loadAllUnlocked()
        }
    }

    func settings(forKey key: String) -> DisplayUnderscanSettings {
        lock.withLock {
            loadAllUnlocked()[key] ?? DisplayUnderscanSettings()
        }
    }

    func hasStoredSettings(forKey key: String) -> Bool {
        lock.withLock {
            loadAllUnlocked()[key] != nil
        }
    }

    func save(_ settings: DisplayUnderscanSettings, forKey key: String) {
        lock.withLock {
            var all = loadAllUnlocked()
            all[key] = settings
            saveAllUnlocked(all)
        }
    }

    func removeSettings(forKey key: String) {
        lock.withLock {
            var all = loadAllUnlocked()
            all.removeValue(forKey: key)
            saveAllUnlocked(all)
        }
    }

    /// Disables underscan and clears suspension/experimental flags for every stored display,
    /// keeping entries reset to 100% for predictable recovery.
    func disableAllSettings() {
        lock.withLock {
            var all = loadAllUnlocked()
            for key in all.keys {
                var entry = all[key] ?? DisplayUnderscanSettings()
                entry.isEnabled = false
                entry.requestedPercentage = UnderscanValue.defaultPercentage
                entry.lastKnownGoodPercentage = UnderscanValue.defaultPercentage
                entry.forceEnableExperimental = false
                entry.autoRestoreSuspended = false
                entry.consecutiveRestoreFailures = 0
                entry.lastApplicationStatus = UnderscanApplyStatus.resetToFullScreen.persistedSummary
                all[key] = entry
            }
            saveAllUnlocked(all)
        }
    }

    /// Safely migrates any legacy `CGDirectDisplayID`-keyed underscan entries onto their
    /// live stable display keys. Never guesses for offline display IDs and never overwrites
    /// an already-migrated stable key.
    @discardableResult
    func migrateLegacyDisplayIDEntries(for liveDisplays: [DisplayUnderscanDescriptor]) -> Int {
        lock.withLock {
            var all = loadAllUnlocked()
            var migratedCount = 0

            for display in liveDisplays {
                let legacyKey = DisplayUnderscanIdentity.legacyDisplayIDKey(for: display.displayID)
                guard let legacyData = defaults.data(forKey: legacyKey),
                      let legacySettings = try? JSONDecoder().decode(DisplayUnderscanSettings.self, from: legacyData) else {
                    continue
                }
                let stableKey = DisplayUnderscanIdentity.stableKey(for: display, among: liveDisplays)
                if all[stableKey] == nil {
                    all[stableKey] = legacySettings
                    migratedCount += 1
                }
                defaults.removeObject(forKey: legacyKey)
            }

            if migratedCount > 0 {
                saveAllUnlocked(all)
            }
            defaults.set(true, forKey: Self.migrationVersionKey)
            return migratedCount
        }
    }

    // MARK: - Private

    private func loadAllUnlocked() -> [String: DisplayUnderscanSettings] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: DisplayUnderscanSettings].self, from: data)) ?? [:]
    }

    private func saveAllUnlocked(_ map: [String: DisplayUnderscanSettings]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
