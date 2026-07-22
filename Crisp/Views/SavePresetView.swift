import SwiftUI

// MARK: - SavePresetView

/// Section in MenuBarView that lets users save the current display state as a named preset.
struct SavePresetView: View {
    @State private var isShowingSaveForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle button
            Button(action: { isShowingSaveForm.toggle() }) {
                HStack {
                    MenuItemIcon(systemName: isShowingSaveForm ? "minus" : "plus", color: .indigo)
                    Text(isShowingSaveForm ? "Cancel" : "Create Preset")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if isShowingSaveForm {
                SavePresetForm(onSaved: { isShowingSaveForm = false })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - SavePresetForm

/// Inline form for naming and saving the current display state as a preset.
struct SavePresetForm: View {
    let onSaved: () -> Void

    @State private var presetName: String = ""
    @State private var selectedIcon: String = "display"
    @State private var selectedColor: String = "indigo"
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    /// The swatch currently picked in the Color row; the selected icon chip
    /// previews it live.
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
        ("briefcase.fill", "Work"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name field
            HStack {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
                // Quiet inset field (Spotlight/Control Center style): the
                // .roundedBorder bezel and its focus halo look bulky on glass.
                TextField("My Preset", text: $presetName)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }

            // Icon picker
            HStack(alignment: .top) {
                Text("Icon")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
                    .padding(.top, 2)
                // Plain HStack, not LazyVGrid: lazy containers reposition their
                // items mid-flight during animated panel resizes (icons "fly").
                HStack(spacing: 4) {
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

            // Color picker
            HStack {
                Text("Color")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
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
                        .accessibilityLabel("\(option.name) color")
                        .accessibilityAddTraits(selectedColor == option.name ? [.isSelected] : [])
                    }
                }
            }

            // Error message
            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Compact right-aligned default button, like native macOS forms
            // (full-width prominent buttons are an iOS sheet pattern).
            HStack(spacing: 6) {
                Spacer()
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
                Button(isSaving ? "Saving..." : "Save", action: savePreset)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.15), value: saveError)
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isSaving = true
        saveError = nil

        var preset = PresetService.shared.captureCurrentState(name: name, icon: selectedIcon)
        preset.colorName = selectedColor
        PresetService.shared.addPreset(preset)

        isSaving = false
        onSaved()
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
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? tint : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
    }
}
