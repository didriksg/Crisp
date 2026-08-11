import SwiftUI
import CoreGraphics

// MARK: - SavePresetView

/// Section in MenuBarView that lets users save the current display state as a
/// named preset. Collapsed, it's a single "New Preset" row; expanded, the row
/// is replaced by a bounded card with its own Cancel / Save buttons.
struct SavePresetView: View {
    @Binding var isShowingForm: Bool
    @State private var isHovered = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fade the row out / card in on the panel spring (no curtain wipe or
            // slide, so nothing ghosts through the glass mid-reveal).
            if isShowingForm {
                SavePresetForm(
                    onClose: { withAnimation(.panelResize) { isShowingForm = false } },
                    nameFocused: $nameFocused
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                Button(action: {
                    // Focus the name field the instant the reveal finishes, 
                    // completion handler, not a timer.
                    withAnimation(.panelResize) {
                        isShowingForm = true
                    } completion: {
                        nameFocused = true
                    }
                }) {
                    HStack {
                        MenuItemIcon(systemName: "plus", color: .blue)
                        Text("New Preset")
                            .font(.body)
                        Spacer()
                    }
                    // Padding inside the button label so the tappable area
                    // matches the hover highlight (no dead padded margin).
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
                .transition(.opacity)
            }
        }
        // Collapse the create form when the panel closes, so it reopens fresh
        // like the rest of the panel (fires while hidden).
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            isShowingForm = false
        }
    }
}

// MARK: - SavePresetForm

/// Bounded card for naming and saving the current display state as a preset.
/// Icon + color are tucked behind the icon button so the common case (name it,
/// save) stays short.
struct SavePresetForm: View {
    /// nil = creating a new preset (captures current state on save); non-nil =
    /// editing an existing one (updates its identity + capture inclusions).
    var editing: DisplayPreset? = nil
    let onClose: () -> Void

    @State private var presetName: String = ""
    @State private var selectedIcon: String = "display"
    @State private var selectedColor: String = "blue"
    @State private var includeResolution: Bool = true
    @State private var includeBrightness: Bool = true
    @State private var includeArrangement: Bool = true
    /// Edit mode only: when on, Save re-captures the current display values
    /// (resolution/brightness/arrangement) instead of keeping the stored ones.
    @State private var recaptureValues: Bool = false
    @State private var showIdentityPicker: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    /// Owned by the parent so it can focus the field in the reveal animation's
    /// completion handler (focusing mid-reveal janks the transition).
    @FocusState.Binding var nameFocused: Bool

    init(editing: DisplayPreset? = nil,
         onClose: @escaping () -> Void,
         nameFocused: FocusState<Bool>.Binding) {
        self.editing = editing
        self.onClose = onClose
        self._nameFocused = nameFocused
        _presetName = State(initialValue: editing?.name ?? "")
        _selectedIcon = State(initialValue: editing?.icon ?? "display")
        _selectedColor = State(initialValue: editing?.colorName ?? "blue")
        _includeResolution = State(initialValue: editing?.includesResolution ?? true)
        _includeBrightness = State(initialValue: editing?.includesBrightness ?? true)
        _includeArrangement = State(initialValue: editing?.includesArrangement ?? true)
    }

    private var nothingSelected: Bool {
        !includeResolution && !includeBrightness && !includeArrangement
    }

    /// Stored resolution shown inline only when a single display carries it (clean
    /// and unambiguous). Several displays stay subtitle-less like the Arrangement
    /// row; their per-display specifics live in the arrangement balloon.
    private var resolutionDetail: String? {
        guard let editing else { return nil }
        let labels = editing.displays.compactMap { $0.width != nil ? $0.resolutionLabel : nil }
        return labels.count == 1 ? labels[0] : nil
    }

    /// Stored brightness, same single-display-only inline treatment as resolution.
    private var brightnessDetail: String? {
        guard let editing else { return nil }
        let vals = editing.displays.compactMap(\.brightness)
        return vals.count == 1 ? "\(Int((vals[0] * 100).rounded()))%" : nil
    }

    /// The swatch currently picked in the Color picker; the icon button previews it live.
    private var selectedSwatch: Color {
        DisplayPreset.colorOptions.first(where: { $0.name == selectedColor })?.color ?? .indigo
    }

