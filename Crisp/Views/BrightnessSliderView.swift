import SwiftUI

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    var compact: Bool = false  // Compact mode: hides the mode label row (used for top-level inline sliders)
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row
            if !compact {
            HStack(spacing: 4) {
                Spacer()
                if display.isBuiltin {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("System")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if let status = ddcStatus {
                    Circle()
                        .fill(status ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(status ? "DDC" : "Software")
                        .font(.caption2)
                        .foregroundColor(status ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(display.isBuiltin ? "Brightness control mode: System" : "Brightness control mode: \(ddcStatus == true ? "DDC hardware" : "Software emulation")")
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture { step(-brightnessStep) }

                // Native macOS slider, exactly as in the system Display panel.
                // Apple tints the built-in display's fill accent blue, externals white.
                Slider(value: $localBrightness, in: 0...100) { editing in
                    isDragging = editing
                    if !editing {
                        Task { @MainActor in
                            // Flush the final value; the coalescing writer already tracked the drag.
                            await BrightnessService.shared.setBrightness(localBrightness, for: display)
                            updateDDCStatus()
                        }
                    }
                }
                .tint(display.isBuiltin ? Color.accentColor : .white)
                .controlSize(.small)
                .accessibilityLabel("Display brightness")
                .accessibilityValue("\(Int(localBrightness))%")
                .onChange(of: localBrightness) { _, newValue in
                    guard isDragging else { return }
                    // Apply immediately — the service chooses software or DDC internally,
                    // and its coalescing writer keeps the I2C bus from flooding.
                    display.brightness = newValue
                    Task { @MainActor in
                        await BrightnessService.shared.setBrightness(newValue, for: display)
                    }
                }

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture { step(brightnessStep) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            localBrightness = display.brightness
            updateDDCStatus()
        }
        .onChange(of: display.brightness) { _, newValue in
            // External change (preset fade, brightness keys, another app).
            // NSSlider renders value changes discretely (withAnimation does not
            // interpolate control values), so smoothness comes from the 60Hz
            // fade steps; track every one of them with a low threshold.
            if !isDragging && abs(newValue - localBrightness) >= 0.1 {
                localBrightness = newValue
            }
        }
    }

    private func updateDDCStatus() {
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
    }

    /// One brightness-key increment (16 steps across the range), same as native.
    private var brightnessStep: Double { 100.0 / 16.0 }

    private func step(_ delta: Double) {
        let target = max(0, min(100, display.brightness + delta))
        // The smooth fade updates display.brightness per frame; localBrightness
        // follows through the existing onChange sync.
        BrightnessService.shared.setBrightnessSmooth(target, for: display)
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double = 50
    @State private var isDragging: Bool = false

    private var averageBrightness: Double {
        guard !displays.isEmpty else { return 50 }
        return displays.map(\.brightness).reduce(0, +) / Double(displays.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Brightness (Combined)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(combinedBrightness))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture { stepAll(-100.0 / 16.0) }

                Slider(value: $combinedBrightness, in: 0...100) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag ended, flush final value to all displays.
                        Task { @MainActor in
                            for display in displays {
                                await BrightnessService.shared.setBrightness(combinedBrightness, for: display)
                            }
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("Combined brightness")
                .accessibilityValue("\(Int(combinedBrightness))%")
                .onChange(of: combinedBrightness) { _, newValue in
                    guard isDragging else { return }
                    Task { @MainActor in
                        for display in displays {
                            display.brightness = newValue
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    }
                }

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture { stepAll(100.0 / 16.0) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            combinedBrightness = averageBrightness
        }
    }

    private func stepAll(_ delta: Double) {
        let target = max(0, min(100, combinedBrightness + delta))
        combinedBrightness = target
        for display in displays {
            BrightnessService.shared.setBrightnessSmooth(target, for: display)
        }
    }
}
