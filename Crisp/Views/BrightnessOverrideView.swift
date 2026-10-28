import SwiftUI

/// Per-display manual software-brightness route. Some monitors (LEN Y27q-20)
/// ack DDC brightness writes but never apply them, and answer every
/// capability read with garbage, so the three-failed-writes latch can never
/// trip and the top of the slider dies with nothing to detect. This row
/// routes the display's whole 0-100 range through the software gamma path,
/// like an HDR-dimmed display (persisted by UUID in BrightnessService).
/// Shown for every DDC external: the broken state is invisible to probes, so
/// the row has to be discoverable before anything looks wrong.
struct BrightnessOverrideView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHovered = false

    var body: some View {
        if !display.isBuiltin, !display.hasNativeBrightness {
            HStack {
                MenuItemIcon(systemName: "sun.max.fill", color: .blue,
                             active: BrightnessService.shared.isSoftwareBrightnessForced(display))
                Text("Software Brightness")
                    .font(.body)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { BrightnessService.shared.isSoftwareBrightnessForced(display) },
                    set: { BrightnessService.shared.setSoftwareBrightnessForced($0, for: display) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .help("Dim in the picture instead of the monitor's backlight, for a monitor that ignores brightness commands. "
                + "Raise the monitor's own brightness to full first: the dimmer can only go darker than the backlight it is stuck at.")
        }
    }
}
