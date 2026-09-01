import SwiftUI
import CoreGraphics

/// "Virtual Displays" management section shown in the MenuBarView tools area.
/// Lists all saved virtual display configurations and allows creating / deleting them.
struct VirtualDisplayView: View {
    @StateObject private var service = VirtualDisplayService.shared
    @State private var showCreateForm = false
    @State private var createHovered = false
    @State private var configToDelete: UUID?
    @State private var isCreating: Bool = false
    @State private var activatingID: UUID?
    @State private var editingID: UUID?
    @State private var isSavingEdit: Bool = false
    @State private var createError: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.configs.isEmpty && !showCreateForm {
                // Centered secondary text is the native empty-state idiom ("No
                // Recent Items"); a label-column indent here reads as an orphaned
                // row floating mid-panel with no icon to anchor it.
                Text("No virtual displays yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(service.configs) { config in
                    if editingID == config.id {
                        CreateVirtualDisplayForm(
                            editing: config,
                            isCreating: $isSavingEdit,
                            nameFocused: $nameFocused,
                            onCancel: { withAnimation(.panelResize) { editingID = nil } },
                            onConfirm: handleEdit
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    } else {
                        VirtualDisplayRow(
                            config: config,
                            isActive: service.isActive(config.id),
                            isActivating: activatingID == config.id,
                            onActivate: { handleActivate(config) },
                            onDeactivate: { service.destroy(configID: config.id) },
                            onEdit: {
                                withAnimation(.panelResize) {
                                    editingID = config.id
                                } completion: {
                                    nameFocused = true
                                }
                            },
                            onDelete: { configToDelete = config.id }
                        )
                        .transition(.opacity)
                    }
                }
            }

            if let err = createError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            // Create area: a trigger row that fades into a bounded card
            // (mirrors the New Preset flow).
            if showCreateForm {
                CreateVirtualDisplayForm(
                    isCreating: $isCreating,
                    nameFocused: $nameFocused,
                    onCancel: { withAnimation(.panelResize) { showCreateForm = false } },
                    onConfirm: handleCreate
                )
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else {
                Button(action: {
                    // Focus the name field the instant the reveal finishes.
                    withAnimation(.panelResize) {
                        showCreateForm = true
                    } completion: {
                        nameFocused = true
                    }
                }) {
                    HStack {
                        MenuItemIcon(systemName: "plus", color: .indigo)
                        Text("Create Virtual Display")
                            .font(.body)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuRowHover(createHovered)
                .onHover { createHovered = $0 }
                .transition(.opacity)
            }
        }
        .alert("Confirm Deletion", isPresented: Binding(
            get: { configToDelete != nil },
            set: { if !$0 { configToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = configToDelete {
                    service.removeConfig(id: id)
                }
                configToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                configToDelete = nil
            }
        } message: {
            if let id = configToDelete, service.isActive(id) {
                Text("This virtual display is currently active. Deleting it will disable it immediately.")
            } else {
                Text("Are you sure you want to delete this virtual display configuration?")
            }
        }
        // Keep the panel alive while the confirmation is up so an outside-click
        // doesn't tear it down mid-decision. onDisappear guards against the flag
        // sticking true if the view unmounts while a config is still pending.
        .onChange(of: configToDelete) { _, newValue in
            PanelOpenGuard.isConfirmationActive = (newValue != nil)
        }
        .onDisappear { PanelOpenGuard.isConfirmationActive = false }
        // Collapse the inline create/edit forms when the panel closes, so it
        // reopens fresh like the rest of the panel (fires while hidden).
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            showCreateForm = false
            editingID = nil
            createError = nil
        }
    }

    /// Re-creates the live CGVirtualDisplay for a config that is off (e.g. after
    /// a crash/force-quit left the config persisted but the display gone).
    private func handleActivate(_ config: VirtualDisplayService.VirtualDisplayConfig) {
        guard activatingID == nil else { return }
        activatingID = config.id
        createError = nil
        Task { @MainActor in
            let ok = await service.create(config: config)
            activatingID = nil
            if !ok {
                createError = String(localized: "Failed to activate virtual display. Please try again.")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    createError = nil
                }
            }
        }
    }

    private func handleEdit(_ config: VirtualDisplayService.VirtualDisplayConfig) {
        guard !isSavingEdit else { return }
        isSavingEdit = true
        createError = nil
        Task { @MainActor in
            let ok = await service.updateConfig(config)
            isSavingEdit = false
            if ok {
                withAnimation(.panelResize) { editingID = nil }
            } else {
                createError = String(localized: "Failed to update virtual display. Please try again.")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    createError = nil
                }
            }
        }
    }

    private func handleCreate(_ config: VirtualDisplayService.VirtualDisplayConfig) {
        isCreating = true
        createError = nil
        Task { @MainActor in
            let success = await service.addAndCreate(config)
            isCreating = false
            if success {
                withAnimation(.panelResize) { showCreateForm = false }
            } else {
                createError = String(localized: "Failed to create virtual display. Please try again.")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    createError = nil
                }
            }
        }
    }
}

// MARK: - Virtual Display Row

