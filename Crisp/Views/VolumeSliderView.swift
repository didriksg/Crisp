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
            // Same size as the brightness slider above it (docs/ui-notes.md).
            .controlSize(SystemLook.isMacOS27OrLater ? .regular : .small)
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

    /// Volume change per tap of the speaker buttons, matching the volume keys' step.
    private var volumeStep: Double { 100.0 / 16.0 }

    private func step(_ delta: Double) {
        VolumeService.shared.setVolume(display.volume + delta, for: display)
    }
}