    private let iconOptions: [(symbol: String, label: String)] = [
        ("display", "Display"),
        ("sparkles.rectangle.stack", "HiDPI"),
        ("rectangle.on.rectangle", "Mirror"),
        ("moon.fill", "Night"),
        ("sun.max.fill", "Day"),
        ("gamecontroller.fill", "Gaming"),
        ("person.fill", "Personal"),
        ("briefcase.fill", "Work")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Identity line: icon button (opens icon+color) + name field
            HStack(spacing: 9) {
                PresetIconButton(symbol: selectedIcon, color: selectedSwatch, isOpen: showIdentityPicker) {
                    withAnimation(.panelResize) { showIdentityPicker.toggle() }
                }
                // Explicit placeholder: macOS drops a plain field's own
                // placeholder once it's focused, so draw our own while empty.
                ZStack(alignment: .leading) {
                    if presetName.isEmpty {
                        Text("Preset name")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $presetName)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($nameFocused)
                        .onSubmit(save)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(nameFocused ? 0.10 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(nameFocused ? 0.85 : 0), lineWidth: 2)
                )
                .animation(.easeOut(duration: 0.12), value: nameFocused)
            }

            // Progressive icon + color picker (collapsed by default)
            if showIdentityPicker {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Icon")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Plain HStack, not LazyVGrid: lazy containers reposition
                        // their items mid-flight during animated panel resizes.
                        // Sized to fit the 242pt inner width (8×26 + 7×3 = 229) so
                        // expanding the picker doesn't force the fixed-308 panel wider.
                        HStack(spacing: 3) {
                            ForEach(iconOptions, id: \.symbol) { option in
                                IconOptionButton(
                                    symbol: option.symbol,
                                    label: option.label,
                                    isSelected: selectedIcon == option.symbol,
                                    tint: selectedSwatch
                                ) {
                                    selectedIcon = option.symbol
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Color")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 7) {
                            ForEach(DisplayPreset.colorOptions, id: \.name) { option in
                                Button {
                                    selectedColor = option.name
                                } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 16, height: 16)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(.white.opacity(selectedColor == option.name ? 0.9 : 0), lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(DisplayPreset.localizedColorName(option.name)) color")
                                .accessibilityAddTraits(selectedColor == option.name ? [.isSelected] : [])
                            }
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
                // Fade in place (no slide from behind the identity row, which
                // would ghost through the glass mid-reveal).
                .transition(.opacity)
            }

            // Captures
            VStack(alignment: .leading, spacing: 6) {
                Text("Captures")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                CaptureToggleRow(icon: "rectangle.on.rectangle", color: .blue,
                                 label: "Resolution", detail: resolutionDetail, isOn: $includeResolution)
                CaptureToggleRow(icon: "sun.max.fill", color: .orange,
                                 label: "Brightness", detail: brightnessDetail, isOn: $includeBrightness)
                CaptureToggleRow(icon: "display.2", color: .indigo,
                                 label: "Arrangement", isOn: $includeArrangement)
                // Editing an arrangement-bearing preset: show the saved layout as a
                // small diagram (raw x/y coordinates aren't legible; a picture is).
                if includeArrangement, let editing, editing.includesArrangement {
                    PresetArrangementThumbnail(preset: editing,
                                               includeResolution: includeResolution,
                                               includeBrightness: includeBrightness)
                        .frame(height: 72)
                        .padding(.top, 18) // headroom for the hover name callout
                        .padding(.leading, 34)
                        .padding(.trailing, 4)
                }
            }

            // Edit mode only: let Save refresh the stored values to the current
            // display state. New always captures fresh, so this only shows when editing.
            if editing != nil {
                Toggle(isOn: $recaptureValues) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update to current values")
                            .font(.callout)
                        Text("Replace the stored values above with this display's current settings")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.accentColor)
            }

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Cancel / Save
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || nothingSelected || presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: saveError)
    }

    private func save() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !nothingSelected else { return }

        isSaving = true
        saveError = nil

        if let editing {
            // Edit: update identity + capture inclusions, preserving stored
            // values for captures left unchanged.
            PresetService.shared.editPreset(
                id: editing.id, name: name, icon: selectedIcon, colorName: selectedColor,
                includeResolution: includeResolution,
                includeBrightness: includeBrightness,
                includeArrangement: includeArrangement
            )
            // Opt-in: refresh the stored values to the current display state.
            if recaptureValues {
                PresetService.shared.updatePreset(id: editing.id)
            }
        } else {
            var preset = PresetService.shared.captureCurrentState(
                name: name, icon: selectedIcon,
                includeResolution: includeResolution,
                includeBrightness: includeBrightness,
                includeArrangement: includeArrangement
            )
            preset.colorName = selectedColor
            PresetService.shared.addPreset(preset)
        }

        isSaving = false
        onClose()
    }
}

// MARK: - PresetIconButton

/// The preset's icon shown in its color; tapping expands the icon + color
/// picker. A small chevron badge marks it as a disclosure.
struct PresetIconButton: View {
    let symbol: String
    let color: Color
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color))
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(isOpen ? 0.9 : (isHovered ? 0.3 : 0)), lineWidth: 2)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color(white: 0.16)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .offset(x: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Icon & color")
        .accessibilityLabel("Choose icon and color")
    }
}

// MARK: - CaptureToggleRow

