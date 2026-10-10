import SwiftUI

/// Per-display maximum raw volume value, shown under Audio Adjustment.
/// The right end restores the full hardware range by clearing the ceiling.
struct VolumeRangeView: View {
    @ObservedObject var display: DisplayInfo
    /// Slider position; seeded from the stored ceiling, the hardware max = full.
    @State private var localValue: Double = 100

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundColor(.blue)
                .frame(width: 18)
                .font(.caption)

            Text("DDC Value Range")
                .font(.caption)
                .frame(width: 96, alignment: .leading)

            // Round in the binding, not via `step:`, which would draw tick marks.
            Slider(value: Binding(
                get: { shownValue },
                set: { localValue = $0.rounded() }
            ), in: 1...sliderTop) { editing in
                if !editing { commit() }
            }
            .accessibilityLabel("DDC Value Range")
            .accessibilityValue("\(Int(shownValue))")

            Text("\(Int(shownValue))")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help("Caps the DDC volume scale for finer steps. Slide to the right end for the full range.")
        .task(id: display.displayID) { seed() }
    }

    /// The hardware top; the slider's upper bound and the "full range" position.
    private var top: Double { Double(VolumeService.shared.hardwareMax(for: display)) }
    /// Sliders misbehave with an empty range; a 1-value scale is pathological anyway.
    private var sliderTop: Double { max(2, top) }
    /// Clamped on read so a probe landing after the seed still shows the real top.
    private var shownValue: Double { min(localValue, top) }

    private func seed() {
        localValue = Double(VolumeService.shared.ceiling(for: display) ?? VolumeService.shared.hardwareMax(for: display))
    }

    private func commit() {
        VolumeService.shared.setCeiling(UInt16(max(1, shownValue)), for: display)
    }
}
