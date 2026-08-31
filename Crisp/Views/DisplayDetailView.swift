import SwiftUI

// The expanded per-display detail, split into canvas blocks (docs/panel-resize.md):
// the mode section (DisplayModeListView.swift), then the preset / color-profile
// section, image adjustment, and the trailing toggle rows below. Each dropdown
// is its own block so the canvas animates its reveal as a clip over content that
// rendered once; nothing SwiftUI-animates block geometry.

/// Per-display preset / color-profile names, shared by the header row (subtitle)
/// and the body list, which are separate blocks. Created per display when the
/// block list is (re)built; the block hosts retain it.
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
        // MonitorPanel's KVC getters can spin the main run loop. Never invoke
        // them from a SwiftUI body: a screen-parameter notification delivered
        // by that nested run loop re-enters AttributeGraph mid-update and macOS
        // aborts on its value_set precondition. Cache one snapshot here instead.
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

/// Preset (XDR builtin panels, mirrors the System Settings "Preset" menu) or
/// Color Profile header row; the two are mutually exclusive, matching System
/// Settings (XDR panels get Preset instead of a profile picker).
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
        // The active profile changes outside this view: System Settings, and
        // HDR mode switches (macOS swaps the display's profile with the mode).
        // Re-read on panel open and on screen reconfiguration, debounced
        // because mode switches emit bursts.
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

/// Image adjustment header row.
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

/// Image adjustment sliders.
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

            // Manual volume enable for externals whose DDC volume probe never
            // succeeded (issue #57); hidden once the probe confirms support.
            VolumeOverrideView(display: display)

            // HDR: explicit per-display HDR mode toggle, shown only for
            // HDR-capable externals (built-in never offers this, matching
            // System Settings). Placed above Extra Brightness: cause before
            // effect, since enabling boost on an SDR external switches this on.
            HDRToggleView(display: display)

            // Extra Brightness (EDR upscaling), shown only for displays with
            // usable HDR headroom (built-in XDR, HDR-capable externals)
            ExtraBrightnessView(display: display)

            // macOS "Automatically adjust brightness" (ambient light), grouped with the
            // other built-in-only toggles; renders only on ALS panels, absent on externals.
            SystemAutoBrightnessView(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

            // Set as main display. Grouped with Disconnect at the foot of the section:
            // both act on the display as a whole, unlike the settings above them.
            MainDisplayView(display: display)

            // Disconnect this physical display (Apple Silicon only; hidden for the last
            // screen). Always last: it's the one row that removes the section you're in,
            // so it sits below every setting rather than between them.
            DisconnectDisplayRow(display: display)
        }
    }
}