/// One "Captures" switch row: colored icon chip + label + native switch.
/// Mirrors the Settings toggle rows so it inherits the panel's look (and the
/// native Liquid Glass material on macOS 26).
struct CaptureToggleRow: View {
    let icon: String
    let color: Color
    let label: String
    /// When editing a preset, the stored value for this capture (e.g. "1512×982
    /// HiDPI", "72%"), shown under the label so you can see what's saved. Hidden
    /// while the capture is toggled off (it's being dropped) and when creating.
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: icon, color: color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(label))
                        .font(.body)
                    if isOn, let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - IconOptionButton

struct IconOptionButton: View {
    let symbol: String
    let label: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? tint : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                )
                // Without this the clear background doesn't hit-test, so hover
                // only fires over the glyph strokes, not the full highlight box.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
    }
}

// MARK: - PresetArrangementThumbnail

/// Static, non-interactive schematic of a preset's saved display arrangement:
/// outlined rectangles at their saved relative positions. Not the arranger, no
/// wallpaper or drag, just a legible stand-in for the raw x/y coordinates.
struct PresetArrangementThumbnail: View {
    let preset: DisplayPreset
    var includeResolution: Bool = true
    var includeBrightness: Bool = true
    @EnvironmentObject private var displayManager: DisplayManager
    @State private var hoveredID: Int?

    var body: some View {
        GeometryReader { geo in
            let items = layout(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(items) { item in
                    thumbnail(for: item.display)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                                if hovering { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
                            }
                        }
                        .overlay(alignment: .top) {
                            // Same hover callout as the arranger; connected displays
                            // only (offline fallbacks have no name to show).
                            if hoveredID == item.id, let display = item.display {
                                DisplayNameBadge(name: display.name, detail: detail(for: display))
                                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                            }
                        }
                        .offset(x: item.rect.minX, y: item.rect.minY)
                        .zIndex(hoveredID == item.id ? 2 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // Bounded canvas, echoing the real arranger's dark rounded stage.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    /// The arranger's own wallpaper thumbnail for a connected display; a neutral
    /// rounded panel when the preset's display isn't currently attached.
    @ViewBuilder
    private func thumbnail(for display: DisplayInfo?) -> some View {
        if let display {
            DisplayThumbnailView(display: display, isDragged: false)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4), lineWidth: 1))
        }
    }

    /// This display's saved resolution · brightness for the hover balloon, limited
    /// to the captures that are currently on. nil when the preset stores neither.
    private func detail(for display: DisplayInfo) -> String? {
        guard let e = preset.displays.first(where: { $0.displayUUID == display.displayUUID }) else { return nil }
        var parts: [String] = []
        if includeResolution, e.width != nil { parts.append(e.resolutionLabel) }
        if includeBrightness, let b = e.brightness { parts.append("\(Int((b * 100).rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private struct Placed: Identifiable {
        let id: Int
        let rect: CGRect
        let display: DisplayInfo?
    }

    /// Saved origins + each display's live point-size (for correct wallpaper aspect),
    /// scaled to fit `size`. Falls back to the stored resolution when a display is offline.
    private func layout(in size: CGSize) -> [Placed] {
        let raw: [(screen: CGRect, display: DisplayInfo?)] = preset.displays.compactMap { e in
            guard let x = e.arrangementX, let y = e.arrangementY else { return nil }
            let live = displayManager.displays.first { $0.displayUUID == e.displayUUID }
            let sz = live.map { CGDisplayBounds($0.displayID).size } ?? pointSize(e)
            return (CGRect(x: x, y: y, width: sz.width, height: sz.height), live)
        }
        guard !raw.isEmpty else { return [] }
        let screens = raw.map(\.screen)
        let minX = screens.map(\.minX).min()!, minY = screens.map(\.minY).min()!
        let maxX = screens.map(\.maxX).max()!, maxY = screens.map(\.maxY).max()!
        let totalW = max(maxX - minX, 1), totalH = max(maxY - minY, 1)
        let padding: CGFloat = 8
        let availW = max(size.width - padding * 2, 1), availH = max(size.height - padding * 2, 1)
        let scale = min(availW / totalW, availH / totalH)
        let offX = padding + (availW - totalW * scale) / 2
        let offY = padding + (availH - totalH * scale) / 2
        return raw.enumerated().map { i, item in
            let r = item.screen
            return Placed(
                id: i,
                rect: CGRect(x: offX + (r.minX - minX) * scale,
                             y: offY + (r.minY - minY) * scale,
                             width: r.width * scale, height: r.height * scale),
                display: item.display
            )
        }
    }

    /// Point footprint from the stored logical resolution (already in points), or a
    /// default 16:10 box when a preset saved arrangement without resolution.
    private func pointSize(_ e: DisplayPresetEntry) -> CGSize {
        guard let w = e.width, let h = e.height else {
            return CGSize(width: 1440, height: 900) // ponytail: default box, arrangement-only preset
        }
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }
}
