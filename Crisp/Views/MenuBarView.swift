import SwiftUI

// MARK: - Shared Icon Helper

/// A colored circular SF Symbol icon chip, macOS 26 Control Center style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(color))
    }
}

/// Native menus ignore activation for a moment after opening, so a fast
/// second click aimed at the status item can't trigger whatever row happens
/// to appear under the cursor. Same rule here.
@MainActor
enum PanelOpenGuard {
    static var openedAt = Date.distantPast
    static var allowsActivation: Bool { Date().timeIntervalSince(openedAt) > 0.25 }
}

/// The content view remounts on every panel open, resetting @State. Remembering
/// the measured height lets the panel render at the right size on the first
/// frame instead of reflowing (which shifts rows under a stationary cursor).
@MainActor
enum PanelMetrics {
    static var lastContentHeight: CGFloat = 0
    /// Set per-screen on panel open; the ScrollView caps at this so the panel
    /// only actually scrolls when content exceeds the screen.
    static var maxContentHeight: CGFloat = 600
}

extension Animation {
    /// Duration shared by the SwiftUI spring and the panel window's mirror
    /// spring (MenuPanel.applyContentSize); change both by changing this.
    static let panelResizeDuration: Double = 0.18
    /// The one curve every panel size change shares (rows, footer, window):
    /// the smooth spring Control Center panels use when a list expands.
    static let panelResize = Animation.smooth(duration: panelResizeDuration)
}

/// Native list expansion (the Wi-Fi panel's "Other Networks" format): the
/// content is always laid out at full size and full opacity; expanding just
/// uncovers it downward, collapsing covers it bottom-up. No fade, no squash.
struct CurtainReveal: ViewModifier {
    let isExpanded: Bool
    @State private var naturalHeight: CGFloat = 0
    func body(content: Content) -> some View {
        content
            // Keep the content at its natural height even while the frame
            // below clamps to 0, so rows never compress during the reveal.
            .fixedSize(horizontal: false, vertical: true)
            // A nested curtain toggle changes this height as one final model
            // value (see the contentHeight note below), so re-animate with the
            // shared spring or rows below this curtain jump instantly.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                withAnimation(.panelResize) { naturalHeight = newHeight }
            }
            // Numeric endpoints (not nil) so the toggle is always animatable.
            .frame(height: isExpanded ? naturalHeight : 0, alignment: .top)
            .clipped()
            // .clipped() only clips drawing; block clicks and VoiceOver too.
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
    }
}

extension View {
    func curtainReveal(_ isExpanded: Bool) -> some View {
        modifier(CurtainReveal(isExpanded: isExpanded))
    }
}

/// Control Center list-row hover: a rounded highlight inset from the panel
/// edges (the flat full-width wash reads as pre-Tahoe).
struct MenuRowHover: ViewModifier {
    let isHovered: Bool
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, 5)
        )
    }
}

extension View {
    func menuRowHover(_ isHovered: Bool) -> some View {
        modifier(MenuRowHover(isHovered: isHovered))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(label).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            // Content and window move as one: SwiftUI interpolates the layout
            // and the panel window tracks it per frame via onGeometryChange.
            withAnimation(.panelResize) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? "\(label), expanded" : "\(label), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showTools: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showSettings: Bool = false
    @State private var quitHovered = false
    @State private var contentHeight: CGFloat = PanelMetrics.lastContentHeight

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays
            .filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
            .sorted {
                // Builtin panel always first, then physical arrangement, topmost first
                if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
                let a = CGDisplayBounds($0.displayID), b = CGDisplayBounds($1.displayID)
                return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
            }
    }

