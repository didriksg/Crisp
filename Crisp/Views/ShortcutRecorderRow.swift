import SwiftUI
import os.log

/// Same category as HotkeyService so one log stream shows the whole chain.
private let recorderLog = Logger(subsystem: "com.crisp.app", category: "hotkey")

/// One record-in-place shortcut row, shared by Settings > Shortcuts and the
/// preset form (issue #61). Tapping toggles recording; a local keyDown
/// monitor captures the next valid combo, Esc cancels. All registered hotkeys
/// are suspended while recording so bound combos can be re-captured. Commit
/// semantics live in the binding: Settings commits immediately, the preset
/// form holds the value in @State until Save.
struct ShortcutRecorderRow: View {
    let label: String
    @Binding var shortcut: KeyboardShortcut?
    /// Extra leading inset so the row aligns under a section's icon chip.
    var leadingInset: CGFloat = 0
    @State private var isRecording = false
    @State private var monitor: Any? = nil
    @State private var isHovered = false
    /// Identity for the takeover notification, so this row can ignore its own
    /// post (see startRecording).
    @State private var rowID = UUID()

    var body: some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(label))
                .font(.body)
            Spacer()
            if isRecording {
                Text("Type shortcut… (Esc to cancel)")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else if let shortcut {
                Text(verbatim: shortcut.display)
                    .font(.callout)
                    .foregroundColor(.secondaryReadable)
                Button {
                    self.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Shortcut")
            } else {
                Text("Record Shortcut")
                    .font(.caption)
                    .foregroundColor(.secondaryReadable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.leading, leadingInset)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            if isRecording { stopRecording() } else { startRecording() }
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // The panel resigns key on close; an in-flight recording can't finish.
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispStopShortcutRecording)) { note in
            // The preset form is committing/closing (nil object), or another row
            // is taking over. Skip our own takeover post (see startRecording):
            // SwiftUI can deliver it back to us after the monitor is installed.
            if note.object as? UUID != rowID { stopRecording() }
        }
        // The preset form unmounts on Save/Cancel; don't leak the monitor.
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        // Only one recording at a time: stop any other mid-recording row first.
        // Tagged with our own id, or SwiftUI delivering it back to us after this
        // function returns would cancel the recording we just started.
        NotificationCenter.default.post(name: .crispStopShortcutRecording, object: rowID)
        isRecording = true
        // Free every bound combo so any of them can be re-recorded here.
        HotkeyService.shared.beginSuspension()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            recorderLog.info("recorder keyDown: code \(event.keyCode)")
            if event.keyCode == 53 {  // kVK_Escape cancels
                stopRecording()
                return nil
            }
            let label = KeyboardShortcut.keyLabel(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            // nil = no ⌘⌥⌃ anchor yet (typing, not a shortcut): swallow, keep listening.
            if let recorded = KeyboardShortcut(
                keyCode: event.keyCode, nsModifierFlags: event.modifierFlags.rawValue,
                keyLabel: label) {
                shortcut = recorded
                stopRecording()
            }
            return nil
        }
        recorderLog.info("recording started: \(label, privacy: .public)")
    }

    private func stopRecording() {
        guard monitor != nil else { return }
        recorderLog.info("recording stopped: \(label, privacy: .public)")
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotkeyService.shared.endSuspension()
    }
}
