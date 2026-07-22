import SwiftUI

/// Horizontal slider to scrub through available resolution modes.
/// Left side: small monitor icon. Right side: "WxH" current resolution text.
/// Releasing the slider applies the selected mode.
struct ResolutionSliderView: View {
    @ObservedObject var display: DisplayInfo
    /// Index into display.availableModes
    @State private var sliderIndex: Double = 0
    @State private var isSwitching: Bool = false
    @State private var isDragging: Bool = false
    @State private var errorMessage: String?

    private var modes: [DisplayMode] { display.availableModes }

    private var maxIndex: Double {
        max(0, Double(modes.count - 1))
    }

    private var previewMode: DisplayMode? {
        guard !modes.isEmpty else { return nil }
        let idx = min(Int(sliderIndex.rounded()), modes.count - 1)
        return modes[idx]
    }

    /// Full resolution string with refresh rate: "2560×1440 @ 60Hz"
    private var previewModeFullString: String {
        guard let mode = previewMode else { return "—" }
        let res = mode.resolutionString
        let hz = mode.refreshRateString
        return "\(res) @ \(hz)"
    }

    /// Index of the recommended (native) mode, if any.
    private var recommendedIndex: Int? {
        modes.firstIndex(where: { $0.isNative })
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)

                Slider(
                    value: $sliderIndex,
                    in: 0...max(1, maxIndex),
                    step: 1
                ) { editing in
                    isDragging = editing
                    if !editing {
                        applySelectedMode()
                    }
                }
                .disabled(modes.isEmpty || isSwitching)
                .onReceive(display.$currentDisplayMode) { _ in
                    guard !isDragging else { return }
                    syncSliderToCurrentMode()
                }
                .onAppear {
                    syncSliderToCurrentMode()
                }

                Text(previewModeFullString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: sliderIndex)
            }

            // Milestone labels: Lowest / Recommended / Highest
            if modes.count > 1 {
                HStack(spacing: 0) {
                    // Modes are sorted descending: index 0 = highest resolution (left), last = lowest (right)
                    Text("Highest")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let recIdx = recommendedIndex {
                        let fraction = Double(recIdx) / Double(modes.count - 1)
                        // Offset text so it aligns with the slider thumb position
                        GeometryReader { geo in
                            let sliderWidth = geo.size.width
                            let offset = fraction * sliderWidth
                            HStack(spacing: 2) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 4, height: 4)
                                Text("Recommended")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                            }
                            .position(x: offset, y: geo.size.height / 2)
                        }
                        .frame(height: 12)
                    } else {
                        Spacer()
                    }
                    Text("Lowest")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func syncSliderToCurrentMode() {
        guard let current = display.currentDisplayMode,
              let idx = modes.firstIndex(where: { $0.id == current.id }) else { return }
        sliderIndex = Double(idx)
    }

    private func applySelectedMode() {
        guard !modes.isEmpty, !isSwitching else { return }
        let idx = min(Int(sliderIndex.rounded()), modes.count - 1)
        let selected = modes[idx]
        guard selected.id != display.currentDisplayMode?.id else { return }
        isSwitching = true
        Task { @MainActor in
            let success = await ResolutionService.shared.setDisplayMode(selected, for: display.displayID)
            if success {
                display.currentDisplayMode = selected
                errorMessage = nil
            } else {
                syncSliderToCurrentMode()
                errorMessage = "Switch failed, please try again"
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    errorMessage = nil
                }
            }
            isSwitching = false
        }
    }
}
