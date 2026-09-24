import Foundation
import os

/// Puts the bundled crispctl (Contents/MacOS/crispctl) on the PATH via a symlink into
/// /usr/local/bin, behind the same admin prompt as the HiDPI override (root-owned dir).
@MainActor
enum CrispctlInstaller {
    private static let log = Logger(subsystem: "com.crisp.app", category: "app")
    static let linkPath = "/usr/local/bin/crispctl"
    static let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/crispctl").path

    /// False on a dev build (dev.sh swaps the app binary only) and while the app
    /// runs translocated from a DMG or Downloads, where the bundle path is a
    /// temporary mount and a link to it would dangle on the next launch.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: bundledPath)
            && !bundledPath.contains("/AppTranslocation/")
    }

    /// The link must point at this bundle: a moved app offers the install again.
    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundledPath
    }

    static func install() {
        // Try unprivileged first (VS Code's shell command install does the same): works
        // where /usr/local/bin belongs to the user, e.g. Intel Macs with Homebrew.
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil { try? fm.removeItem(atPath: linkPath) }
        if (try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bundledPath)) != nil { return }
        // Single-quoted for the shell, then escaped for the AppleScript literal.
        let shellPath = bundledPath.replacingOccurrences(of: "'", with: "'\\''")
        let command = "mkdir -p /usr/local/bin && ln -sfn '\(shellPath)' \(linkPath)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if let error = HiDPIService.shared.executePrivilegedCommand(command) {
            log.error("crispctl install failed: \(error, privacy: .public)")
        }
    }

    /// Removes the link; a regular file at that path is not ours and is left alone.
    static func uninstall() {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return }
        if (try? FileManager.default.removeItem(atPath: linkPath)) != nil { return }
        if let error = HiDPIService.shared.executePrivilegedCommand("rm -f \(linkPath)") {
            log.error("crispctl uninstall failed: \(error, privacy: .public)")
        }
    }
}
