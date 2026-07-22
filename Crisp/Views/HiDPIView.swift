import SwiftUI

/// Single HiDPI switch: flips between the builtin Native/HiDPI presets, and
/// transparently installs the per-monitor override (admin prompt, one-time)
/// the first time it's enabled for a display that lacks it.
///
/// The switch is optimistic: it flips instantly on click and the resolution
/// change confirms it afterwards. The preset match is derived from display
/// modes that only settle seconds after an apply, so rendering the match
/// directly made the knob snap back and read stale.
struct HiDPIToggleRow: View {
    let displays: [DisplayInfo]  // external displays
    let nativePreset: DisplayPreset?
    let hidpiPreset: DisplayPreset?

    @ObservedObject private var presetService = PresetService.shared
    @State private var isOn = false
    @State private var isLoading = false
    @State private var reconnectNeeded = false
    @State private var errorMessage: String? = nil
    @State private var lastToggleAt = Date.distantPast

    /// Ground truth: the HiDPI preset matches the displays' current modes.
    private var matchedOn: Bool {
        hidpiPreset.map { presetService.currentPresetMatch() == $0.id } ?? false
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { userToggle($0) })) {
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
        .padding(.horizontal, 12)
        .onAppear { isOn = matchedOn }
        .onChange(of: matchedOn) { _, newValue in
            // Adopt external truth (Control Center, another app, a failed
            // apply) unless our own toggle is still settling.
            guard !isLoading, Date().timeIntervalSince(lastToggleAt) > 5 else { return }
            isOn = newValue
        }
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

    private func userToggle(_ on: Bool) {
        guard !isLoading, !presetService.isApplying else { return }
        // Optimistic: the knob moves now; the apply confirms (or reverts) it.
        isOn = on
        lastToggleAt = Date()
        isLoading = true
        Task {
            if on {
                // One-time: install the override for displays still lacking it.
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
                        isOn = false
                        isLoading = false
                        return
                    }
                    HiDPIService.shared.refreshModes(for: display)
                }
                if let hidpi = hidpiPreset {
                    await PresetService.shared.applyPreset(hidpi)
                } else {
                    // Override just installed but HiDPI modes aren't visible
                    // yet; honest state is off until the display reconnects.
                    reconnectNeeded = true
                    isOn = false
                }
            } else if let native = nativePreset {
                await PresetService.shared.applyPreset(native)
            }
            isLoading = false
            // Settle-check: once the mode change has had time to land, adopt
            // whatever is actually true (catches silent apply failures).
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !isLoading { isOn = matchedOn }
        }
    }
}