struct VirtualDisplayRow: View {
    let config: VirtualDisplayService.VirtualDisplayConfig
    let isActive: Bool
    let isActivating: Bool
    let onActivate: () -> Void
    let onDeactivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: "display.2", color: .blue, active: isActive)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.body)
                    .lineLimit(1)
                Text(verbatim: "\(config.width)×\(config.height)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isActivating {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else {
                statusPill
            }

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
            .accessibilityLabel("Virtual display options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            // An off display turns back on with a tap (also in the ⋯ menu).
            if !isActive && !isActivating { onActivate() }
        }
        .contextMenu { rowActions }
    }

    @ViewBuilder
    private var statusPill: some View {
        if isActive {
            pill("Active", color: .blue)
        } else {
            pill("Off", color: .secondary)
        }
    }

    // LocalizedStringKey, not String: Text(String) is the non-localizing overload.
    private func pill(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder
    private var rowActions: some View {
        if isActive {
            Button(action: onDeactivate) {
                Label("Deactivate", systemImage: "stop.circle")
            }
        } else {
            Button(action: onActivate) {
                Label("Activate", systemImage: "play.circle")
            }
        }
        Button(action: onEdit) {
            Label("Edit…", systemImage: "pencil")
        }
        Section {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Create Form

/// Bounded card for creating a new virtual display configuration. Mirrors the
/// preset card: left-aligned labels, native switch rows, native footer buttons.
struct CreateVirtualDisplayForm: View {
    /// Non-nil when editing an existing config; nil when creating a new one.
    let editing: VirtualDisplayService.VirtualDisplayConfig?
    @Binding var isCreating: Bool
    @FocusState.Binding var nameFocused: Bool
    let onCancel: () -> Void
    let onConfirm: (VirtualDisplayService.VirtualDisplayConfig) -> Void

    @State private var name: String
    @State private var selectedPreset: Int
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var autoCreate: Bool

    static let presetOptions: [(label: String, width: Int, height: Int)] = [
        ("1920×1080 (FHD)", 1920, 1080),
        ("2560×1440 (QHD)", 2560, 1440),
        ("3840×2160 (4K)", 3840, 2160),
        ("2732×2048 (iPad Pro 12.9″)", 2732, 2048),
        ("2388×1668 (iPad Pro 11″)", 2388, 1668),
        ("2360×1640 (iPad Air)", 2360, 1640),
        ("2048×1536 (iPad 4:3)", 2048, 1536)
    ]
    private var presets: [(label: String, width: Int, height: Int)] { Self.presetOptions }
    /// The tag used by the "Custom…" picker entry (one past the last preset).
    private var customTag: Int { Self.presetOptions.count }

    init(editing: VirtualDisplayService.VirtualDisplayConfig? = nil,
         isCreating: Binding<Bool>,
         nameFocused: FocusState<Bool>.Binding,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (VirtualDisplayService.VirtualDisplayConfig) -> Void) {
        self.editing = editing
        self._isCreating = isCreating
        self._nameFocused = nameFocused
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _name = State(initialValue: editing?.name ?? String(localized: "Virtual Display"))
        _autoCreate = State(initialValue: editing?.autoCreate ?? true)
        // Match the config's size to a preset; a non-preset size (e.g. a custom
        // aspect ratio) selects "Custom" and prefills the width/height fields.
        let presetIdx = editing.flatMap { e in
            Self.presetOptions.firstIndex(where: { $0.width == e.width && $0.height == e.height })
        }
        _selectedPreset = State(initialValue: presetIdx ?? (editing == nil ? 0 : Self.presetOptions.count))
        _customWidth = State(initialValue: presetIdx == nil ? (editing.map { String($0.width) } ?? "") : "")
        _customHeight = State(initialValue: presetIdx == nil ? (editing.map { String($0.height) } ?? "") : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($nameFocused)
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

            // Resolution
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolution")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $selectedPreset) {
                    ForEach(presets.indices, id: \.self) { i in
                        Text(presets[i].label).tag(i)
                    }
                    Text("Custom…").tag(customTag)
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if selectedPreset == customTag {
                    HStack(spacing: 6) {
                        PanelNumericField(text: $customWidth, placeholder: String(localized: "Width"))
                        Text("×").foregroundColor(.secondary)
                        PanelNumericField(text: $customHeight, placeholder: String(localized: "Height"))
                        Spacer()
                    }
                }
            }

            // Options
            VStack(alignment: .leading, spacing: 6) {
                Text("Options")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                CaptureToggleRow(icon: "bolt.fill", color: .green,
                                 label: "Create at launch", isOn: $autoCreate)
            }

            // Cancel / Create
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if isCreating {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Button(confirmTitle, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || resolution == nil)
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
    }

    private var confirmTitle: String {
        if isCreating {
            return editing == nil ? String(localized: "Creating…") : String(localized: "Saving…")
        }
        return editing == nil ? String(localized: "Create") : String(localized: "Save")
    }

    /// The chosen resolution: a preset, or the validated custom width×height.
    /// Nil when "Custom" is selected but the fields are empty / out of range,
    /// which disables the confirm button.
    private var resolution: (width: Int, height: Int)? {
        if selectedPreset < presets.count {
            let p = presets[selectedPreset]
            return (p.width, p.height)
        }
        guard let w = Int(customWidth), let h = Int(customHeight),
              (640...8192).contains(w), (480...8192).contains(h) else { return nil }
        return (w, h)
    }

    private func confirm() {
        guard !isCreating, let res = resolution else { return }
        let config = VirtualDisplayService.VirtualDisplayConfig(
            id: editing?.id ?? UUID(),
            name: name.isEmpty ? String(localized: "Virtual Display") : name,
            width: res.width,
            height: res.height,
            refreshRate: editing?.refreshRate ?? 60,
            hiDPI: true,
            autoCreate: autoCreate
        )
        onConfirm(config)
    }
}
