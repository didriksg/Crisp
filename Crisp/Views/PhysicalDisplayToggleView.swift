import SwiftUI
import CoreGraphics

/// Per-display "Disconnect Display" control, shown inside DisplayDetailView below the
/// "Set as Main Display" row. Apple Silicon only; hidden when disconnecting this display
/// would leave no active screen. Disconnecting removes the display from the layout (a true
/// hardware disconnect via SkyLight); it then reappears in ReconnectDisplaysSection.
struct DisconnectDisplayRow: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = PhysicalDisplayToggleService.shared
    @State private var isHovered = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        // Feature gate: Apple Silicon only, and never offer to black out the last screen.
        if service.isSupported, !service.wouldLeaveNoActiveDisplay(display.displayID) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MenuItemIcon(systemName: "rectangle.slash", color: .orange, active: false)
                    Text("Disconnect Display")
                        .font(.body)
                    Spacer()
                    if busy {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !busy else { return }
                    busy = true
                    errorMessage = nil
                    Task { @MainActor in
                        let result = await service.disconnect(display)
                        displayManager.refreshDisplays()
                        if case .failure(let err) = result {
                            errorMessage = err.description
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                errorMessage = nil
                            }
                        }
                        busy = false
                    }
                }

                // The disconnect outlives a replug and a reboot (see
                // PhysicalDisplayToggleService.reconcile), and a display that is switched off
                // at the window server shows no signal and is absent from System Settings, so
                // there is nothing outside this menu to say what happened to it. Said here,
                // where the choice is made, rather than left to be rediscovered later.
                Text("Stays disconnected until you reconnect it here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
        }
    }
}

/// Inline "Disconnected" section for the main display list (MenuBarView). Lists displays the
/// user disconnected and offers a Reconnect action for each. Rendered only when the
/// disconnected set is non-empty, since a disconnected display no longer has its own row.
struct ReconnectDisplaysSection: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = PhysicalDisplayToggleService.shared
    @State private var busyUUIDs: Set<String> = []

    var body: some View {
        if !service.disconnected.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Disconnected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ForEach(service.disconnected) { record in
                    DisconnectedDisplayRow(
                        record: record,
                        busy: busyUUIDs.contains(record.uuid),
                        onReconnect: { reconnect(record) }
                    )
                }
            }
        }
    }

    private func reconnect(_ record: PhysicalDisplayToggleService.DisconnectedDisplay) {
        guard !busyUUIDs.contains(record.uuid) else { return }
        busyUUIDs.insert(record.uuid)
        Task { @MainActor in
            _ = await service.reconnect(uuid: record.uuid)
            displayManager.refreshDisplays()
            busyUUIDs.remove(record.uuid)
        }
    }
}

/// One disconnected-display row. The whole row highlights and is tappable to
/// reconnect (like clicking a network in the native Wi-Fi menu), with a
/// "Reconnect" hint that is always visible and brightens to the accent color on
/// hover, so the action is discoverable at rest, not a small stray button.
private struct DisconnectedDisplayRow: View {
    let record: PhysicalDisplayToggleService.DisconnectedDisplay
    let busy: Bool
    let onReconnect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // The display is inactive, so dim its icon + name; it brightens as the
            // row is hovered, cueing that a click brings it back.
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "rectangle.slash", color: .secondary, active: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name).font(.body).lineLimit(1)
                    Text(verbatim: "\(record.width)×\(record.height)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .opacity(isHovered ? 1 : 0.6)

            Spacer()

            if busy {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
                // Liquid-Glass accent capsule; the whole row is the tap target, so
                // this reads as the affordance and deepens with the row on hover.
                Text("Reconnect")
                    .font(.caption).fontWeight(.medium)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(isHovered ? 0.22 : 0.12))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !busy else { return }
            onReconnect()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name), disconnected")
        .accessibilityHint("Reconnect this display")
        .accessibilityAddTraits(.isButton)
    }
}
