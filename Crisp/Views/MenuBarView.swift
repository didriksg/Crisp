import SwiftUI

// MARK: - Shared Icon Helper

/// A colored circular SF Symbol icon chip, macOS 26 Control Center style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
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
    /// While true, the panel ignores its auto-dismiss triggers (resign-key and
    /// outside-click). Set around a system-modal prompt we raise ourselves (the
    /// admin auth dialog for installing a HiDPI override) so clicking/typing in
    /// that dialog doesn't dismiss the panel out from under it.
    static var suppressAutoDismiss = false
    /// True while an AppKit menu (a SwiftUI `Menu`, e.g. a row's ⋯) is tracking.
    /// Those popups render in their own window outside the panel frame, so a click
    /// on a menu item reads as an outside-click; suppress dismissal while tracking.
    static var isMenuTracking = false
    /// True while an in-panel confirmation alert (e.g. delete) is presented, so an
    /// outside-click / resign-key leaves the panel and the pending choice intact
    /// instead of tearing them down mid-decision.
    static var isConfirmationActive = false
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

extension Notification.Name {
    /// Posted once the panel has finished hiding, so the menu content can reset
    /// transient UI (collapse the tool/nav sections) and reopen fresh like a native menu.
    static let crispPanelDidClose = Notification.Name("crisp.panelDidClose")
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

// MARK: - SectionDivider

/// The one canonical section separator, used between every group across the
/// panel (main menu, display detail, settings) so the divider rhythm is
/// consistent everywhere.
struct SectionDivider: View {
    var body: some View {
        Divider()
            .opacity(0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
    }
}

// MARK: - SectionHeader

/// A group label in the native menu-bar idiom (the "Known Networks" /
/// "Energy Mode" captions in the Wi-Fi and Battery menus): a small semibold
/// secondary caption sitting above a group of rows.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(LocalizedStringKey(title))
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 3)
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

    /// Resolve the label key through NSLocalizedString so Text(String) displays
    /// the localized value (Text(_ content: String) does NOT auto-localize,
    /// unlike Text(_ key: LocalizedStringKey)).
    private var localizedLabel: String {
        NSLocalizedString(label, comment: "")
    }

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(localizedLabel).font(.body)
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
        .padding(.vertical, 5)
        // Highlight on hover only. The native Wi-Fi "Other Networks" header
        // stays flat when expanded (just the chevron rotates), so we do too.
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
        .accessibilityLabel(isExpanded ? "\(localizedLabel), expanded" : "\(localizedLabel), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - UpdateRow

/// Update notice styled like every other menu row (icon badge + label + hover),
/// instead of a tinted banner, matching the native panel look.
struct UpdateRow: View {
    let version: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: "arrow.down.to.line", color: .green)
            Text("Update Available").font(.body)
            Spacer()
            Text("v\(version)")
                .font(.caption)
                .foregroundColor(.secondary)
            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel("Update available, version \(version)")
        .accessibilityHint("Click to open the release page")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - SupportRow

/// Optional "buy me a coffee" link at the bottom of Settings, styled as a normal
/// menu row (icon badge + label + hover + trailing ↗) so it's as findable as the
/// update row — the genre standard for free apps. Never a popup or launch-time
/// nag, and every feature stays free.
struct SupportRow: View {
    // Owned by the parent (SettingsView) so its panel-close handler can collapse
    // it; a private @State here would survive the reset and reopen still expanded,
    // unlike every other submenu.
    @Binding var expanded: Bool

    private let kofi = "https://ko-fi.com/didriksg"
    private let afdian = "https://ifdian.net/a/didriksg"

    /// A supporter's payment region can't be detected reliably in a sideloaded
    /// app (no App Store storefront; Locale.current.region is only a formatting
    /// hint mainland users often switch away), so the submenu lists both and lets
    /// them pick. Mainland China can't complete Ko-fi's PayPal/Stripe checkout
    /// (needs Afdian's WeChat/Alipay), so the hint only ORDERS the list, surfacing
    /// the likely option first; neither is ever hidden.
    private var prefersChinese: Bool {
        Locale.current.region?.identifier == "CN"
            || Bundle.main.preferredLocalizations.first?.hasPrefix("zh-Hans") == true
    }

    var body: some View {
        VStack(spacing: 0) {
            ExpandableRow(
                icon: "heart.fill",
                iconColor: .pink,
                label: "Support Crisp",
                isExpanded: $expanded
            )

            VStack(spacing: 0) {
                if expanded {
                    if prefersChinese {
                        SupportLinkRow(title: "爱发电 (Afdian)", url: afdian)
                        SupportLinkRow(title: "Ko-fi", url: kofi)
                    } else {
                        SupportLinkRow(title: "Ko-fi", url: kofi)
                        SupportLinkRow(title: "爱发电 (Afdian)", url: afdian)
                    }
                }
            }
            .padding(.leading, 8)
            .curtainReveal(expanded)
        }
    }
}

/// One external-link row inside the Support submenu: a label with the ↗ affordance
/// that opens the platform's page in the browser. Brand names are verbatim so they
/// are never localized or number-grouped.
private struct SupportLinkRow: View {
    let title: String
    let url: String
    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.body)
            Spacer()
            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let link = URL(string: url) else { return }
            NSWorkspace.shared.open(link)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(Text(verbatim: title))
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
        let active = displayManager.activePanelDisplayID
        return displayManager.displays
            .filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
            .sorted {
                // Screen the panel was opened on first (native panel behavior),
                // then builtin, then physical arrangement, topmost first
                if ($0.displayID == active) != ($1.displayID == active) { return $0.displayID == active }
                if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
                let a = CGDisplayBounds($0.displayID), b = CGDisplayBounds($1.displayID)
                return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
            }
    }

