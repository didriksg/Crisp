import SwiftUI

struct ToolsHeaderRow: View {
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        ExpandableRow(
            icon: "wrench.and.screwdriver.fill",
            iconActive: false,
            label: "Tools",
            isExpanded: Binding(
                get: { state.showTools },
                set: { if !settings.keepToolsExpanded { state.showTools = $0 } }
            )
        )
    }
}

struct KeepToolsExpandedRow: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        Toggle(isOn: $settings.keepToolsExpanded) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "wrench.and.screwdriver.fill", color: .gray,
                             active: settings.keepToolsExpanded)
                    .accessibilityHidden(true)
                Text("Keep Tools Expanded").font(.body)
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
