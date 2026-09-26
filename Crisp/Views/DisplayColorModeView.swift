import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted after a successful startup or reconnection restore request, and after
    /// each wake pass, to refresh color-mode rows.
    static let crispDisplayColorModeNeedsRefresh = Notification.Name("crisp.displayColorModeNeedsRefresh")
}

/// Color-mode choices for one display, showing its refreshed current mode.
@MainActor
final class DisplayColorModeController: ObservableObject {
    let display: DisplayInfo
    @Published private(set) var snapshot: DisplayColorModeSnapshot?
    @Published var errorMessage: String?

    init(display: DisplayInfo) {
        self.display = display
    }

    func reload() {
        snapshot = DisplayColorModeService.shared.snapshot(for: display)
    }

    func select(_ mode: DisplayColorMode) {
        guard let snapshot, snapshot.canSet,
              mode.id != snapshot.current.id else { return }

        errorMessage = nil
        guard DisplayColorModeService.shared.selectMode(mode, for: display) else {
            showError()
            return
        }
        reload()
    }

    private func showError() {
        let message = String(localized: "Unable to switch color mode. Please try again.")
        errorMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.errorMessage == message { self.errorMessage = nil }
        }
    }
}

/// Header row for the color-mode list; refreshes the available choices when the panel
/// opens or macOS reports a display change.
struct ColorModeHeadBlock: View {
    @ObservedObject var controller: DisplayColorModeController
    @ObservedObject var state: PanelSectionState

    var body: some View {
        Group {
            if let snapshot = controller.snapshot {
                ExpandableRow(
                    icon: "circle.lefthalf.filled",
                    iconActive: false,
                    label: "Color Mode",
                    subtitle: snapshot.current.shortSummary,
                    isExpanded: state.openBinding(\.colorModeOpenIDs, controller.display.displayID)
                )
            }
        }
        .onAppear { controller.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            controller.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispDisplayColorModeNeedsRefresh)) { _ in
            controller.reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        ) { _ in
            controller.reload()
        }
    }
}

/// Modes matching the current logical size, refresh rate, and HDR state; distinct IDs
/// may still describe the same color format. Displays with no other ID are read-only.
struct ColorModeListBlock: View {
    @ObservedObject var controller: DisplayColorModeController

    var body: some View {
        if let snapshot = controller.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot.compatibleModes) { mode in
                    ColorModeOptionRow(
                        mode: mode,
                        isSelected: mode.id == snapshot.current.id,
                        isSelectable: snapshot.canSet
                    ) {
                        controller.select(mode)
                    }
                }

                if snapshot.compatibleModes.isEmpty {
                    Text("No compatible color modes are available.")
                        .font(.caption)
                        .foregroundColor(.secondaryReadable)
                        .padding(.leading, 24)
                        .padding(.vertical, 6)
                }

                if !snapshot.canSet && !snapshot.compatibleModes.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("No alternative color modes are available for this display.")
                            .font(.caption)
                            .foregroundColor(.secondaryReadable)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 5)
                }

                if let message = controller.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

/// The BetterDisplay-style bit-depth line with compact HDR, encoding, and range badges.
private struct ColorModeOptionRow: View {
    let mode: DisplayColorMode
    let isSelected: Bool
    let isSelectable: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 16)

            Text(mode.title)
                .font(.body)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelectable ? .primary : .secondaryReadable)

            Spacer(minLength: 2)

            HStack(spacing: 3) {
                ForEach(Array(mode.badges.enumerated()), id: \.offset) { _, badge in
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
            }
            .foregroundColor(isSelectable ? .secondaryReadable : .secondary)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered && isSelectable)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelectable, PanelOpenGuard.allowsActivation, !isSelected else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(mode.summary)\(isSelected ? NSLocalizedString(", selected", comment: "") : "")")
        .accessibilityAddTraits(isSelectable ? [.isButton] : [])
    }
}

/// Closes the color-mode section before the profile section below it.
struct ColorModeTailBlock: View {
    @ObservedObject var controller: DisplayColorModeController

    var body: some View {
        if controller.snapshot != nil {
            SectionDivider()
        }
    }
}
