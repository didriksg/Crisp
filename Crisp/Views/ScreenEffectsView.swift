import SwiftUI

/// Night Shift / True Tone quick toggles (system-level, via CoreBrightnessService).
/// Circular button + label below, modeled on the Dark Mode / Night Shift / True Tone row in the macOS 26 system displays panel.
struct ScreenEffectsView: View {
    @ObservedObject private var effects = CoreBrightnessService.shared

    var body: some View {
        HStack(spacing: 0) {
            if effects.darkModeAvailable {
                EffectCircleButton(
                    glyph: .darkMode,
                    label: "Dark Mode",
                    isOn: effects.darkModeEnabled
                ) {
                    effects.setDarkMode(!effects.darkModeEnabled)
                }
                .frame(maxWidth: .infinity)
            }
            if effects.nightShiftAvailable {
                EffectCircleButton(
                    glyph: .nightShift,
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
                    glyph: .trueTone,
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

/// No press feedback: the dark mode crossfade snapshot freezes anything else
/// mid-flight (reads as a stuck button), and transaction tampering would also
/// strip the panel's layout spring, making the row jump instead of riding
/// section expansions.
private struct InstantPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Same circular toggle style as the system panel: off is a translucent dark
/// circle, on is the effect's own tint (white/orange/blue for Dark Mode/Night
/// Shift/True Tone).
private struct EffectCircleButton: View {
    let glyph: EffectGlyph
    let label: String
    let isOn: Bool
    var onFill: Color = .white
    var onIcon: Color = .black
    let action: () -> Void

    /// Resolve the label key through NSLocalizedString; Text(String) does not
    /// auto-localize unlike Text(LocalizedStringKey).
    private var localizedLabel: String {
        NSLocalizedString(label, comment: "")
    }

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(onFill) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: 36, height: 36)
                    EffectGlyphView(glyph: glyph, color: isOn ? onIcon : .primary.opacity(0.85))
                }
                VStack(spacing: 1) {
                    Text(localizedLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 11))
                        .foregroundColor(.secondaryReadable)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InstantPressStyle())
        .accessibilityLabel(isOn ? "\(localizedLabel), on" : "\(localizedLabel), off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Effect glyphs
//
// Dark Mode uses the public SF Symbol `circle.lefthalf.filled`. Night Shift and True
// Tone have no public symbol, so they are hand-drawn (sun-with-moon, sun-with-stripes)
// as original vector shapes rather than reproductions of Apple's private glyphs.

enum EffectGlyph { case darkMode, nightShift, trueTone }

private struct EffectGlyphView: View {
    let glyph: EffectGlyph
    let color: Color

    var body: some View {
        switch glyph {
        case .darkMode:
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(color)
        case .nightShift:
            ZStack { SunRaysGlyph(color: color); CrescentGlyph(color: color) }
                .frame(width: 18, height: 18)
        case .trueTone:
            ZStack { SunRaysGlyph(color: color); StripedDiscGlyph(color: color) }
                .frame(width: 18, height: 18)
        }
    }
}

/// Eight short rounded rays around the center, the shared base of the Night Shift
/// and True Tone glyphs.
private struct SunRaysGlyph: View {
    let color: Color
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 1.6, height: 3)
                    .offset(y: -6.9)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Crescent moon (a disc with an offset disc erased), the Night Shift center.
private struct CrescentGlyph: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7.5, height: 7.5)
            .overlay(
                Circle()
                    .fill(color)
                    .frame(width: 6.5, height: 6.5)
                    .offset(x: 2.3, y: -0.7)
                    .blendMode(.destinationOut)
            )
            .compositingGroup()
    }
}

/// Disc crossed by horizontal gaps (a striped circle), the True Tone center.
private struct StripedDiscGlyph: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7.5, height: 7.5)
            .overlay(
                VStack(spacing: 0.9) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(color).frame(width: 7.5, height: 0.8)
                    }
                }
                .blendMode(.destinationOut)
            )
            .compositingGroup()
    }
}
