import SwiftUI

/// Resolution and refresh-rate selection as native dropdown menus,
/// like the system Displays panel: one row per setting, NSMenu-backed pickers.
struct DisplayModeListView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isSwitching: Bool = false
    @State private var errorMessage: String?
    @State private var selectedGroupID: String = ""
    @State private var selectedModeID: Int32 = 0

    private var currentMode: DisplayMode? { display.currentDisplayMode }

    /// Group modes by (resolution + HiDPI), sorted by resolution descending.
    private var resolutionGroups: [ResolutionGroup] {
        let base = display.availableModes.filter {
            $0.width >= 1280 && $0.height >= 720
        }

        var grouped: [String: [DisplayMode]] = [:]
        for mode in base {
            let key = "\(mode.width)x\(mode.height)_\(mode.isHiDPI)"
            grouped[key, default: []].append(mode)
        }

        return grouped.map { (_, modes) in
            let sorted = modes.sorted { $0.refreshRate > $1.refreshRate }
            return ResolutionGroup(
                width: sorted[0].width,
                height: sorted[0].height,
                isHiDPI: sorted[0].isHiDPI,
                modes: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return false
        }
    }

    private var currentGroup: ResolutionGroup? {
        resolutionGroups.first { $0.modes.contains { $0.id == currentMode?.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if resolutionGroups.isEmpty {
                Text("No display modes available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                HStack {
                    Text("Resolution")
                        .font(.body)
                    Spacer()
                    if isSwitching {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    }
                    Picker("", selection: $selectedGroupID) {
                        ForEach(resolutionGroups) { group in
                            Text(group.menuLabel).tag(group.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 190)
                    .disabled(isSwitching)
                    .onChange(of: selectedGroupID) { _, newValue in
                        guard let group = resolutionGroups.first(where: { $0.id == newValue }),
                              group.id != currentGroup?.id else { return }
                        // Keep the refresh rate when the new resolution offers it
                        let target = group.modes.first { $0.refreshRate == currentMode?.refreshRate } ?? group.bestMode
                        switchTo(target)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                if let group = currentGroup, group.hasMultipleRates {
                    HStack {
                        Text("Refresh Rate")
                            .font(.body)
                        Spacer()
                        Picker("", selection: $selectedModeID) {
                            ForEach(group.modes) { mode in
                                Text(mode.refreshRateString).tag(mode.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 130)
                        .disabled(isSwitching)
                        .onChange(of: selectedModeID) { _, newValue in
                            guard newValue != currentMode?.id,
                                  let mode = group.modes.first(where: { $0.id == newValue }) else { return }
                            switchTo(mode)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            if let msg = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .transition(.opacity)
            }
        }
        .task(id: currentMode?.id) { syncSelection() }
    }

    private func syncSelection() {
        selectedGroupID = currentGroup?.id ?? ""
        selectedModeID = currentMode?.id ?? 0
    }

    // MARK: - Actions

    private func switchTo(_ mode: DisplayMode) {
        guard !isSwitching else { return }
        isSwitching = true
        let displayID = display.displayID
        Task { @MainActor in
            var success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            if !success {
                try? await Task.sleep(nanoseconds: 200_000_000)
                success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            }
            if success {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let refreshedMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: displayID)
                }.value
                if let rm = refreshedMode, rm.width == mode.width && rm.height == mode.height {
                    display.currentDisplayMode = rm
                } else {
                    display.currentDisplayMode = mode
                }
                errorMessage = nil
            } else {
                withAnimation {
                    errorMessage = "Unable to switch to \(mode.resolutionString), please try again"
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { errorMessage = nil }
                }
            }
            isSwitching = false
            syncSelection()
        }
    }
}

// MARK: - Data model

private struct ResolutionGroup: Identifiable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    let modes: [DisplayMode] // sorted by refresh rate descending

    var id: String { "\(width)x\(height)_\(isHiDPI)" }
    var resolutionString: String { "\(width)×\(height)" }
    var menuLabel: String { isHiDPI ? "\(resolutionString) (HiDPI)" : resolutionString }
    var hasMultipleRates: Bool { modes.count > 1 }
    var bestMode: DisplayMode { modes[0] }
}
