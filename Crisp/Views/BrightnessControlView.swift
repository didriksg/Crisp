import SwiftUI

// The Brightness Control row of an external monitor in Advanced Settings > Displays: how its
// brightness is done, Hardware (the backlight over DDC) or Software (the gamma table). Some
// monitors ack brightness writes and ignore them, or stop answering after some writes, and no
// probe can tell, so the choice is the user's, saved per display (docs/brightness-notes.md).
// The row shows Software also when Crisp fell back by itself; Keep saves that, and Hardware
// tries the monitor again. What it shows is decided in BrightnessControlRoute.

struct BrightnessControlPicker: View {
    @ObservedObject var display: DisplayInfo
    @State private var routeChanges = 0

    var body: some View {
        // Read so a route change that publishes nothing on the display redraws the row.
        _ = routeChanges
        let row = BrightnessService.shared.brightnessControlRow(for: display)
        return Group {
            if row.visible {
                CenteredRow(title: "Brightness Control", detail: Text(caption(row))) {
                    if row.fallback {
                        Button("Keep") { BrightnessService.shared.setBrightnessControl(.software, for: display) }
                    }
                    Picker("Brightness Control", selection: Binding(
                        get: { row.shown },
                        set: { BrightnessService.shared.setBrightnessControl($0, for: display) }
                    )) {
                        Text("Hardware").tag(BrightnessControlRoute.hardware)
                            .selectionDisabled(!row.hardwareSelectable)
                        Text("Software").tag(BrightnessControlRoute.software)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BrightnessService.routeChanged)) { _ in
            routeChanges += 1
        }
    }

    private func caption(_ row: BrightnessControlRoute.Row) -> LocalizedStringKey {
        if !row.hardwareSelectable { return "HDR is on, so the monitor sets its own backlight." }
        if row.fallback { return "The monitor stopped answering. Click to keep brightness in software." }
        return row.shown == .hardware
            ? "Changes the monitor's backlight."
            : "Darkens the picture. For a monitor that ignores brightness commands."
    }
}
