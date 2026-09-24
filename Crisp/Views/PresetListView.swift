import SwiftUI

extension DisplayPreset {
    static let colorOptions: [(name: String, color: Color)] = [
        ("blue", .blue), ("indigo", .indigo), ("purple", .purple), ("pink", .pink),
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green),
        ("teal", .teal), ("gray", .gray)
    ]
    var chipColor: Color {
        Self.colorOptions.first(where: { $0.name == colorName })?.color ?? .indigo
    }
    /// VoiceOver display name for a color option; option.name is an internal key,
    /// so interpolating it raw leaves the color untranslated (e.g. "blue 颜色").
    static func localizedColorName(_ name: String) -> String {
        switch name {
        case "blue": return String(localized: "blue")
        case "indigo": return String(localized: "indigo")
        case "purple": return String(localized: "purple")
        case "pink": return String(localized: "pink")
        case "red": return String(localized: "red")
        case "orange": return String(localized: "orange")
        case "yellow": return String(localized: "yellow")
        case "green": return String(localized: "green")
        case "teal": return String(localized: "teal")
        case "gray": return String(localized: "gray")
        default: return name
        }
    }
}

// MARK: - PresetListView

/// Section in MenuBarView listing user-created presets + Save Preset row.
struct PresetListView: View {
    @ObservedObject private var presetService = PresetService.shared
    // Accordion: only one editor is open at a time (docs/DESIGN.md).
    @State private var activeEditor: PresetEditor?

    private var userPresets: [DisplayPreset] {
        presetService.presets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(userPresets) { preset in
                PresetRow(
                    preset: preset,
                    isCurrentMatch: presetService.activePresetID == preset.id,
                    isApplying: presetService.applyingPresetID == preset.id,
                    isEditing: Binding(
                        get: { activeEditor == .preset(preset.id) },
                        set: { activeEditor = $0 ? .preset(preset.id) : nil }
                    )
                )
            }

            SavePresetView(isShowingForm: Binding(
                get: { activeEditor == .new },
                set: { activeEditor = $0 ? .new : nil }
            ))
        }
    }
}

/// Which preset editor, if any, is currently open in the list.
enum PresetEditor: Equatable {
    case preset(DisplayPreset.ID)
    case new
}

// MARK: - PresetRow (for user-created presets)

struct PresetRow: View {
    let preset: DisplayPreset
    let isCurrentMatch: Bool
    let isApplying: Bool

    @Binding var isEditing: Bool

    @State private var isHovered = false
    @FocusState private var nameFocused: Bool
    /// Spinner shown only when applying outlasts a beat: an instant apply (a
    /// brightness-only preset, or one whose resolution already matches) would
    /// otherwise flash the spinner for a frame every time its shortcut fires.
    @State private var showSpinner = false

    /// Resolutions this preset will set, joined across displays; shown as a hover
    /// tooltip (.help) to stay compact. Nil when the preset sets no resolution.
    private var resolutionSummary: String? {
        let labels = preset.displays.compactMap { $0.width != nil ? $0.resolutionLabel : nil }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                SavePresetForm(
                    editing: preset,
                    onClose: { withAnimation(.panelResize) { isEditing = false } },
                    nameFocused: $nameFocused
                )
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else {
                rowContent
                    .transition(.opacity)
            }
        }
        // Collapse the inline edit form when the panel closes, so it reopens fresh.
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            isEditing = false
        }
        .onChange(of: isApplying) { _, applying in
            if applying {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    // Live service state, not the captured row value: a stale read
                    // would raise the spinner after a fast apply already ended.
                    if PresetService.shared.applyingPresetID == preset.id { showSpinner = true }
                }
            } else {
                showSpinner = false
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            if showSpinner {
                // Same footprint as MenuItemIcon (26pt chip), or the row height
                // dips and the panel resizes for a beat.
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 26, height: 26)
            } else {
                MenuItemIcon(systemName: preset.icon, color: preset.chipColor)
            }

            Text(preset.name)
                .font(.body)
                .fontWeight(isCurrentMatch ? .semibold : .regular)
                .lineLimit(1)

            Spacer()

            // Right-aligned like a native menu key equivalent (#61).
            if let combo = preset.shortcut?.display {
                Text(verbatim: combo)
                    .font(.callout)
                    .foregroundColor(.secondaryReadable)
            }

            // Slot stays reserved so glyphs don't shift when this comes and goes.
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .opacity(isCurrentMatch ? 1 : 0)
                .accessibilityHidden(!isCurrentMatch)
                .accessibilityLabel("Currently active")

            // Revealed on hover; same actions as the right-click menu below.
            Menu {
                rowActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Preset options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            // Already the active preset (the checkmarked row): tapping it is a no-op.
            guard PanelOpenGuard.allowsActivation, !PresetService.shared.isApplying, !isCurrentMatch else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        }
        .onHover { isHovered = $0 }
        .help(resolutionSummary ?? "")
        .contextMenu { rowActions }
        .disabled(PresetService.shared.isApplying)
    }

    @ViewBuilder
    private var rowActions: some View {
        Button {
            PresetService.shared.updatePreset(id: preset.id)
        } label: {
            Label("Update to Current Settings", systemImage: "arrow.triangle.2.circlepath")
        }

        Button {
            withAnimation(.panelResize) {
                isEditing = true
            } completion: {
                nameFocused = true
            }
        } label: {
            Label("Edit…", systemImage: "pencil")
        }

        Section {
            Button(role: .destructive) {
                PresetService.shared.deletePreset(id: preset.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
