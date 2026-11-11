import SwiftUI

/// Per-display DDC volume switch, on every external (persisted by UUID in
/// VolumeService). On for a monitor that never answers the 0x62 probe read
/// forces write-only volume (issue #57, LG 27UP850N over USB-C). Off stops
/// volume commands to a monitor that answers, for one whose DDC stops after
/// repeated volume writes (#245).
struct VolumeOverrideView: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject private var settings = SettingsService.shared
    @State private var isHovered = false

    var body: some View {
        if !display.isBuiltin, settings.showVolumeSliders {
            HStack {
                MenuItemIcon(systemName: "speaker.wave.2.fill", color: .blue, active: display.volumeSupported)
                Text("Volume Control")
                    .font(.body)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { display.volumeSupported },
                    set: { VolumeService.shared.setEnabled($0, for: display) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .help("Speaker volume over DDC. Turn it off if the monitor stops answering, or on if it doesn't report volume.")
        }
    }
}
