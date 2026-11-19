import SwiftUI

/// "Auto Brightness" section, follows builtin screen brightness and adjusts external display brightness automatically.
struct AutoBrightnessView: View {
    @StateObject private var service = AutoBrightnessService.shared
    @EnvironmentObject var displayManager: DisplayManager

    /// From the display list, not the service's own read: that read exists only once
    /// tracking runs, so a Mac with no built-in display showed the switch until it was
    /// turned on, then locked it on.
    private var builtinUnavailable: Bool {
        !displayManager.displays.contains(where: \.isBuiltin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "sun.and.horizon.fill", color: .orange, active: service.isEnabled)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Brightness")
                        .font(.body)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { newValue in withAnimation(.panelResize) { service.isEnabled = newValue } }
                ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(builtinUnavailable && !service.isEnabled)  // can always be turned off
                    .accessibilityLabel("Auto Brightness")
                    // VoiceOver-only state confirmation; the visible subtitle
                    // intentionally stays static (native toggles don't switch text).
                    .accessibilityValue(service.isEnabled ? "Syncing with built-in display brightness" : "Off")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            // Relative vs absolute mapping. Revealed with the panel spring while
            // tracking is on, instead of popping in at full height.
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep display offsets")
                        .font(.callout)
                    Text("External displays follow the built-in but keep the difference you set")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $service.relativeMode)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.vertical, 3)
            .padding(.trailing, 12)
            // Align the label under the parent's title: 12 pad + 26 icon + 8 spacing.
            .padding(.leading, 46)
            .curtainReveal(service.isEnabled && !builtinUnavailable)
        }
    }

    private var statusText: String {
        builtinUnavailable
            ? String(localized: "No built-in display detected")
            : String(localized: "External displays follow the built-in display's brightness")
    }
}
