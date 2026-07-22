import SwiftUI

/// Night Shift / True Tone quick toggles (system-level, via CoreBrightnessService).
/// Circular button + label below, modeled on the Dark Mode / Night Shift / True Tone row in the macOS 26 system displays panel.
struct ScreenEffectsView: View {
    @ObservedObject private var effects = CoreBrightnessService.shared

    var body: some View {
        HStack(spacing: 0) {
            if effects.darkModeAvailable {
                EffectCircleButton(
                    icon: "circle.lefthalf.filled",
                    label: "Dark Mode",
                    isOn: effects.darkModeEnabled
                ) {
                    effects.setDarkMode(!effects.darkModeEnabled)
                }
                .frame(maxWidth: .infinity)
            }
            if effects.nightShiftAvailable {
                EffectCircleButton(
                    icon: "moon.fill",
                    label: "Night Shift",
                    isOn: effects.nightShiftEnabled,
                    onFill: .orange,
                    onIcon: .white
                ) {
                    effects.setNightShift(!effects.nightShiftEnabled)
                }
                .frame(maxWidth: .infinity)
            }
            if effects.trueToneAvailable {
                EffectCircleButton(
                    icon: "sun.max.fill",
                    label: "True Tone",
                    isOn: effects.trueToneEnabled,
                    onFill: .blue,
                    onIcon: .white
                ) {
                    effects.setTrueTone(!effects.trueToneEnabled)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { effects.refresh() }
    }
}

/// No press feedback at all: the only visible change on click is the state
/// itself (fill + On/Off text). Anything else gets frozen mid-flight by the
/// dark mode crossfade snapshot and reads as a stuck button. No transaction
/// tampering here: that would also strip the panel's layout spring and make
/// the row jump instead of riding section expansions.
private struct InstantPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Same circular toggle style as the system panel: off = translucent dark
/// circle; on = the effect's own tint (white for Dark Mode, orange for Night
/// Shift, blue for True Tone), matching the native panel.
private struct EffectCircleButton: View {
    let icon: String
    let label: String
    let isOn: Bool
    var onFill: Color = .white
    var onIcon: Color = .black
    let action: () -> Void

    var body: some View {
        Button {
            // Instant state flip, like the native Control Center circles.
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(onFill) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isOn ? onIcon : .primary.opacity(0.85))
                }
                VStack(spacing: 1) {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.primary)
                    Text(isOn ? "On" : "Off")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InstantPressStyle())
        .accessibilityLabel("\(label), \(isOn ? "on" : "off")")
        .accessibilityAddTraits(.isButton)
    }
}
