import Foundation

/// Centralizes bundle-level isolation rules so a custom development build (for example
/// `com.reconditum.crisp`) never collides with an official `/Applications/Crisp.app`
/// install's lock file, control socket, Application Support folder, Login Item registration,
/// or Sparkle auto-update feed, while leaving production `com.crisp.app` behavior untouched.
enum AppIsolation {
    static let productionBundleIdentifier = "com.crisp.app"
    static let disableUpdaterInfoKey = "CrispDisableUpdater"

    /// True whenever the running bundle carries a non-production bundle identifier.
    /// When `bundleIdentifier` is nil (e.g. a bare swiftc binary), returns false unless
    /// explicitly overridden, matching existing upstream `make compile` behavior.
    static func isIsolatedBuild(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let id = bundleIdentifier, !id.isEmpty else { return false }
        return id != productionBundleIdentifier
    }

    /// Stable filesystem-safe token derived from a non-production bundle identifier.
    static func sanitizedIdentifier(_ bundleIdentifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = bundleIdentifier.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let cleaned = String(mapped)
        return cleaned.isEmpty ? "dev" : cleaned
    }

    /// Single-instance lock filename inside `NSTemporaryDirectory()`.
    static func lockFileName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard isIsolatedBuild(bundleIdentifier: bundleIdentifier),
              let id = bundleIdentifier else {
            return "crisp.lock"
        }
        return "crisp-\(sanitizedIdentifier(id)).lock"
    }

    /// Local control Unix socket filename inside `FileManager.default.temporaryDirectory`.
    static func controlSocketFileName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard isIsolatedBuild(bundleIdentifier: bundleIdentifier),
              let id = bundleIdentifier else {
            return "crispctl.sock"
        }
        return "crispctl-\(sanitizedIdentifier(id)).sock"
    }

    /// Subdirectory under `~/Library/Application Support/`.
    static func applicationSupportDirectoryName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard isIsolatedBuild(bundleIdentifier: bundleIdentifier),
              let id = bundleIdentifier else {
            return "Crisp"
        }
        return "Crisp-\(sanitizedIdentifier(id))"
    }

    /// Whether Sparkle should start its background update controller.
    /// Always disabled for isolated builds or when Info.plist opts out / lacks `SUFeedURL`,
    /// preventing upstream releases from overwriting a custom development build.
    static func shouldStartSparkleUpdater(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        guard !isIsolatedBuild(bundleIdentifier: bundleIdentifier) else { return false }
        if infoDictionary?[disableUpdaterInfoKey] as? Bool == true { return false }
        if let feed = infoDictionary?["SUFeedURL"] as? String, !feed.isEmpty {
            return true
        }
        // Preserve upstream behavior for bare dev binaries whose Info.plist may omit SUFeedURL
        // only when running under the production identifier or no bundle id at all.
        return bundleIdentifier == nil
    }

    /// Whether first launch should automatically register Launch at Login via SMAppService.
    /// Isolated development builds never touch Login Items automatically on first launch.
    static func shouldAutoRegisterLaunchAtLogin(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        !isIsolatedBuild(bundleIdentifier: bundleIdentifier)
    }
}
