import SwiftUI
import CoreGraphics

/// "Virtual Displays" management section shown in the MenuBarView tools area.
/// Lists all saved virtual display configurations and allows creating / deleting them.
struct VirtualDisplayView: View {
    @StateObject private var service = VirtualDisplayService.shared
    @State private var showCreateForm = false
    @State private var configToDelete: UUID?
    @State private var isCreating: Bool = false
    @State private var createError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.configs.isEmpty {
                Text("No virtual displays yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(service.configs) { config in
                    configRow(config: config)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
            }

            // "+" create button
            Button(action: { showCreateForm.toggle() }) {
                HStack {
                    Image(systemName: showCreateForm ? "minus.circle.fill" : "plus.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(showCreateForm ? "Cancel" : "Create Virtual Display")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if let err = createError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            if showCreateForm {
                CreateVirtualDisplayForm(isCreating: $isCreating, onConfirm: { config in
                    isCreating = true
                    createError = nil
                    Task { @MainActor in
                        let success = await service.addAndCreate(config)
                        isCreating = false
                        if success {
                            showCreateForm = false
                        } else {
                            createError = "Failed to create virtual display. Please try again."
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                createError = nil
                            }
                        }
                    }
                })
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
    }

    // MARK: - Config Row

    @ViewBuilder
    private func configRow(config: VirtualDisplayService.VirtualDisplayConfig) -> some View {
        let active = service.isActive(config.id)

        HStack(spacing: 8) {
            Image(systemName: "display.2")
                .foregroundColor(active ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(config.width)×\(config.height)\(config.hiDPI ? " · HiDPI" : "") · \(Int(config.refreshRate))Hz")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Active / inactive badge
            if active {
                Text("Active")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .cornerRadius(4)
            }

            // Delete button
            Button(action: {
                configToDelete = config.id
            }) {
                Label("Delete", systemImage: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.08))
        )
        .contextMenu {
            Button(role: .destructive) {
                configToDelete = config.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Create Form

/// Inline form for creating a new virtual display configuration.
struct CreateVirtualDisplayForm: View {
    @Binding var isCreating: Bool
    let onConfirm: (VirtualDisplayService.VirtualDisplayConfig) -> Void

    @State private var name: String = "Virtual Display"
    @State private var selectedPreset: Int = 0
    @State private var hiDPI: Bool = true
    @State private var autoCreate: Bool = true

    private let presets: [(label: String, width: Int, height: Int)] = [
        ("1920×1080 (FHD)", 1920, 1080),
        ("2560×1440 (QHD)", 2560, 1440),
        ("3840×2160 (4K)",  3840, 2160),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name field
            HStack {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
                TextField("Display Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            // Resolution preset picker
            HStack {
                Text("Resolution")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
                Picker("", selection: $selectedPreset) {
                    ForEach(presets.indices, id: \.self) { i in
                        Text(presets[i].label).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .labelsHidden()
            }

            // HiDPI toggle
            HStack {
                Text("HiDPI")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
                Toggle("", isOn: $hiDPI)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                Text("Enable high-resolution scaling")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Auto-create toggle
            HStack {
                Text("Auto")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
                Toggle("", isOn: $autoCreate)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                Text("Create automatically at launch")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Confirm button
            Button(action: confirm) {
                HStack(spacing: 6) {
                    if isCreating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    }
                    Text(isCreating ? "Creating..." : "Create")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isCreating)
        }
        .padding(.vertical, 4)
    }

    private func confirm() {
        guard !isCreating else { return }
        let preset = presets[selectedPreset]
        let config = VirtualDisplayService.VirtualDisplayConfig(
            name: name.isEmpty ? "Virtual Display" : name,
            width: preset.width,
            height: preset.height,
            refreshRate: 60,
            hiDPI: hiDPI,
            autoCreate: autoCreate
        )
        onConfirm(config)
    }
}
