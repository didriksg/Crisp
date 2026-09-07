import SwiftUI
import AppKit

/// Per-display explicit HDR toggle: switches an HDR-capable external monitor
/// between SDR and HDR mode. Rendered only for eligible externals (see
/// BrightnessBoostService.isEligibleForHDRToggle); the built-in panel never
/// shows this row, matching System Settings.
struct HDRToggleView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isOn: Bool = false
    @State private var isHovered = false
    /// Guards the onChange handler while we set isOn programmatically
    /// (initial sync, revert on failure), so those writes do not re-trigger
    /// the service.
    @State private var isProgrammaticChange = false
    /// A user-initiated HDR request that has not settled yet. setHDRPreference
    /// waits out a boost collapse plus a settle before switching modes, and an
    /// unrelated screen reconfiguration in that window would make the live
    /// resync read the OLD state and fight the pending request. Resyncs are
    /// skipped until the request's own read-back lands.
    @State private var requestInFlight = false

    var body: some View {
        if BrightnessBoostService.shared.isEligibleForHDRToggle(display) {
            HStack {
                MenuItemIcon(systemName: "tv.fill", color: .purple, active: isOn)
                Text("HDR")
                    .font(.body)
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: isOn) { _, newValue in
                        guard !isProgrammaticChange,
                              newValue != BrightnessBoostService.shared.isHDREnabled(for: display) else { return }
                        requestInFlight = true
                        Task { @MainActor in
                            _ = await BrightnessBoostService.shared.setHDRPreference(newValue, for: display)
                            // Read back the live state rather than trust newValue:
                            // this both confirms success and is the quiet revert
                            // on failure, per the spec: no dialogs.
                            isProgrammaticChange = true
                            isOn = BrightnessBoostService.shared.isHDREnabled(for: display)
                            isProgrammaticChange = false
                            requestInFlight = false
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .onAppear { resyncFromLiveState() }
            // HDR can change outside Crisp (System Settings, or the auto
            // boost teardown) while the panel sits open, and every HDR flip
            // fires a screen reconfiguration; re-read the live state then so
            // the toggle never shows stale HDR-on.
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            ) { _ in
                resyncFromLiveState()
            }
        }
    }

    private func resyncFromLiveState() {
        guard !requestInFlight else { return }
        isProgrammaticChange = true
        isOn = BrightnessBoostService.shared.isHDREnabled(for: display)
        isProgrammaticChange = false
    }
}
