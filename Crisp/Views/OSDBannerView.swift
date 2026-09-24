import SwiftUI

/// State behind one OSD banner: the display name, which glyph pair to show,
/// and the level as 0...1. Mutated by OSDBannerService on every key press;
/// the panel's hosting view redraws from it.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerModel: ObservableObject {
    @Published var title = ""
    @Published var image: OSDImage = .brightness
    @Published var level = 0.0
    /// Whether the pointer is on the capsule. The system HUD grows a knob and
    /// a close badge then, and holds itself up until the pointer leaves.
    @Published var hovering = false
    /// Takes a level the pointer set on the track, 0...1 of the same scale the
    /// banner shows. Set by OSDBannerService for the display in question.
    var slide: ((Double) -> Void)?
    /// Takes the close badge's click.
    var dismiss: (() -> Void)?
}

/// The banner OSDBannerService draws on macOS 26: the display name over a
/// level track with a symbol at each end, in the style of the system's own
/// brightness and volume capsule under the menu bar. Sizes and paddings are
/// tuned against a screenshot of the native capsule on the same screen.
@available(macOS 26.0, *)
struct OSDBannerView: View {
    /// Visible capsule size, measured from the native HUD once it has settled
    /// (see OSDBannerService.cornerRadius).
    static let size = CGSize(width: 292, height: 64)

    @ObservedObject var model: OSDBannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.title)
                // Fitted at 2x against the native label; glyphs below stay at 13.
                // Measured: see docs/osd-notes.md (Label size and position).
                .font(.system(size: 12.25))
                // Explicit white at 85 percent, not .primary, which reads too
                // thin and dull next to the HUD's own label.
                .foregroundStyle(.white)
                .lineLimit(1)
                // 16 pt (the line box at 13 pt), so the track and glyphs below
                // land on the HUD's own rows.
                .frame(height: 16)
                // Puts the baseline where the HUD's sits; macOS 27 carries its
                // label one row higher.
                .offset(y: OSDBannerService.drawsMacOS27Capsule ? -0.75 : 0.25)
            HStack(spacing: 4) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                track
                Image(systemName: trailingSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    // Mute keeps the slot so the track does not grow 27 pt.
                    .opacity(model.image == .mute ? 0 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var track: some View {
        // Two states, as the HUD has: a plain line at rest, or (while the
        // pointer is on the capsule) the same control the panel's rows use,
        // with its growing knob and glass. Not that control at rest too:
        // AppKit only draws it live in a key window, and the panel can't hold
        // key outside a hover or every key press would steal focus.
        // Measured: see docs/osd-notes.md (Track (inactive vs. key window)).
        Group {
            if model.hovering {
                Slider(value: Binding(get: { model.level },
                                      set: { level in
                                          model.level = level
                                          model.slide?(level)
                                      }),
                       in: 0...1)
                    .controlSize(.small)
                    .tint(.white)
            } else {
                restingTrack
            }
        }
        // The row the glyphs set, so the bar lands on the HUD's line.
        .frame(height: 16)
        // The native track sits a point above the glyph centre line.
        .offset(y: -1)
    }

    /// The line with no pointer on it: groove, fill to the step, and the dots.
    /// No knob, which is the HUD at rest too.
    private var restingTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07)).frame(height: 4)
                Capsule().fill(.white).frame(width: fillWidth(geo.size.width), height: 4)
                ticks
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The fill ends on the tick for the level, not a plain fraction of the
    /// track, except at the top of the range, which runs to the track's end.
    /// Measured: see docs/osd-notes.md (Track (inactive vs. key window)).
    private func fillWidth(_ width: CGFloat) -> CGFloat {
        model.level >= 1 ? width : Self.tickInset + (width - 2 * Self.tickInset) * model.level
    }

    /// How far the tick dots' centres sit in from each end of the track.
    /// Measured: see docs/osd-notes.md (Track (inactive vs. key window)).
    private static let tickInset: CGFloat = 4.5

    /// The 16 steps the keys move between: 2 pt dots, 6 pt below the track's
    /// centre line. The pointer takes them away, as it does on the HUD, by
    /// taking the whole resting track away.
    private var ticks: some View {
        HStack(spacing: 0) {
            ForEach(0..<17) { tick in
                // macOS 27 draws the dots brighter.
                // Measured: see docs/osd-notes.md (Track (inactive vs. key window)).
                Circle().fill(.white.opacity(OSDBannerService.drawsMacOS27Capsule ? 0.19 : 0.11))
                    .frame(width: 2, height: 2)
                if tick < 16 { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, Self.tickInset - 1)
        .offset(y: 6)
    }

    /// Eject never reaches this path (BrightnessKeyService sends only
    /// brightness, volume and mute), it takes the brightness glyphs.
    private var leadingSymbol: String {
        switch model.image {
        case .volume: return "speaker.fill"
        case .mute: return "speaker.slash.fill"
        case .brightness, .eject: return "sun.min.fill"
        }
    }

    /// Mute hides this symbol but keeps its slot, see body.
    private var trailingSymbol: String {
        switch model.image {
        case .volume, .mute: return "speaker.wave.3.fill"
        case .brightness, .eject: return "sun.max.fill"
        }
    }
}
