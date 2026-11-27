import SwiftUI

// MARK: - Panel Blocks (Menu Bar Panel > Display Detail > Picture)

/// Underscan disclosure header row inside a display's expanded Picture group.
/// Shown for physical external displays only (built-in displays do not support native
/// underscan and must never auto-apply experimental underscan).
struct UnderscanHeadBlock: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var state: PanelSectionState
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var underscan = UnderscanService.shared

    private var liveState: UnderscanDisplayState {
        underscan.state(for: display, among: displayManager.displays)
    }

    private var subtitle: String {
        let current = liveState
        if current.settings.autoRestoreSuspended {
            return String(localized: "Paused")
        }
        if current.isControlUsable {
            return "\(current.requestedPercentage)%"
        }
        return String(localized: "Unsupported")
    }

    var body: some View {
        if !display.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay(display.displayID) {
            let current = liveState
            let active = current.settings.isEnabled
                && current.isControlUsable
                && current.requestedPercentage < UnderscanValue.defaultPercentage
            ExpandableRow(
                icon: "rectangle.inset.filled",
                iconActive: active,
                label: "Underscan",
                subtitle: subtitle,
                isExpanded: state.openBinding(\.underscanOpenIDs, display.displayID)
            )
            .task(id: display.displayID) {
                await underscan.refresh(display: display, among: displayManager.displays)
            }
            .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
                Task { await underscan.refresh(display: display, among: displayManager.displays) }
            }
        }
    }
}

/// Expanded Underscan slider, status, reset, and experimental confirmation / rollback controls
/// inside the menu bar panel.
struct UnderscanBodyBlock: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var underscan = UnderscanService.shared

    var body: some View {
        if !display.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay(display.displayID) {
            UnderscanPanelControlView(
                display: display,
                liveState: underscan.state(for: display, among: displayManager.displays)
            )
        }
    }
}

private struct UnderscanPanelControlView: View {
    @ObservedObject var display: DisplayInfo
    let liveState: UnderscanDisplayState
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var underscan = UnderscanService.shared

    @State private var sliderValue: Double = Double(UnderscanValue.defaultPercentage)
    @State private var isDragging = false

    private var range: ClosedRange<Int> { liveState.capability.percentageRange }

    private var needsExperimentalConfirmation: Bool {
        !liveState.capability.isNativelySupported
            && liveState.settings.forceEnableExperimental
            && !liveState.settings.hasConfirmedExperimentalRisk
    }

    private var sliderDisabled: Bool {
        !liveState.isControlUsable || needsExperimentalConfirmation
    }

    private var canReset: Bool {
        guard liveState.isControlUsable, !needsExperimentalConfirmation else { return false }
        return Int(sliderValue.rounded()) < UnderscanValue.defaultPercentage
            || liveState.requestedPercentage < UnderscanValue.defaultPercentage
            || (liveState.lastSubmittedPercentage ?? UnderscanValue.defaultPercentage) < UnderscanValue.defaultPercentage
            || (liveState.hardwareConfirmedPercentage ?? UnderscanValue.defaultPercentage) < UnderscanValue.defaultPercentage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sliderRow

            Text("Shrinks the visible desktop area with black borders while keeping native resolution and HiDPI scaling.")
                .font(.caption2)
                .foregroundColor(.secondaryReadable)
                .fixedSize(horizontal: false, vertical: true)

            statusBadge

            if needsExperimentalConfirmation {
                experimentalConfirmationBanner
            }

            if let rollback = liveState.pendingRollback {
                rollbackBanner(rollback)
            }

            if liveState.settings.autoRestoreSuspended {
                suspendedRecoveryRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            sliderValue = Double(liveState.requestedPercentage)
        }
        .onChange(of: liveState.requestedPercentage) { _, newValue in
            if !isDragging {
                sliderValue = Double(newValue)
            }
        }
    }

    private var sliderRow: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { sliderValue },
                    set: { newValue in
                        let snapped = newValue.rounded()
                        sliderValue = snapped
                        if isDragging {
                            underscan.setSliderPercentage(
                                Int(snapped),
                                for: display,
                                among: displayManager.displays,
                                commitImmediately: false
                            )
                        }
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            ) { editing in
                isDragging = editing
                if !editing {
                    let target = Int(sliderValue.rounded())
                    underscan.setSliderPercentage(
                        target,
                        for: display,
                        among: displayManager.displays,
                        commitImmediately: true
                    )
                }
            }
            .controlSize(.small)
            .disabled(sliderDisabled)
            .accessibilityLabel("Display underscan")
            .accessibilityValue("\(Int(sliderValue.rounded()))%")
            .accessibilityHint("Adjusts visible desktop area between \(String(range.lowerBound))% and \(String(range.upperBound))%")

