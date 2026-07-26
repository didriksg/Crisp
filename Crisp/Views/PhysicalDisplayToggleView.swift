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
                    MenuItemIcon(systemName: "rectangle.slash", color: .orange)
                    Text("Disconnect Display")
                        .font(.body)
                    Spacer()
                    if busy {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
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
                    let busy = busyUUIDs.contains(record.uuid)
                    HStack(spacing: 8) {
                        MenuItemIcon(systemName: "rectangle.slash", color: .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.name).font(.body).lineLimit(1)
                            Text("\(record.width)×\(record.height)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if busy {
                            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        } else {
                            Button("Reconnect") { reconnect(record) }
                                .buttonStyle(.borderless)
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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
