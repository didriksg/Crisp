import SwiftUI
import CoreGraphics

/// Per-display "Disconnect Display" control (Apple Silicon only), hidden when
/// disconnecting would leave no active screen. Removes the display from the
/// layout via SkyLight; it then reappears in ReconnectDisplaysSection.
struct DisconnectDisplayRow: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = PhysicalDisplayToggleService.shared
    @State private var isHovered = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
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

                // Outlives a replug and reboot (PhysicalDisplayToggleService.reconcile);
                // nothing outside this menu shows the display's state, so it's said here.
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

/// Inline "Disconnected" section for the main display list: lists displays the
/// user disconnected and offers a Reconnect action for each.
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

/// One disconnected-display row: the whole row is tappable to reconnect (like
/// a network in the native Wi-Fi menu), with a "Reconnect" hint always visible.
private struct DisconnectedDisplayRow: View {
    let record: PhysicalDisplayToggleService.DisconnectedDisplay
    let busy: Bool
    let onReconnect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Dim while inactive; brightens on hover to cue that a click reconnects it.
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
                // Liquid-Glass accent capsule; reads as the affordance since the
                // whole row is the tap target.
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
