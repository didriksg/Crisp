import AppKit
import OSLog
import SwiftUI

/// Advanced Settings > About: what Crisp is, its version, an update check, a debug report
/// for bug reports, and the donation links (the panel's Support Crisp row has the same).
struct AdvancedAboutTab: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var copying = false
    @State private var copied = false

    private static let repo = "https://github.com/didriksg/Crisp"

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text(verbatim: "Crisp")
                .font(.title.bold())
                .padding(.top, 8)
            Text("Version \(UpdateService.shared.currentVersion)")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(spacing: 2) {
                Text("Every display control macOS hides, in one menu bar panel.")
                Text("Free and open source.")
            }
            .padding(.top, 14)

            HStack(spacing: 8) {
                Button("Check for Updates…") { UpdateService.shared.installUpdate() }
                Button(copied ? "Copied" : copying ? "Copying…" : "Copy Debug Info") { copyDebugInfo() }
                    .disabled(copying)
            }
            .padding(.top, 18)
            Text("Copies versions, displays and the last 30 minutes of Crisp's log to the clipboard, for a bug report.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Text("Crisp is free. Donations keep it signed and notarized:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 22)
            HStack(spacing: 6) {
                if SupportRow.prefersChinese {
                    Link(SupportRow.afdianTitle, destination: URL(string: SupportRow.afdian)!).handCursor()
                    Text(verbatim: "·").foregroundStyle(.secondary)
                }
                Link(destination: URL(string: SupportRow.kofi)!) { Text(verbatim: "Ko-fi") }.handCursor()
                Text(verbatim: "·").foregroundStyle(.secondary)
                Link(destination: URL(string: SupportRow.github)!) { Text(verbatim: "GitHub Sponsors") }.handCursor()
                if !SupportRow.prefersChinese {
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Link(SupportRow.afdianTitle, destination: URL(string: SupportRow.afdian)!).handCursor()
                }
            }
            .padding(.top, 4)

            HStack(spacing: 4) {
                Text(verbatim: "© 2026 Didrik Galteland ·")
                Link("MIT License", destination: URL(string: Self.repo + "/blob/main/LICENSE")!).handCursor()
                Text(verbatim: "·")
                Link("Acknowledgments", destination: URL(string: Self.repo + "/blob/main/ACKNOWLEDGMENTS.md")!).handCursor()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(.secondary)
            .padding(.top, 26)
            Link(destination: URL(string: Self.repo)!) { Text(verbatim: "github.com/didriksg/Crisp") }
                .handCursor()
                .font(.caption)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
    }

    private func copyDebugInfo() {
        copying = true
        let displays = displayManager.displays.map(DebugInfo.display)
        Task {
            // Reading the log takes about 2 s (measured), so it runs off the main thread.
            let log = await Task.detached { DebugInfo.recentLog() }.value
            let text = DebugReport.text(crisp: UpdateService.shared.currentVersion,
                                        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                        mac: DebugInfo.macModel(), displays: displays,
                                        log: log.lines, allRuns: log.allRuns)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copying = false
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Gathers the facts for `DebugReport`.
private enum DebugInfo {
    @MainActor
    static func display(_ display: DisplayInfo) -> DebugReport.Display {
        let mode = display.currentDisplayMode.map {
            "\($0.width) × \($0.height)\($0.isHiDPI ? " HiDPI" : ""), \($0.refreshRateString)"
        }
        return DebugReport.Display(name: display.name, isBuiltin: display.isBuiltin, isMain: display.isMain,
                                   vendor: display.vendorNumber, model: display.modelNumber, mode: mode)
    }

    /// The model identifier and chip, as the bug template asks: "Mac16,1, Apple M4 Pro".
    static func macModel() -> String {
        [sysctl("hw.model"), sysctl("machdep.cpu.brand_string")].compactMap { $0 }.joined(separator: ", ")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }

    /// Crisp's log lines from the last 30 minutes, the window the bug template's
    /// `log show --last 30m` uses, and the same lines: every run in that window (so a
    /// freeze or crash that ended in a relaunch is in it), info lines from this run only
    /// (macOS never saves info lines). The full store needs an admin user; anyone else
    /// gets this run alone, and `allRuns` says which.
    static func recentLog() -> (lines: [String], allRuns: Bool) {
        let local = try? OSLogStore.local()
        guard let store = local ?? (try? OSLogStore(scope: .currentProcessIdentifier)),
              let entries = try? store.getEntries(
                at: store.position(date: Date().addingTimeInterval(-30 * 60)),
                matching: NSPredicate(format: "subsystem == %@", "com.crisp.app")) else { return ([], false) }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\(format.string(from: $0.date)) [\($0.processIdentifier)] \($0.category): \($0.composedMessage)"
        }
        return (lines, local != nil)
    }
}

private extension View {
    /// The pointing hand over a link, as the panel's link rows show it.
    func handCursor() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
