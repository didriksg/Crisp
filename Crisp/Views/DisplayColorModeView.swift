import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted only after a verified color-mode restore.
    static let crispDisplayColorModeNeedsRefresh = Notification.Name("crisp.displayColorModeNeedsRefresh")
}

/// Color-mode choices for one display, showing its refreshed current mode.
@MainActor
final class DisplayColorModeController: ObservableObject {
    let display: DisplayInfo
    @Published private(set) var snapshot: DisplayColorModeSnapshot?
    @Published private(set) var isAutomatic = true
    @Published private(set) var isApplying = false
    @Published var errorMessage: String?

    init(display: DisplayInfo) {
        self.display = display
    }

    func reload() {
        guard !isApplying else { return }
        snapshot = DisplayColorModeService.shared.snapshot(for: display)
        isAutomatic = !DisplayColorModeService.shared.hasSavedMode(for: display)
    }

    func selectAutomatic() {
        guard !isApplying else { return }
        DisplayColorModeService.shared.useAutomaticMode(for: display)
        isAutomatic = true
        errorMessage = nil
    }

    func select(_ mode: DisplayColorMode) {
        guard let snapshot, snapshot.canSet, !isApplying,
              isAutomatic || mode.id != snapshot.current.id else { return }
        errorMessage = nil
        isApplying = true
        Task {
            let confirmed = await DisplayColorModeService.shared.selectMode(mode, for: display)
            isApplying = false
            if let confirmed {
                self.snapshot = confirmed
                isAutomatic = false
            } else {
                reload()
                showError()
            }
        }
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

/// Refreshes the available choices when the panel opens or macOS reports a display change.
struct ColorModeHeadBlock: View {
    @ObservedObject var controller: DisplayColorModeController
    @ObservedObject var state: PanelSectionState

    var body: some View {
        Group {
            if let snapshot = controller.snapshot, snapshot.canSet {
                ExpandableRow(
                    icon: "swatchpalette",
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

/// Modes matching the current logical size, refresh rate, and HDR state.
struct ColorModeListBlock: View {
    @ObservedObject var controller: DisplayColorModeController

    var body: some View {
        if let snapshot = controller.snapshot, snapshot.canSet {
            VStack(alignment: .leading, spacing: 0) {
                CheckmarkRow(label: String(localized: "Automatic"), isSelected: controller.isAutomatic) {
                    controller.selectAutomatic()
                }
                ForEach(snapshot.compatibleModes) { mode in
                    ColorModeOptionRow(
                        mode: mode,
                        isSelected: !controller.isAutomatic && mode.id == snapshot.current.id
                    ) {
                        controller.select(mode)
                    }
                }
                if let message = controller.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(message)
                            .font(.caption)
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 5)
                }
            }
            .disabled(controller.isApplying)
        }
    }
}

/// A checkmarked format with plain secondary text, matching the other panel lists.
private struct ColorModeOptionRow: View {
    let mode: DisplayColorMode
    let isSelected: Bool
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
            Spacer(minLength: 2)
            Text(mode.detailLabel)
                .font(.caption)
                .foregroundColor(.secondaryReadable)
                .lineLimit(1)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation, !isSelected else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(verbatim: mode.summary + (isSelected ? NSLocalizedString(", selected", comment: "") : "")))
        .accessibilityAddTraits([.isButton])
    }
}

/// Closes the color-mode section before the profile section below it.
struct ColorModeTailBlock: View {
    @ObservedObject var controller: DisplayColorModeController

    var body: some View {
        if controller.snapshot?.canSet == true {
            SectionDivider()
        }
    }
}