    /// A thin group divider styled like the native menu bar panel (modeled on the system Wi-Fi/Battery panel)
    private var sectionDivider: some View {
        Divider()
            .opacity(0.25)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Display list: name row + inline brightness slider (modeled on the system displays panel)
                ForEach(visibleDisplays) { display in
                    VStack(spacing: 0) {
                        DisplayRowView(
                            display: display,
                            isExpanded: expandedDisplayIDs.contains(display.displayID),
                            onToggleExpand: {
                                withAnimation(.panelResize) {
                                    if expandedDisplayIDs.contains(display.displayID) {
                                        expandedDisplayIDs.remove(display.displayID)
                                    } else {
                                        expandedDisplayIDs.insert(display.displayID)
                                    }
                                }
                            }
                        )

                        BrightnessSliderView(display: display, compact: true)
                            .padding(.bottom, 4)

                        DisplayDetailView(display: display)
                            .curtainReveal(expandedDisplayIDs.contains(display.displayID))
                    }
                }

                // Combined brightness control (Phase 2)
                if settings.showCombinedBrightness {
                    sectionDivider
                    CombinedBrightnessView(displays: displayManager.displays)
                }

                // Dark Mode / Night Shift / True Tone circular toggle row (modeled on the system displays panel)
                if CoreBrightnessService.shared.darkModeAvailable || CoreBrightnessService.shared.nightShiftAvailable || CoreBrightnessService.shared.trueToneAvailable {
                    sectionDivider
                    ScreenEffectsView()
                }

                // Preset list (Phase 19): located below the effects toggles
                sectionDivider
                PresetListView()

                sectionDivider

                // Tools area (collapsible section, collapsed by default)
                ExpandableRow(
                    icon: "wrench.and.screwdriver.fill",
                    iconColor: .gray,
                    label: "Tools",
                    isExpanded: $showTools
                )

                VStack(alignment: .leading, spacing: 0) {
                    // Virtual Displays tool entry (Phase 10)
                    ExpandableRow(
                        icon: "display.2",
                        iconColor: .blue,
                        label: "Virtual Displays",
                        isExpanded: $showVirtualDisplays
                    )

                    VirtualDisplayView()
                        .padding(.leading, 8)
                        .curtainReveal(showVirtualDisplays)

                    // Arrange Displays (Phase 4): only useful with multiple displays
                    if visibleDisplays.count > 1 {
                        ExpandableRow(
                            icon: "rectangle.3.offgrid",
                            iconColor: .blue,
                            label: "Arrange Displays",
                            isExpanded: $showArrangement
                        )

                        ArrangementView()
                            .padding(.leading, 8)
                            .curtainReveal(showArrangement)
                    }

                    // Auto Brightness: a single toggle row, no nested section
                    AutoBrightnessView()
                }
                .padding(.leading, 8)
                .curtainReveal(showTools)

                // Settings area (Phase 12)
                ExpandableRow(
                    icon: "gearshape.fill",
                    iconColor: .gray,
                    label: "Settings",
                    isExpanded: $showSettings
                )

                SettingsView()
                    .padding(.leading, 8)
                    .curtainReveal(showSettings)

                // Update notice (Phase 12)
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("New version v\(ver) available")
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button("View") { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal, 8)
                }

            }
            .padding(.vertical, 4)
            .frame(width: 360)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                PanelMetrics.lastContentHeight = newHeight
                // onGeometryChange inside a ScrollView reports only the final
                // model height (verified: one callback per toggle, no frames),
                // so the eased motion cannot be measured out of the curtain.
                // Instead, re-animate the ScrollView frame with the same spring
                // the curtain uses: both start this runloop turn, and the root
                // geometry callback (outside the ScrollView) DOES fire per
                // frame for this presentation animation, carrying the eased
                // values to the panel window.
                withAnimation(.panelResize) {
                    contentHeight = newHeight
                }
            }
        }
        // Native menus don't rubber-band unless they actually scroll
        .scrollBounceBehavior(.basedOnSize)
        // Keep content pinned to the top while its size animates; without
        // this the scroll offset transiently re-anchors during expansion and
        // the whole panel content shifts up for a moment.
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .initialOffset)
        // macOS 26 Tahoe: MenuBarExtra(.window) gives ScrollView an ideal height of 0;
        // without an explicit height it collapses into an empty pill. Measure the actual content height so the popover fits its content, capping at 600 before scrolling;
        // if measurement fails (reports 0), fall back to a fixed 520
        .frame(height: contentHeight > 0 ? min(contentHeight, PanelMetrics.maxContentHeight) : 520)

        Divider().opacity(0.25).padding(.horizontal, 12)

        // Quit only (fixed at the bottom, does not scroll with content);
        // the version string lives in Settings, like native panels.
        HStack {
            Spacer()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("Quit")
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { quitHovered = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)

        } // end VStack
        .frame(width: 360)
        .padding(.vertical, 8)
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
        .task {
            // Mirror changes made elsewhere (Control Center, brightness keys,
            // other apps) while the panel is visible. The view persists across
            // opens, so poll forever but only touch hardware when shown.
            while !Task.isCancelled {
                pollExternalState()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onAppear {
            PanelOpenGuard.openedAt = Date()
        }
    }

    private func pollExternalState() {
        // The panel is never ordered out (hidden = alpha 0), so isVisible
        // alone is always true; alpha is the actual shown state.
        let panelVisible = NSApp.windows.contains {
            $0 is MenuPanel && $0.isVisible && $0.alphaValue > 0
        }
        guard panelVisible else { return }
        // Don't fight the user's own adjustments (or busy the DDC bus mid-drag).
        if let last = BrightnessService.shared.lastManualAdjustDate,
           Date().timeIntervalSince(last) < 3 { return }
        CoreBrightnessService.shared.refresh()
        for display in visibleDisplays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
        }
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var presetService = PresetService.shared
    @EnvironmentObject var displayManager: DisplayManager

    private var builtinPresets: [DisplayPreset] {
        presetService.presets.filter { $0.isBuiltin }
    }

    private var externalDisplays: [DisplayInfo] {
        displayManager.displays.filter { !$0.isBuiltin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Launch at login
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    if newValue {
                        LaunchService.shared.enable()
                    } else {
                        LaunchService.shared.disable()
                    }
                    settings.launchAtLogin = newValue
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text("Launch at Login")
                        .font(.body)
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)


            // Show combined brightness
            Toggle(isOn: $settings.showCombinedBrightness) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.min.fill", color: .yellow)
                        .accessibilityHidden(true)
                    Text("Show Combined Brightness")
                        .font(.body)
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)

            // Check for updates at launch
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text("Check for Updates at Launch")
                        .font(.body)
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)

            // HiDPI / Scaling (moved here from the top-level segmented control and per-display panel)
            if !builtinPresets.isEmpty || !externalDisplays.isEmpty {
                Divider().opacity(0.25).padding(.horizontal, 12).padding(.vertical, 2)

                Text("HiDPI & Scaling")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)

                if !builtinPresets.isEmpty {
                    PresetSegmentedControl(
                        presets: builtinPresets,
                        matchID: presetService.currentPresetMatch(),
                        applyingID: presetService.applyingPresetID,
                        isApplying: presetService.isApplying
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                ForEach(externalDisplays) { display in
                    HiDPIRowView(display: display)
                }
            }

            Divider().opacity(0.25).padding(.horizontal, 12).padding(.vertical, 2)

            Text("Crisp v\(UpdateService.shared.currentVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var isHovered: Bool = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        // Native Display panel style: bold name, gray subtitle, trailing chevron.
        // No icon chip, no leading chevron, no badge (matches the system panel).
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(display.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let mode = display.currentDisplayMode {
                    Text(mode.resolutionString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            onToggleExpand()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .menuRowHover(isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in System Settings", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Copy Display Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Click to expand the control panel")
        .accessibilityAddTraits(.isButton)
    }
}
