import SwiftUI

// The Brightness Control row of an external monitor: how its brightness is done,
// Hardware (the backlight over DDC) or Software (the gamma table). Some monitors ack
// brightness writes and ignore them, or stop answering after some writes, and no probe
// can tell, so the choice is the user's, saved per display (docs/brightness-notes.md).
// The row shows Software also when Crisp fell back by itself; a click on Hardware then
// tries the monitor again. What it shows is decided in BrightnessControlRoute.

struct BrightnessControlHeadBlock: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var state: PanelSectionState

    var body: some View {
        let row = BrightnessService.shared.brightnessControlRow(for: display)
        if row.visible {
            ExpandableRow(
                icon: "dial.medium",
                iconActive: false,
                label: "Brightness Control",
                subtitle: row.shown == .hardware ? String(localized: "Hardware") : String(localized: "Software"),
                isExpanded: state.openBinding(\.brightnessControlOpenIDs, display.displayID)
            )
        }
    }
}

struct BrightnessControlBodyBlock: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        let row = BrightnessService.shared.brightnessControlRow(for: display)
        if row.visible {
            VStack(alignment: .leading, spacing: 0) {
                CheckmarkRow(label: String(localized: "Hardware"), isSelected: row.shown == .hardware) {
                    BrightnessService.shared.setBrightnessControl(.hardware, for: display)
                }
                .allowsHitTesting(row.hardwareSelectable)
                .opacity(row.hardwareSelectable ? 1 : 0.5)
                caption(row.hardwareSelectable
                    ? "Changes the monitor's backlight."
                    : "HDR is on, so the monitor sets its own backlight.")
                CheckmarkRow(label: String(localized: "Software"), isSelected: row.shown == .software) {
                    BrightnessService.shared.setBrightnessControl(.software, for: display)
                }
                caption("Darkens the picture. For a monitor that ignores brightness commands.")
            }
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.bottom, 3)
    }
}
