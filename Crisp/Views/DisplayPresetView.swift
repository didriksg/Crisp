import SwiftUI

/// Reference-mode preset picker, mirroring the System Settings "Preset" menu
/// for displays that have presets (XDR builtin panels). A native checkmarked
/// list (same style as the resolution list), not a nested popup.
struct DisplayPresetView: View {
    @ObservedObject var controller: DisplayProfileController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(controller.presets) { preset in
                CheckmarkRow(
                    label: preset.name,
                    isSelected: preset.index == controller.activePresetIndex
                ) {
                    select(preset)
                }
            }
        }
    }

    private func select(_ preset: DisplayPresetService.Preset) {
        guard preset.index != controller.activePresetIndex else { return }
        if DisplayPresetService.shared.setActivePreset(
            index: preset.index,
            for: controller.display.displayID
        ) {
            controller.activePresetIndex = preset.index
            controller.presetName = preset.name
        }
    }
}
