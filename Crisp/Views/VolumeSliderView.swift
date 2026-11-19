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

/// The panel block that holds the combined volume slider, under combined brightness
/// and the Combined title.
struct CombinedVolumeBlock: View {
    let displays: [DisplayInfo]

    /// With Show Combined Volume and Show Volume Sliders on, and two or more speaker monitors.
    @MainActor
    static func isShown(_ displays: [DisplayInfo]) -> Bool {
        let settings = SettingsService.shared
        return settings.showCombinedVolume && settings.showVolumeSliders
            && displays.filter { !$0.isBuiltin && $0.volumeSupported }.count > 1
    }

    var body: some View {
        // No divider: it sits under the Combined title with combined brightness.
        CombinedVolumeSliderView(displays: displays.filter { !$0.isBuiltin })
            .padding(.bottom, 4)
    }
}

/// One speaker volume slider for every external with DDC volume, in its own panel block
/// under the combined brightness one. It sets them all to the same level.
struct CombinedVolumeSliderView: View {
    /// The externals; `speakers` filters on each use, since a volume probe can answer
    /// after the panel opens.
    let displays: [DisplayInfo]
    @State private var localVolume: Double = 0
    @State private var isDragging: Bool = false

    private var speakers: [DisplayInfo] { displays.filter(\.volumeSupported) }

    private var averageVolume: Double {
        let speakers = speakers
        guard !speakers.isEmpty else { return 0 }
        return speakers.map(\.volume).reduce(0, +) / Double(speakers.count)
    }

    var body: some View {
        HStack(spacing: 8) {
            BrightnessStepButton(systemName: "speaker.fill") { step(-volumeStep) }

            Slider(value: $localVolume, in: 0...100) { editing in
                isDragging = editing
                if !editing { setAll(localVolume) }
            }
            .controlSize(SystemLook.isMacOS27OrLater ? .regular : .small)
            .accessibilityLabel("Combined speaker volume")
            .accessibilityValue("\(Int(localVolume))%")
            .onChange(of: localVolume) { _, newValue in
                guard isDragging else { return }
                setAll(newValue)
            }

            BrightnessStepButton(systemName: "speaker.wave.3.fill") { step(volumeStep) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            // Follows the displays' volume (keys, per-display sliders) while idle.
            ForEach(displays) { display in
                VolumeProbe(display: display) {
                    if !isDragging { localVolume = averageVolume }
                }
            }
        }
        .onAppear { localVolume = averageVolume }
    }

    /// Same step as the per-display buttons and the volume keys.
    private var volumeStep: Double { BrightnessKeySteps.step }

    private func step(_ delta: Double) {
        localVolume = max(0, min(100, averageVolume + delta))
        setAll(localVolume)
    }

    private func setAll(_ volume: Double) {
        for display in speakers {
            VolumeService.shared.setVolume(volume, for: display)
        }
    }
}

/// Invisible observer of one display's volume, the counterpart of BrightnessProbe.
private struct VolumeProbe: View {
    @ObservedObject var display: DisplayInfo
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: display.volume) { _, _ in onChange() }
    }
}
