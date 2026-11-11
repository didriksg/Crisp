import SwiftUI
import CoreGraphics

// The Rotation row (#258): a checkmark list under Refresh Rate, split into a head and a
// body block like the other dropdowns (docs/panel-resize.md).

/// Shared by the head (subtitle) and body (list) blocks of one display.
@MainActor
final class RotationController: ObservableObject {
    let display: DisplayInfo
    private let displayManager: DisplayManager
    @Published private(set) var current: DisplayRotation
    @Published private(set) var pending: DisplayRotation?

    init(display: DisplayInfo, displayManager: DisplayManager) {
        self.display = display
        self.displayManager = displayManager
        current = DisplayRotation(degrees: CGDisplayRotation(display.displayID))
    }

    var isAvailable: Bool { ResolutionService.shared.canRotate(display) }

    /// Re-read on panel open: System Settings or a disconnect's arrangement change turns it too.
    func reload() {
        current = DisplayRotation(degrees: CGDisplayRotation(display.displayID))
    }

    func select(_ rotation: DisplayRotation) {
        guard pending == nil else { return }
        pending = rotation
        Task {
            _ = await displayManager.rotate(display, to: rotation)
            reload()
            pending = nil
        }
    }
}

struct RotationHeadBlock: View {
    @ObservedObject var controller: RotationController
    @ObservedObject var state: PanelSectionState

    var body: some View {
        if controller.isAvailable {
            ExpandableRow(
                icon: "rotate.right",
                iconActive: false,
                label: "Rotation",
                subtitle: controller.current.label,
                isExpanded: state.openBinding(\.rotationOpenIDs, controller.display.displayID)
            )
            .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
                controller.reload()
            }
        }
    }
}

struct RotationListBlock: View {
    @ObservedObject var controller: RotationController

    var body: some View {
        if controller.isAvailable {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(DisplayRotation.allCases) { rotation in
                    CheckmarkRow(
                        label: rotation.label,
                        isSelected: rotation == controller.current,
                        isPending: rotation == controller.pending
                    ) {
                        controller.select(rotation)
                    }
                }
            }
        }
    }
}
