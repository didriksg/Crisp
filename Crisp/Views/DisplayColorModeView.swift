import AppKit
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
        isAutomatic = true
        errorMessage = nil
        isApplying = true
        Task {
            let switched = await DisplayColorModeService.shared.useAutomaticMode(for: display)
            isApplying = false
            if let switched { snapshot = switched } else { reload() }
        }
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

/// Color Mode in Advanced Settings > Displays > Color: Automatic or one of the formats
/// that match the current size, refresh rate and HDR state. Hidden when the display offers
/// no choice. Loads when the page appears and after a restore, never on a display change:
/// CADisplay is private, and a display change reaches every user.
struct AdvancedColorModePicker: View {
    @StateObject private var controller: DisplayColorModeController

    init(display: DisplayInfo) {
        // Loaded here, not in onAppear: in a Form the empty Group below makes no row, so
        // its onAppear never fires.
        _controller = StateObject(wrappedValue: {
            let controller = DisplayColorModeController(display: display)
            controller.reload()
            return controller
        }())
    }

    var body: some View {
        Group {
            if let snapshot = controller.snapshot, snapshot.canSet {
                Picker("Color Mode", selection: Binding<UInt64?>(
                    get: { controller.isAutomatic ? nil : snapshot.current.id },
                    set: { id in
                        if let mode = snapshot.compatibleModes.first(where: { $0.id == id }) {
                            controller.select(mode)
                        } else {
                            controller.selectAutomatic()
                        }
                    }
                )) {
                    Text("Automatic").tag(UInt64?.none)
                    ForEach(snapshot.compatibleModes) { mode in
                        Text(verbatim: "\(mode.title), \(mode.detailLabel)").tag(Optional(mode.id))
                    }
                }
                .disabled(controller.isApplying)
                if let message = controller.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispDisplayColorModeNeedsRefresh)) { _ in
            controller.reload()
        }
    }
}
