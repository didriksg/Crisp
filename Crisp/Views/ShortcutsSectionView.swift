import SwiftUI

/// Settings > Shortcuts: the curated list of named global-shortcut actions
/// (issue #61). Toggle HiDPI, brightness and volume up/down, and mute, for
/// keyboards whose media keys are missing or taken (issue #160). The volume
/// rows mirror the volume keys (issue #23); the bar for adding another is
/// "someone asked". Per-preset shortcuts live on the presets themselves, not
/// here. Expands in place per DESIGN.md.
struct ShortcutsSection: View {
    @ObservedObject private var settings = SettingsService.shared
    // Owned by SettingsView so its panel-close reset collapses this section
    // like every other.
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "command",
                iconActive: settings.hidpiShortcut != nil
                    || settings.brightnessUpShortcut != nil
                    || settings.brightnessDownShortcut != nil
                    || settings.volumeUpShortcut != nil
                    || settings.volumeDownShortcut != nil
                    || settings.muteShortcut != nil,
                // No combo subtitle: the header names a category, and a single
                // binding there reads as the section's own shortcut. Bindings
                // show only on their action rows inside.
                label: "Keyboard Shortcuts",
                isExpanded: $expanded
            )
            if expanded {
                ShortcutRecorderRow(
                    label: "Toggle HiDPI",
                    // Commits immediately (no form): store, take the combo off
                    // whatever else held it, re-register.
                    shortcut: binding(\.hidpiShortcut) { settings.hidpiShortcut = $0 },
                    leadingInset: 34
                )
                caption("Switches the display under the pointer between HiDPI and low resolution.")
                ShortcutRecorderRow(
                    label: "Brightness Up",
                    shortcut: binding(\.brightnessUpShortcut) { settings.brightnessUpShortcut = $0 },
                    leadingInset: 34
                )
                ShortcutRecorderRow(
                    label: "Brightness Down",
                    shortcut: binding(\.brightnessDownShortcut) { settings.brightnessDownShortcut = $0 },
                    leadingInset: 34
                )
                caption("Steps brightness like the brightness keys, on the same displays. For keyboards without them.")
                ShortcutRecorderRow(
                    label: "Volume Up",
                    shortcut: binding(\.volumeUpShortcut) { settings.volumeUpShortcut = $0 },
                    leadingInset: 34
                )
                ShortcutRecorderRow(
                    label: "Volume Down",
                    shortcut: binding(\.volumeDownShortcut) { settings.volumeDownShortcut = $0 },
                    leadingInset: 34
                )
                ShortcutRecorderRow(
                    label: "Mute",
                    shortcut: binding(\.muteShortcut) { settings.muteShortcut = $0 },
                    leadingInset: 34
                )
                caption("Presses the volume keys for the selected sound output. Needs Accessibility, like the brightness keys.")
            }
        }
    }

    private func binding(_ path: KeyPath<SettingsService, KeyboardShortcut?>,
                         assign: @escaping (KeyboardShortcut?) -> Void) -> Binding<KeyboardShortcut?> {
        Binding(
            get: { settings[keyPath: path] },
            set: { newValue in settings.assignStaticShortcut(newValue, assign: assign) }
        )
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.leading, 34)
            .padding(.bottom, 4)
    }
}
