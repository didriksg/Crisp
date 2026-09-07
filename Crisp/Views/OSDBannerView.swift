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
    /// Visible capsule size, measured from the native HUD on 26.5.1 once it
    /// has settled (see OSDBannerService.cornerRadius).
    static let size = CGSize(width: 292, height: 64)

    @ObservedObject var model: OSDBannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.title)
                // Smaller than the 13 pt it used to be, which is what read as
                // slightly off next to the HUD. Fitted at 2x, where a point is
                // two pixels: the same label drawn at 13, 12.5 and 12 next to
                // the HUD's own, matched to it by sliding one profile over the
                // other, puts the HUD at 12.33, 12.22 and 12.18, and its
                // ascenders (18.5 px against 19.7, 18.9 and 18.1) agree. The
                // glyphs below stay at 13.
                .font(.system(size: 12.25))
                // Explicit white, not .primary: the label colour is white at
                // 85 percent, which reads thinner and duller than the HUD's
                // label (peak 243 against its 251 over the same body).
                .foregroundStyle(.white)
                .lineLimit(1)
                // The row the smaller label costs is given back here, so the
                // track and the glyphs stay on the HUD's rows: the line box at
                // 13 pt is 16 pt tall, and this block's height is what places
                // everything under it.
                .frame(height: 16)
                // A quarter point down, which puts the baseline where the
                // HUD's sits: 22.75 pt under the top of the capsule, measured
                // at 2x on both.
                .offset(y: 0.25)
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
        // Two states, as the HUD has. At rest the line is drawn here. While
        // the pointer is on the capsule it is the control Crisp's own panel
        // rows use, which brings the growing knob, the drag, and the glass the
        // knob turns to while it is held.
        //
        // Why not that control at rest as well: AppKit draws a slider in an
        // inactive window in its inactive state, where the line is a grey
        // darker than its own groove (measured 71 against 82 over a backdrop
        // of 91) and the knob has no glass. Only a key window draws the real
        // one, and nothing else reaches it: the tint, trackFillColor, the
        // controlActiveState environment value, an overridden isKeyWindow and
        // a posted key notification were all measured and all changed nothing.
        // The panel takes key while the pointer is on it (see setHovering) and
        // it cannot hold key the rest of the time, since that would take the
        // keyboard away from whatever is in front on every key press.
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

    /// The fill ends on the tick for the level, not at a plain fraction of the
    /// track: measured settled on the system HUD, three steps up its fill ends
    /// on the third dot and eleven steps up on the eleventh, to a tenth of a
    /// pixel at 2x. The top of the range is the one exception, where it runs
    /// to the end of the track instead of stopping on the last dot.
    private func fillWidth(_ width: CGFloat) -> CGFloat {
        model.level >= 1 ? width : Self.tickInset + (width - 2 * Self.tickInset) * model.level
    }

    /// How far the tick dots' centres sit in from each end of the track.
    /// Measured on the system HUD at 2x: its track runs 450 px, its seventeen
    /// dots 74.5 to 505.5 from the same origin, so 9 px in at both ends.
    private static let tickInset: CGFloat = 4.5

    /// The 16 steps the keys move between: 2 pt dots, 6 pt below the track's
    /// centre line. The pointer takes them away, as it does on the HUD, by
    /// taking the whole resting track away.
    private var ticks: some View {
        HStack(spacing: 0) {
            ForEach(0..<17) { tick in
                Circle().fill(.white.opacity(0.11)).frame(width: 2, height: 2)
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
