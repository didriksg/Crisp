import SwiftUI

/// Speaker volume slider for external monitors with DDC volume (VCP 0x62),
/// shown under the brightness slider only once the probe confirmed support
/// (issue #23). Writes go through VolumeService's coalesced writer, so drags
/// don't flood the I2C bus that brightness shares. No click-glide like the
/// brightness slider: audio has no reason to fade, a jump is correct.
struct VolumeSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localVolume: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            BrightnessStepButton(systemName: "speaker.fill") { step(-volumeStep) }

            Slider(value: $localVolume, in: 0...100) { editing in
                isDragging = editing
                if !editing {
                    VolumeService.shared.setVolume(localVolume, for: display)
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Speaker volume")
            .accessibilityValue("\(Int(localVolume))%")
            .onChange(of: localVolume) { _, newValue in
                guard isDragging else { return }
                VolumeService.shared.setVolume(newValue, for: display)
            }

            BrightnessStepButton(systemName: "speaker.wave.3.fill") { step(volumeStep) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .task(id: display.displayID) { localVolume = display.volume }
        .onChange(of: display.volume) { _, newValue in
            // External change (volume keys, a probe adopting the OSD level).
            if !isDragging && abs(newValue - localVolume) >= 0.1 {
                localVolume = newValue
            }
        }
    }

    /// Volume change per tap of the speaker buttons: the fine quarter step the keys
    /// ask for with Option+Shift. A whole stop overshoots on a display that only
    /// takes DDC writes (the keys would move 100/16 = 6.25 of its range per press),
    /// and these buttons are what you nudge such a display with.
    private var volumeStep: Double { BrightnessKeySteps.fineStep }

    private func step(_ delta: Double) {
        VolumeService.shared.setVolume(display.volume + delta, for: display)
    }
}
