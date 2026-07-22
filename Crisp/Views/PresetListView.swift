import SwiftUI

extension DisplayPreset {
    static let colorOptions: [(name: String, color: Color)] = [
        ("indigo", .indigo), ("blue", .blue), ("purple", .purple), ("pink", .pink),
        ("red", .red), ("orange", .orange), ("green", .green), ("teal", .teal),
    ]
    var chipColor: Color {
        Self.colorOptions.first(where: { $0.name == colorName })?.color ?? .indigo
    }
}

// MARK: - PresetListView

/// Section in MenuBarView listing user-created presets + Save Preset row.
/// (Built-in Native/HiDPI segmented control has been moved to the HiDPI section in Settings.)
struct PresetListView: View {
    @ObservedObject private var presetService = PresetService.shared

    private var userPresets: [DisplayPreset] {
        presetService.presets.filter { !$0.isBuiltin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // User-created presets as rows
            ForEach(userPresets) { preset in
                PresetRow(
                    preset: preset,
                    isCurrentMatch: presetService.activePresetID == preset.id,
                    isApplying: presetService.applyingPresetID == preset.id
                )
            }

            // Save preset button
            SavePresetView()
        }
    }
}

// MARK: - Segmented Control for built-in presets (embedded in SettingsView)

struct PresetSegmentedControl: View {
    let presets: [DisplayPreset]
    let matchID: UUID?
    let applyingID: UUID?
    let isApplying: Bool

    @State private var selection: UUID? = nil

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(presets) { preset in
                Text(preset.name).tag(Optional(preset.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .disabled(isApplying)
        .onAppear { selection = matchID }
        .onChange(of: matchID) { _, newValue in
            selection = newValue
        }
        .onChange(of: selection) { _, newValue in
            guard let id = newValue, id != matchID,
                  let preset = presets.first(where: { $0.id == id }) else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        }
    }
}

// MARK: - PresetRow (for user-created presets)

struct PresetRow: View {
    let preset: DisplayPreset
    let isCurrentMatch: Bool
    let isApplying: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if isApplying {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            } else {
                MenuItemIcon(systemName: preset.icon, color: preset.chipColor)
            }

            Text(preset.name)
                .font(.body)
                .fontWeight(isCurrentMatch ? .semibold : .regular)
                .lineLimit(1)

            Spacer()

            if isCurrentMatch {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("Currently active")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation, !PresetService.shared.isApplying else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                PresetService.shared.updatePreset(id: preset.id)
            } label: {
                Label("Update to Current Settings", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) {
                PresetService.shared.deletePreset(id: preset.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .disabled(PresetService.shared.isApplying)
    }
}
