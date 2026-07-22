import SwiftUI

/// Single HiDPI switch: flips between the builtin Native/HiDPI presets, and
/// transparently installs the per-monitor override (admin prompt, one-time)
/// the first time it's enabled for a display that lacks it.
struct HiDPIToggleRow: View {
    let displays: [DisplayInfo]  // external displays
    let nativePreset: DisplayPreset?
    let hidpiPreset: DisplayPreset?

    @ObservedObject private var presetService = PresetService.shared
    @State private var isLoading = false
    @State private var reconnectNeeded = false
    @State private var errorMessage: String? = nil

    private var isOn: Bool {
        hidpiPreset.map { presetService.currentPresetMatch() == $0.id } ?? false
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { setHiDPI($0) })) {
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "sparkles", color: .purple)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HiDPI")
                        .font(.body)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(reconnectNeeded ? .orange : .secondary)
                    }
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isLoading || presetService.isApplying)
        .padding(.horizontal, 12)
        .alert("HiDPI Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }

    private var subtitle: String? {
        if reconnectNeeded { return "Reconnect the display to finish" }
        if !isOn && overridesMissing { return "First enable asks for an administrator password" }
        return nil
    }

    private var overridesMissing: Bool {
        displays.contains {
            !HiDPIService.shared.isHiDPIEnabled(vendor: $0.vendorNumber, product: $0.modelNumber)
        }
    }

    private func setHiDPI(_ on: Bool) {
        guard !isLoading else { return }
        if !on {
            guard let native = nativePreset else { return }
            Task { await PresetService.shared.applyPreset(native) }
            return
        }
        isLoading = true
        Task {
            // One-time: install the override for any display still lacking it.
            for display in displays where !HiDPIService.shared.isHiDPIEnabled(
                vendor: display.vendorNumber, product: display.modelNumber
            ) {
                let (nativeW, nativeH) = display.nativeResolution
                let err = await HiDPIService.shared.enableHiDPI(
                    for: display.displayID,
                    vendor: display.vendorNumber,
                    product: display.modelNumber,
                    nativeWidth: nativeW,
                    nativeHeight: nativeH
                )
                if let err {
                    errorMessage = err
                    isLoading = false
                    return
                }
                HiDPIService.shared.refreshModes(for: display)
            }
            if let hidpi = hidpiPreset {
                await PresetService.shared.applyPreset(hidpi)
            } else {
                // Override just installed but HiDPI modes aren't visible yet.
                reconnectNeeded = true
            }
            isLoading = false
        }
    }
}
