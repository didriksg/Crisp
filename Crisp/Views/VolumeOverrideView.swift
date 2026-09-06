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
        if !display.isBuiltin, #available(macOS 14.2, *) {
            SoftwareVolumeRow(display: display)
        }
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
    }
}

@available(macOS 14.2, *)
private struct SoftwareVolumeRow: View {
    @ObservedObject private var service = SoftwareVolumeService.shared
    @ObservedObject var display: DisplayInfo
    @State private var consent = false

    var body: some View {
        if #available(macOS 14.2, *) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Software Volume (Experimental)", isOn: Binding(
                    get: { display.softwareVolumeActive },
                    set: { enabled in
                        if enabled { consent = true } else { SoftwareVolumeService.shared.stop() }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(display.softwareVolumeBusy || (!display.softwareVolumeActive &&
                    (!service.canEnable || VolumeService.shared.softwareOutput(for: display) == nil)))
                if VolumeService.shared.softwareOutput(for: display) == nil, !display.softwareVolumeActive {
                    Text("Select this display as the audio output. A unique display name is required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !display.softwareVolumeStatus.isEmpty {
                    Text(display.softwareVolumeStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .alert("Enable Software Volume?", isPresented: $consent) {
                Button("Cancel", role: .cancel) {}
                Button("Enable at 25%") {
                    Task { await SoftwareVolumeService.shared.enable(for: display) }
                }
            } message: {
                Text("""
                Lower the monitor or TV hardware volume to a comfortable level first. \
                Crisp captures system audio on this output locally, excludes its own playback, and applies software gain. \
                The percentage is not your TV remote volume. Turning this off, sleeping, changing output, quitting, \
                or a crash restores original audio; mute does not survive a stopped engine. \
                Stereo 48 kHz output only. Nothing is recorded or uploaded.
                """)
            }
        }
    }
}
