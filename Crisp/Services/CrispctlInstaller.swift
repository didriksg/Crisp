import Foundation
import os

/// Puts the bundled crispctl on the PATH. Release builds carry it at
/// Contents/MacOS/crispctl; installing is one symlink into /usr/local/bin, behind
/// the same admin prompt the HiDPI override uses, because that directory is
/// root-owned on a stock Mac. The Homebrew cask makes the same link on install.
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
        // Where /usr/local/bin belongs to the user (Intel Macs with Homebrew) the
        // link needs no prompt, so try that first, the way VS Code's shell
        // command install does; a stale link of ours is replaced on the way.
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
}
