import SwiftUI
import CoreGraphics

/// Tools > Virtual Displays: an on/off switch per saved virtual display, which is the part
/// changed often. Creating, editing and deleting are rare, so they live in Advanced Settings,
/// opened by the last row.
struct VirtualDisplayView: View {
    @StateObject private var service = VirtualDisplayService.shared
    let openManager: () -> Void
    @State private var activatingID: UUID?
    @State private var activateError: String?
    @State private var manageHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(service.configs) { config in
                VirtualDisplaySwitchRow(
                    config: config,
                    isOn: service.isActive(config.id),
                    isBusy: activatingID == config.id,
                    setOn: { on in
                        if on { activate(config) } else { service.destroy(configID: config.id) }
                    }
                )
            }
            if let activateError {
                Text(activateError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "gearshape", active: false)
                    .accessibilityHidden(true)
                Text("Manage Virtual Displays…")
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(manageHovered)
            .contentShape(Rectangle())
            .onTapGesture {
                guard PanelOpenGuard.allowsActivation else { return }
                openManager()
            }
            .onHover { manageHovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    /// Re-creates the live CGVirtualDisplay for a config that is off.
    private func activate(_ config: VirtualDisplayService.VirtualDisplayConfig) {
        guard activatingID == nil else { return }
        activatingID = config.id
        activateError = nil
        Task { @MainActor in
            let ok = await service.create(config: config)
            activatingID = nil
            if !ok {
                activateError = String(localized: "Failed to activate virtual display. Please try again.")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                activateError = nil
            }
        }
    }
}

private struct VirtualDisplaySwitchRow: View {
    let config: VirtualDisplayService.VirtualDisplayConfig
    let isOn: Bool
    let isBusy: Bool
    let setOn: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: "display.2", color: .blue, active: isOn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.body)
                    .lineLimit(1)
                Text(verbatim: VirtualDisplayService.summary(config))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { isOn }, set: { setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(config.name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

// MARK: - Advanced Settings tab

/// Advanced Settings > Virtual Displays: the saved virtual displays in a list with + and −,
/// as System Settings lists login items, and the selected one's settings below. A change
/// applies at once, as in any settings window; a size or refresh change on a display that
/// is on recreates it (VirtualDisplayService.updateConfig).
struct AdvancedVirtualDisplaysTab: View {
    @ObservedObject private var service = VirtualDisplayService.shared
    @State private var selection: UUID?
    @State private var confirmDelete = false
    @State private var errorText: String?
    @State private var newConfig: VirtualDisplayService.VirtualDisplayConfig?

    static let sizes: [(label: String, width: Int, height: Int)] = [
        ("1920×1080 (FHD)", 1920, 1080),
        ("2560×1440 (QHD)", 2560, 1440),
        ("3840×2160 (4K)", 3840, 2160),
        ("2732×2048 (iPad Pro 12.9″)", 2732, 2048),
        ("2388×1668 (iPad Pro 11″)", 2388, 1668),
        ("2360×1640 (iPad Air)", 2360, 1640),
        ("2048×1536 (iPad 4:3)", 2048, 1536)
    ]

    var body: some View {
        let selected = service.configs.first(where: { $0.id == selection }) ?? service.configs.first
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                    ForEach(service.configs) { config in
                        HStack {
                            Text(config.name)
                            Spacer()
                            Text(verbatim: VirtualDisplayService.summary(config)).foregroundStyle(.secondary)
                        }
                        .tag(config.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 110)
                .overlay {
                    // The + below is easy to miss on an empty list, so say what to do here.
                    if service.configs.isEmpty {
                        VStack(spacing: 8) {
                            Text("No virtual displays yet").foregroundStyle(.secondary)
                            Button("Create Virtual Display") { add() }
                        }
                    }
                }
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                        .accessibilityLabel("Create Virtual Display")
                    Divider().frame(height: 14)
                    Button { confirmDelete = true } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .disabled(selected == nil)
                        .accessibilityLabel("Delete")
                    Spacer()
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, selected == nil ? 20 : 0)  // the editor's form has its own margin
            if let selected {
                VirtualDisplayEditor(config: selected, onError: showError).id(selected.id)
            }
        }
        .frame(maxWidth: .infinity)  // the window sets the width, scroll bar included
        .sheet(item: $newConfig) { config in
            VirtualDisplayEditor(config: config, onError: showError, onCreate: create)
                .frame(width: 440)
        }
        .alert("Confirm Deletion", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = selected?.id { service.removeConfig(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let id = selected?.id, service.isActive(id) {
                Text("This virtual display is currently active. Deleting it will disable it immediately.")
            } else {
                Text("Are you sure you want to delete this virtual display configuration?")
            }
        }
    }

    /// + makes and turns on a new display at the first size not saved yet, then selects it.
    /// + opens the create sheet, starting at the first size not saved yet.
    private func add() {
        let size = Self.sizes.first { size in
            !service.configs.contains { $0.width == size.width && $0.height == size.height }
        } ?? Self.sizes[0]
        newConfig = VirtualDisplayService.VirtualDisplayConfig(
            name: String(localized: "Virtual Display"), width: size.width, height: size.height)
    }

    private func create(_ config: VirtualDisplayService.VirtualDisplayConfig) async -> Bool {
        if await service.addAndCreate(config) {
            selection = config.id
            return true
        }
        showError(String(localized: "Failed to create virtual display. Please try again."))
        return false
    }

    private func showError(_ text: String) {
        errorText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            errorText = nil
        }
    }
}

/// The settings of one virtual display. For a saved display (`onCreate` nil) every change
/// applies at once; for a new one (`onCreate` set, shown in a sheet) nothing happens until
/// Create, and Cancel drops it.
private struct VirtualDisplayEditor: View {
    let onError: (String) -> Void
    let onCreate: ((VirtualDisplayService.VirtualDisplayConfig) async -> Bool)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VirtualDisplayService.VirtualDisplayConfig
    @State private var name: String
    @State private var custom: Bool
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var isCreating = false

    init(config: VirtualDisplayService.VirtualDisplayConfig, onError: @escaping (String) -> Void,
         onCreate: ((VirtualDisplayService.VirtualDisplayConfig) async -> Bool)? = nil) {
        self.onError = onError
        self.onCreate = onCreate
        _draft = State(initialValue: config)
        _name = State(initialValue: config.name)
        let isPreset = AdvancedVirtualDisplaysTab.sizes.contains { $0.width == config.width && $0.height == config.height }
        _custom = State(initialValue: !isPreset)
        _customWidth = State(initialValue: String(config.width))
        _customHeight = State(initialValue: String(config.height))
    }

    private var isNew: Bool { onCreate != nil }

    var body: some View {
        if isNew {
            // A sheet sizes to the form's minimum, which is near zero for a grouped form,
            // so the sheet gets a height and its buttons sit under the form, not over it.
            VStack(spacing: 0) {
                form.frame(height: custom ? 236 : 200)
                HStack {
                    Spacer()
                    if isCreating { ProgressView().controlSize(.small) }
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isCreating || (custom && customSize == nil))
                }
                .padding([.horizontal, .bottom], 20)
            }
        } else {
            form.onDisappear { commitName() }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { commitName() }
                Picker("Resolution", selection: Binding(
                    get: { custom ? -1 : sizeIndex },
                    set: { index in
                        if index < 0 {
                            custom = true
                        } else {
                            custom = false
                            let size = AdvancedVirtualDisplaysTab.sizes[index]
                            save { $0.width = size.width; $0.height = size.height }
                        }
                    }
                )) {
                    ForEach(AdvancedVirtualDisplaysTab.sizes.indices, id: \.self) { i in
                        Text(verbatim: AdvancedVirtualDisplaysTab.sizes[i].label).tag(i)
                    }
                    Text("Custom…").tag(-1)
                }
                if custom {
                    LabeledContent("Custom…") {
                        HStack(spacing: 6) {
                            TextField("Width", text: $customWidth).frame(width: 64)
                            Text(verbatim: "×").foregroundStyle(.secondary)
                            TextField("Height", text: $customHeight).frame(width: 64)
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitCustomSize() }
                    }
                }
                Picker("Refresh Rate", selection: Binding(
                    get: { draft.refreshRate },
                    set: { rate in save { $0.refreshRate = rate } }
                )) {
                    ForEach(rateOptions, id: \.self) { Text(verbatim: RefreshRateFormat.label($0)).tag($0) }
                }
                Toggle("Create at launch", isOn: Binding(
                    get: { draft.autoCreate },
                    set: { on in save { $0.autoCreate = on } }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // the window's scroll view scrolls; the sheet's form is sized to fit
    }

    private var sizeIndex: Int {
        AdvancedVirtualDisplaysTab.sizes.firstIndex { $0.width == draft.width && $0.height == draft.height } ?? -1
    }

    /// Keeps a rate saved before the list changed selectable.
    private var rateOptions: [Double] {
        let options = VirtualDisplayService.refreshRateOptions
        return options.contains(draft.refreshRate) ? options : (options + [draft.refreshRate]).sorted()
    }

    /// Same bounds as before the move: 640...8192 by 480...8192.
    private var customSize: (width: Int, height: Int)? {
        guard let width = Int(customWidth), let height = Int(customHeight),
              (640...8192).contains(width), (480...8192).contains(height) else { return nil }
        return (width, height)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        save { $0.name = trimmed }
    }

    /// On Return only: typing 1920 passes through 192, which must not resize a live display.
    private func commitCustomSize() {
        guard let size = customSize else { return }
        save { $0.width = size.width; $0.height = size.height }
    }

    private func save(_ change: (inout VirtualDisplayService.VirtualDisplayConfig) -> Void) {
        var updated = draft
        change(&updated)
        guard updated != draft else { return }
        draft = updated
        guard !isNew else { return }
        Task { @MainActor in
            if !(await VirtualDisplayService.shared.updateConfig(updated)) {
                onError(String(localized: "Failed to update virtual display. Please try again."))
            }
        }
    }

    private func create() {
        guard let onCreate, !isCreating else { return }
        commitName()
        if custom { commitCustomSize() }
        isCreating = true
        Task { @MainActor in
            let ok = await onCreate(draft)
            isCreating = false
            if ok { dismiss() }
        }
    }
}
