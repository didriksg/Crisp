import SwiftUI
import AppKit

/// Per-display "Extra Brightness" toggle: unlocks the brightness slider beyond
/// 100% by engaging the EDR upscaling overlay. Rendered only for displays that
/// can actually boost (built-in XDR panels, HDR-capable externals). For an
/// external in SDR mode, enabling also switches the monitor into HDR mode.
struct ExtraBrightnessView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isOn: Bool = false
    @State private var isHovered = false
    /// Guards the onChange handler while we set isOn programmatically
    /// (initial sync, revert on failure), so those writes do not re-trigger
    /// the service.
    @State private var isProgrammaticChange = false

    var body: some View {
        if BrightnessBoostService.shared.isEligible(display) {
            HStack {
                MenuItemIcon(systemName: "sun.max.fill", color: .yellow, active: isOn)
                Text("Extra Brightness")
                    .font(.body)
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: isOn) { _, newValue in
                        guard !isProgrammaticChange else { return }
                        Task { @MainActor in
                            let ok = await BrightnessBoostService.shared.setEnabled(newValue, for: display)
                            if !ok {
                                // Quiet revert, per the spec: no dialogs.
                                isProgrammaticChange = true
                                isOn = false
                                isProgrammaticChange = false
                            }
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .onAppear {
                isProgrammaticChange = true
                isOn = BrightnessBoostService.shared.isEnabled(for: display)
                isProgrammaticChange = false
            }
            // The service can silently disable boost (BrightnessBoostService.headroomLossPolls).
            // Re-read on every panel open so the toggle doesn't go stale.
            .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
                isProgrammaticChange = true
                isOn = BrightnessBoostService.shared.isEnabled(for: display)
                isProgrammaticChange = false
            }
            // Catches the same auto-disable while the panel stays open, once
            // maxBrightness collapses back to 100.
            .onChange(of: display.maxBrightness) { _, newValue in
                guard isOn, newValue <= 100.5, !BrightnessBoostService.shared.isEnabled(for: display) else { return }
                isProgrammaticChange = true
                isOn = false
                isProgrammaticChange = false
            }
        }
    }
}