    /// A thin group divider styled like the native menu bar panel (modeled on the system Wi-Fi/Battery panel)
    private var sectionDivider: some View { SectionDivider() }

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
                            .padding(.horizontal, 12)
                            .curtainReveal(expandedDisplayIDs.contains(display.displayID))
                    }
                }

                // Displays the user disconnected (they no longer have their own row above).
                ReconnectDisplaysSection()

                // Combined brightness control (Phase 2)
                if settings.showCombinedBrightness {
                    sectionDivider
                    CombinedBrightnessView(displays: displayManager.displays)
                }

                // Dark Mode / Night Shift / True Tone circular toggle row (modeled on the system displays panel).
                // No divider above it: the native panel runs the effect row straight under the sliders.
                if CoreBrightnessService.shared.darkModeAvailable || CoreBrightnessService.shared.nightShiftAvailable || CoreBrightnessService.shared.trueToneAvailable {
                    ScreenEffectsView()
                }

                // Preset list (Phase 19): located below the effects toggles
                sectionDivider
                SectionHeader(title: "Presets")
                PresetListView()

                sectionDivider

                // Tools area (collapsible section, collapsed by default): the
                // Virtual Displays + Arrange tools live here. Auto Brightness is
                // a behavior preference and lives in Settings instead.
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

                    // Nest one level under the "Virtual Displays" header using the
                    // same +8 step the header itself sits at under Tools, so the
                    // tree indents uniformly (12 → 20 → 28) instead of jumping.
                    VirtualDisplayView()
                        .padding(.leading, 8)
                        .curtainReveal(showVirtualDisplays)

                    // Arrange Displays (Phase 4): shown whenever more than one
                    // display exists to arrange — including an active virtual one
                    // (visibleDisplays excludes virtuals, so count all displays).
                    if displayManager.displays.count > 1 {
                        ExpandableRow(
                            icon: "rectangle.3.offgrid",
                            iconColor: .blue,
                            label: "Arrange Displays",
                            isExpanded: $showArrangement
                        )

                        ArrangementView()
                            .curtainReveal(showArrangement)
                    }
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
                    UpdateRow(version: ver) { updateService.openReleasePage() }
                }

            }
            .padding(.vertical, 4)
            .frame(width: 308)
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

        // Quit: a capsule-shaped button with a power icon, left-aligned.
        // Tinted red on hover to signal a destructive/exit action.
        HStack {
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quit Crisp")
                        .font(.body)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(quitHovered ? Color.red.opacity(0.15) : Color.primary.opacity(0.06))
                )
                .foregroundColor(quitHovered ? .red : .primary)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { quitHovered = $0 }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.leading, 12)

        } // end VStack
        .frame(width: 308)
        .padding(.vertical, 8)
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // Reopen collapsed, like a native menu. Fires while the panel is hidden,
            // so the content resizes off screen and reopens at the collapsed height.
            showTools = false
            showVirtualDisplays = false
            showArrangement = false
            showSettings = false
            expandedDisplayIDs.removeAll()
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
            // animated: glide the built-in slider to sensor-driven changes instead
            // of snapping every poll (external displays ignore the flag).
            Task { await BrightnessService.shared.refreshBrightness(for: display, animated: true) }
        }
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var presetService = PresetService.shared
    // SettingsView stays mounted (only height-clipped) across panel opens, so the
    // support submenu's expansion must be reset explicitly on close like every
    // other section, or it reopens still expanded.
    @State private var showSupport = false
    @EnvironmentObject var displayManager: DisplayManager

    private var builtinPresets: [DisplayPreset] {
        presetService.presets.filter { $0.isBuiltin }
    }

    private var externalDisplays: [DisplayInfo] {
        displayManager.displays.filter { !$0.isBuiltin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Auto Brightness: a behavior preference (moved out of the Tools
            // group, which is display features only).
            AutoBrightnessView()

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
                SectionDivider()

                SectionHeader(title: "HiDPI & Scaling")

                // One switch for the whole HiDPI story: flips the Native/HiDPI
                // presets, and the first enable also installs the per-monitor
                // override (admin prompt) when it's missing.
                if !externalDisplays.isEmpty {
                    HiDPIToggleRow(
                        displays: externalDisplays,
                        nativePreset: builtinPresets.first(where: { $0.name == "Native Mode" }),
                        hidpiPreset: builtinPresets.first(where: { $0.name == "HiDPI Mode" })
                    )
                }
            }

            SectionDivider()

            Text("Crisp v\(UpdateService.shared.currentVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            // Optional support link, tucked next to the version stamp where
            // "about" info lives. Muted, but with a link affordance so it doesn't
            // read as static text — no popup, no launch nag; every feature stays free.
            SupportRow(expanded: $showSupport)
        }
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            showSupport = false
        }
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
