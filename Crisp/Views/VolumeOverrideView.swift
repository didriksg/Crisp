import SwiftUI

/// Per-display manual volume enable (issue #57). Some monitors (LG 27UP850N
/// over USB-C) accept DDC volume writes but never answer the 0x62 probe read,
/// so volumeSupported can never turn on by itself and the whole volume
/// feature stays hidden. This row appears only for externals in that state
/// and forces write-only volume for the display (persisted by UUID in
/// VolumeService). Probe-confirmed monitors never show it.
struct VolumeOverrideView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHovered = false

    var body: some View {
        if !display.isBuiltin,
           !display.volumeSupported || VolumeService.shared.isForced(display) {
            HStack {
                MenuItemIcon(systemName: "speaker.wave.2.fill", color: .blue, active: display.volumeSupported)
                Text("Hardware Volume Control (DDC)")
                    .font(.body)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { VolumeService.shared.isForced(display) },
                    set: { VolumeService.shared.setForced($0, for: display) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .help("Force volume control for a monitor that doesn't report it. Crisp can set the volume but not read the current level.")
        }
        if !display.isBuiltin, #available(macOS 14.2, *) {
            SoftwareVolumeRow(display: display)
        }
    }
}

@available(macOS 14.2, *)
private struct SoftwareVolumeRow: View {
    @ObservedObject private var service = SoftwareVolumeService.shared
    @ObservedObject var display: DisplayInfo
    @State private var consent = false

    var body: some View {
        if #available(macOS 14.2, *) {
            Toggle(isOn: Binding(
                get: { display.softwareVolumeActive },
                set: { enabled in
                    if enabled { consent = true } else { SoftwareVolumeService.shared.stop() }
                }
            )) {
                HStack(spacing: 8) {
                    MenuItemIcon(systemName: "speaker.wave.2.fill", color: .blue, active: display.softwareVolumeActive)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Software Volume (Experimental)")
                            .font(.body)
                        Text("""
                        Use working hardware volume control (DDC or monitor/TV controls) when available. \
                        Software volume is an optional fallback; a failed DDC probe never enables it automatically.
                        """)
                        .font(.caption).foregroundStyle(Color.secondaryReadable)
                        if VolumeService.shared.softwareOutput(for: display) == nil, !display.softwareVolumeActive {
                            Text("Select this display as the audio output. A unique display name is required.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !display.softwareVolumeStatus.isEmpty {
                            Text(display.softwareVolumeStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(display.softwareVolumeBusy || (!display.softwareVolumeActive &&
                (!service.canEnable || VolumeService.shared.softwareOutput(for: display) == nil)))
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .alert("Enable Software Volume?", isPresented: $consent) {
                Button("Cancel", role: .cancel) {}
                Button("Enable at 25%") {
                    Task { await SoftwareVolumeService.shared.enable(for: display) }
                }
            } message: {
                Text("""
                Lower the monitor or TV hardware volume to a comfortable baseline first. \
                25% is the initial software gain, not a guaranteed safe volume or your TV remote level. \
                Crisp does not set hardware volume to 100%.

                Turning this off, stopping the engine, quitting, a crash, sleep, or an output change removes attenuation. \
                Audio can suddenly become louder, and software mute is lost.

                Crisp captures system audio on this output locally, excluding its own playback. \
                macOS may ask for System Audio Recording permission. Nothing is recorded or uploaded. Stereo 48 kHz output only.
                """)
            }
        }
    }
}
