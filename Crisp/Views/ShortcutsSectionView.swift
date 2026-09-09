import SwiftUI

/// Settings > Shortcuts: the curated list of named global-shortcut actions
/// (issue #61). Toggle HiDPI, plus brightness up and down for keyboards whose
/// brightness keys are missing or taken (issue #160); the bar for adding another
/// is "someone asked" (see the 2026-08-18 spec). Per-preset shortcuts live on the
/// presets themselves, not here. Expands in place per DESIGN.md.
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
                    || settings.brightnessDownShortcut != nil,
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
