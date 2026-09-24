import SwiftUI

// The expanded per-display detail, split into canvas blocks (docs/panel-resize.md):
// mode section, preset / color-profile, image adjustment, then the trailing
// toggle rows.

/// Per-display preset / color-profile names, shared by the header row and the
/// body list (separate blocks). Created per display when the block list is
/// (re)built; the block hosts retain it.
@MainActor
final class DisplayProfileController: ObservableObject {
    let display: DisplayInfo
    @Published var presetName: String = ""
    @Published var presets: [DisplayPresetService.Preset] = []
    @Published var activePresetIndex: Int?
    @Published var activeProfileName: String = ""

    init(display: DisplayInfo) {
        self.display = display
    }

    func reload() {
        activeProfileName = ColorProfileService.shared.currentColorSpaceName(for: display.displayID)
        let svc = DisplayPresetService.shared
        // Never call MonitorPanel's KVC getters from a SwiftUI body: they can
        // spin the run loop and crash AttributeGraph mid-update. Cache a
        // snapshot here instead.
        let newPresets = svc.presets(for: display.displayID)
        let newActiveIndex = svc.activePresetIndex(for: display.displayID)
        presets = newPresets
        activePresetIndex = newActiveIndex
        presetName = newActiveIndex.flatMap { idx in
            newPresets.first(where: { $0.index == idx })?.name
        } ?? ""
    }

    func refreshActiveProfileName() {
        activeProfileName = ColorProfileService.shared.currentColorSpaceName(for: display.displayID)
    }
}

/// Preset (XDR builtin panels) or Color Profile header row, mutually exclusive
/// as in System Settings.
struct ProfileHeadBlock: View {
    @ObservedObject var controller: DisplayProfileController
    @ObservedObject var state: PanelSectionState

    var body: some View {
        Group {
            if !controller.presetName.isEmpty {
                ExpandableRow(
                    icon: "camera.filters",
                    iconActive: false,
                    label: "Preset",
                    subtitle: controller.presetName,
                    isExpanded: state.openBinding(\.profileOpenIDs, controller.display.displayID)
                )
            } else {
                ExpandableRow(
                    icon: "paintpalette.fill",
                    iconActive: false,
                    label: "Color Profile",
                    subtitle: controller.activeProfileName,
                    isExpanded: state.openBinding(\.profileOpenIDs, controller.display.displayID)
                )
            }
        }
        .task { controller.reload() }
        // Re-read on panel open and on screen reconfiguration (debounced: mode
        // switches emit bursts), since System Settings and HDR mode switches
        // change the profile outside this view.
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            controller.refreshActiveProfileName()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        ) { _ in
            controller.refreshActiveProfileName()
        }
    }
}

/// The preset or color-profile list under the header row.
struct ProfileBodyBlock: View {
    @ObservedObject var controller: DisplayProfileController

    var body: some View {
        if !controller.presetName.isEmpty {
            DisplayPresetView(controller: controller)
        } else {
            ColorProfileView(display: controller.display, activeProfileName: $controller.activeProfileName)
        }
    }
}

struct ImageHeadBlock: View {
    let display: DisplayInfo
    @ObservedObject var state: PanelSectionState

    var body: some View {
        ExpandableRow(
            icon: "slider.horizontal.3",
            iconActive: false,
            label: "Image Adjustment",
            isExpanded: state.openBinding(\.imageOpenIDs, display.displayID)
        )
    }
}

struct ImageBodyBlock: View {
    let display: DisplayInfo
    @ObservedObject var state: PanelSectionState

    var body: some View {
        ImageAdjustmentView(display: display, isExpanded: state.imageOpenIDs.contains(display.displayID))
            .padding(.leading, 8)
    }
}

/// The plain rows below the dropdown sections.
struct DetailTailBlock: View {
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider()

            VolumeOverrideView(display: display)

            // Above Extra Brightness: cause before effect (boost on an SDR
            // external switches HDR on).
            HDRToggleView(display: display)

            ExtraBrightnessView(display: display)

            SystemAutoBrightnessView(display: display)

            NotchView(display: display)

            // Grouped with Disconnect: both act on the display as a whole.
            MainDisplayView(display: display)

            // Always last: it removes the section it's in.
            DisconnectDisplayRow(display: display)
        }
    }
}