            Text("\(Int(sliderValue.rounded()))%")
                .font(.caption)
                .foregroundColor(sliderDisabled ? .secondary : .primary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)

            Button {
                Task { await underscan.resetToFullScreen(for: display, among: displayManager.displays) }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!canReset)
            .help("Reset Underscan to 100%")
            .accessibilityLabel("Reset Underscan to 100%")
        }
    }

    private var statusBadge: some View {
        let presentation = UnderscanStatusPresentation.describe(liveState)
        return HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(presentation.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: presentation.headline)
                    .font(.caption2)
                    .foregroundColor(presentation.isError ? .red : .secondaryReadable)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = presentation.detail {
                    Text(verbatim: detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var experimentalConfirmationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Experimental Underscan Confirmation")
                .font(.caption)
                .fontWeight(.semibold)
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("Forced native underscan is experimental on Apple Silicon and may have no effect or cause temporary display glitches. Confirm before testing.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Confirm Test") {
                    underscan.confirmExperimentalRisk(for: display, among: displayManager.displays)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                Button("Cancel") {
                    underscan.updateSettings(for: display, among: displayManager.displays) {
                        $0.forceEnableExperimental = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private func rollbackBanner(_ rollback: UnderscanRollbackConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Keep \(String(rollback.testedPercentage))% underscan? Reverting to \(String(rollback.previousKnownGoodPercentage))% in \(String(rollback.remainingSeconds))s."
            )
            .font(.caption)
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)
            Text("Automatic rollback depends on macOS accepting the revert request.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Keep") {
                    underscan.keepExperimentalChange(forKey: rollback.displayKey)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                Button("Revert Now") {
                    Task { await underscan.revertExperimentalChange(for: display, among: displayManager.displays) }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
    }

    private var suspendedRecoveryRow: some View {
        HStack {
            Text("Automatic restore suspended")
                .font(.caption2)
                .foregroundColor(.orange)
            Spacer()
            Button("Resume Auto-Restore") {
                underscan.resumeAutoRestore(for: display, among: displayManager.displays)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }
}

// MARK: - Advanced Settings > Displays > Underscan Section

/// Per-display Underscan settings section for `AdvancedDisplayPage`.
struct AdvancedUnderscanSection: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var underscan = UnderscanService.shared

    @State private var sliderValue: Double = Double(UnderscanValue.defaultPercentage)
    @State private var isDragging = false

    private var liveState: UnderscanDisplayState {
        underscan.state(for: display, among: displayManager.displays)
    }

    private var range: ClosedRange<Int> { liveState.capability.percentageRange }

    private var needsExperimentalConfirmation: Bool {
        !liveState.capability.isNativelySupported
            && liveState.settings.forceEnableExperimental
            && !liveState.settings.hasConfirmedExperimentalRisk
    }

    private var sliderDisabled: Bool {
        !liveState.isControlUsable || needsExperimentalConfirmation
    }

    var body: some View {
        let state = liveState
        let presentation = UnderscanStatusPresentation.describe(state)
        Section("Underscan") {
            CenteredRow(
                title: "Hardware Status",
                detail: Text(verbatim: [presentation.headline, presentation.detail].compactMap { $0 }.joined(separator: " "))
            ) {
                Circle()
                    .fill(presentation.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            if !display.isBuiltin {
                HStack(spacing: 10) {
                    Text("Underscan")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { sliderValue },
                            set: { newValue in
                                let snapped = newValue.rounded()
                                sliderValue = snapped
                                if isDragging {
                                    underscan.setSliderPercentage(
                                        Int(snapped),
                                        for: display,
                                        among: displayManager.displays,
                                        commitImmediately: false
                                    )
                                }
                            }
                        ),
                        in: Double(range.lowerBound)...Double(range.upperBound)
                    ) { editing in
                        isDragging = editing
                        if !editing {
                            underscan.setSliderPercentage(
                                Int(sliderValue.rounded()),
                                for: display,
                                among: displayManager.displays,
                                commitImmediately: true
                            )
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .disabled(sliderDisabled)
                    .accessibilityLabel("Display underscan")
                    .accessibilityValue("\(Int(sliderValue.rounded()))%")

                    Text("\(Int(sliderValue.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)

                    Button("Reset") {
                        Task { await underscan.resetToFullScreen(for: display, among: displayManager.displays) }
                    }
                    .disabled(!state.isControlUsable || needsExperimentalConfirmation)
                    .help("Reset Underscan to 100%")
                }

                if needsExperimentalConfirmation {
                    CenteredRow(
                        title: "Confirm Experimental Hardware Test",
                        detail: Text("Required before sending the first forced native underscan call on this monitor.")
                    ) {
                        HStack(spacing: 8) {
                            Button("Cancel") {
                                underscan.updateSettings(for: display, among: displayManager.displays) {
                                    $0.forceEnableExperimental = false
                                }
                            }
                            Button("Confirm Test") {
                                underscan.confirmExperimentalRisk(for: display, among: displayManager.displays)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if let rollback = state.pendingRollback {
                    CenteredRow(
                        title: "Confirm Experimental Underscan",
                        detail: Text(
                            "Keep \(String(rollback.testedPercentage))%? Reverting to \(String(rollback.previousKnownGoodPercentage))% in \(String(rollback.remainingSeconds))s. Rollback depends on macOS accepting the revert call."
                        )
                    ) {
                        HStack(spacing: 8) {
                            Button("Revert Now") {
                                Task { await underscan.revertExperimentalChange(for: display, among: displayManager.displays) }
                            }
                            Button("Keep") {
                                underscan.keepExperimentalChange(forKey: rollback.displayKey)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Toggle("Enable Underscan", isOn: settingsBinding(\.isEnabled, onDisable: {
                    Task { await underscan.disableUnderscan(for: display, among: displayManager.displays) }
                }))
                .disabled(!state.isControlUsable)

                Toggle("Remember Underscan Value", isOn: settingsBinding(\.rememberValue))
                Toggle("Automatically Restore Underscan", isOn: settingsBinding(\.autoRestore))
                Toggle("Restore After Sleep", isOn: settingsBinding(\.restoreAfterSleep))
                    .disabled(!state.settings.autoRestore)
                Toggle("Restore After Display Reconnection", isOn: settingsBinding(\.restoreAfterReconnect))
                    .disabled(!state.settings.autoRestore)
                Toggle("Restore After Resolution Changes", isOn: settingsBinding(\.restoreAfterResolutionChange))
                    .disabled(!state.settings.autoRestore)

                if !state.capability.isNativelySupported {
                    CenteredRow(
                        title: "Force-enable Native Underscan (Experimental)",
                        // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                        detail: Text("Exposes the native underscan control even when macOS reports this display as unsupported. Hardware compatibility and readback are not guaranteed on Apple Silicon.")
                    ) {
                        Toggle("Force-enable Native Underscan (Experimental)", isOn: settingsBinding(\.forceEnableExperimental))
                            .labelsHidden()
                            .disabled(!state.capability.canUseWithExperimentalForce)
                    }
                }

                CenteredRow(
                    title: "Display Recovery",
                    detail: Text("Reset this display to 100% or stop automatic underscan restoration.")
                ) {
                    HStack(spacing: 8) {
                        if state.settings.autoRestoreSuspended {
                            Button("Resume Auto-Restore") {
                                underscan.resumeAutoRestore(for: display, among: displayManager.displays)
                            }
                        }
                        Button("Reset to 100%") {
                            Task { await underscan.resetToFullScreen(for: display, among: displayManager.displays) }
                        }
                        .disabled(!state.isControlUsable)
                        Button("Disable Underscan") {
                            Task { await underscan.disableUnderscan(for: display, among: displayManager.displays) }
                        }
                    }
                }
            }
        }
        .task(id: display.displayID) {
            await underscan.refresh(display: display, among: displayManager.displays)
            sliderValue = Double(underscan.state(for: display, among: displayManager.displays).requestedPercentage)
        }
        .onChange(of: state.requestedPercentage) { _, newValue in
            if !isDragging { sliderValue = Double(newValue) }
        }
    }

    private func settingsBinding(
        _ keyPath: WritableKeyPath<DisplayUnderscanSettings, Bool>,
        onDisable: (() -> Void)? = nil
    ) -> Binding<Bool> {
        Binding(
            get: { liveState.settings[keyPath: keyPath] },
            set: { newValue in
                if !newValue, let onDisable {
                    onDisable()
                    return
                }
                underscan.updateSettings(for: display, among: displayManager.displays) { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

// MARK: - Advanced Settings > General > Global Underscan Recovery

struct AdvancedUnderscanRecoverySection: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var underscan = UnderscanService.shared
    @State private var confirmDisableAll = false

    var body: some View {
        Section("Underscan") {
            CenteredRow(
                title: "Disable All Underscan Settings",
                detail: Text("Stops automatic restoration on every monitor and resets active external displays back to 100%.")
            ) {
                Button("Disable All", role: .destructive) {
                    confirmDisableAll = true
                }
            }
        }
        .confirmationDialog(
            "Disable all underscan settings?",
            isPresented: $confirmDisableAll
        ) {
            Button("Disable All & Reset to 100%", role: .destructive) {
                Task { await underscan.disableAllUnderscan(displays: displayManager.displays) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every monitor's underscan setting will be disabled and active displays will be reset to 100% where supported.")
        }
    }
}

// MARK: - Status Formatting Helper

private struct UnderscanStatusPresentation {
    let headline: String
    let detail: String?
    let color: Color
    let isError: Bool

    static func describe(_ state: UnderscanDisplayState) -> UnderscanStatusPresentation {
        if case .suspended(let count, let lastError) = state.status {
            return UnderscanStatusPresentation(
                headline: String(localized: "Auto-restore paused after \(String(count)) failed attempts."),
                detail: lastError,
                color: .orange,
                isError: false
            )
        }
        if case .failed(let error) = state.status {
            return UnderscanStatusPresentation(
                headline: error.description,
                detail: verificationSummary(state),
                color: .red,
                isError: true
            )
        }

        switch state.capability.availability {
        case .nativeSupported(_, _, let canReadback):
            if let confirmed = state.hardwareConfirmedPercentage {
                return UnderscanStatusPresentation(
                    headline: String(localized: "Native underscan supported · Confirmed \(String(confirmed))%"),
                    detail: verificationSummary(state),
                    color: .green,
                    isError: false
                )
            }
            if let submitted = state.lastSubmittedPercentage {
                let unconfirmedNote = String(
                    localized: "Hardware readback is unavailable; tracking last requested value locally."
                )
                return UnderscanStatusPresentation(
                    headline: String(localized: "Native underscan supported · Submitted \(String(submitted))% (unconfirmed)"),
                    detail: canReadback ? nil : unconfirmedNote,
                    color: .blue,
                    isError: false
                )
            }
            return UnderscanStatusPresentation(
                headline: String(localized: "Native underscan supported"),
                detail: nil,
                color: .green,
                isError: false
            )

        case .unsupportedHardware(let reason):
            if state.settings.forceEnableExperimental {
                let headline: String
                if let submitted = state.lastSubmittedPercentage {
                    headline = String(localized: "Experimental force-enabled · Submitted \(String(submitted))% (unconfirmed)")
                } else {
                    headline = String(localized: "Experimental force-enabled · Hardware readback unavailable")
                }
                return UnderscanStatusPresentation(
                    headline: headline,
                    detail: String(localized: "Requested \(String(state.requestedPercentage))%. Hardware confirmation is skipped on unsupported displays."),
                    color: .orange,
                    isError: false
                )
            }
            return UnderscanStatusPresentation(
                headline: reason,
                detail: String(localized: "Enable Force-enable Native Underscan (Experimental) in Advanced Settings > Displays to test."),
                color: .secondary,
                isError: false
            )

        case .builtInRestricted:
            return UnderscanStatusPresentation(
                headline: String(localized: "Native underscan is not supported on the built-in display."),
                detail: nil,
                color: .secondary,
                isError: false
            )

        case .virtualDisplayUnsupported:
            return UnderscanStatusPresentation(
                headline: String(localized: "Native underscan is not available on virtual displays."),
                detail: nil,
                color: .secondary,
                isError: false
            )

        case .frameworkUnavailable(let framework):
            return UnderscanStatusPresentation(
                headline: String(localized: "Required macOS framework unavailable (\(framework))."),
                detail: nil,
                color: .red,
                isError: true
            )

        case .symbolMissing(let symbol):
            return UnderscanStatusPresentation(
                headline: String(localized: "Native underscan API symbol unavailable (\(symbol))."),
                detail: nil,
                color: .red,
                isError: true
            )

        case .invalidSignature(let symbol):
            return UnderscanStatusPresentation(
                headline: String(localized: "Incompatible macOS API signature (\(symbol))."),
                detail: nil,
                color: .red,
                isError: true
            )

        case .displayNotFound:
            return UnderscanStatusPresentation(
                headline: String(localized: "Display is currently offline."),
                detail: nil,
                color: .secondary,
                isError: false
            )
        }
    }

    private static func verificationSummary(_ state: UnderscanDisplayState) -> String? {
        var parts: [String] = [String(localized: "Requested: \(String(state.requestedPercentage))%")]
        if let submitted = state.lastSubmittedPercentage {
            parts.append(String(localized: "Submitted: \(String(submitted))%"))
        }
        if let confirmed = state.hardwareConfirmedPercentage {
            parts.append(String(localized: "Hardware-confirmed: \(String(confirmed))%"))
        } else {
            parts.append(String(localized: "Hardware-confirmed: Unavailable"))
        }
        return parts.joined(separator: " · ")
    }
}
