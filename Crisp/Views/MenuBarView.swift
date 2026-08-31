import SwiftUI
import ApplicationServices

// MARK: - Shared Icon Helper

/// A colored circular SF Symbol icon chip, macOS 26 Control Center style.
/// `active` follows the native menu-bar rule (Wi-Fi/Battery): the colored chip
/// is spent on state (connected, on, selected); inactive rows render a bare
/// monochrome glyph in the same footprint so color still means something.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue
    var active: Bool = true
    /// Optical size compensation. Sparse glyphs (a bare `plus`) read smaller than
    /// dense ones (`gearshape.fill`) at the same point size, so a few call sites
    /// nudge theirs up to match the rest of the column. Leave it alone otherwise.
    var glyphSize: CGFloat = 13

    /// Colored chips keep the filled glyph (white on accent, as the native menus do);
    /// the gray inactive chip takes the outline twin so it reads as line art instead of
    /// a solid shape. Not every symbol has one, and Image(systemName:) draws nothing when
    /// the name is missing, so fall back to the filled name.
    private var glyph: String {
        guard !active else { return systemName }
        let outline = systemName.replacingOccurrences(of: ".fill", with: "")
        return NSImage(systemSymbolName: outline, accessibilityDescription: nil) != nil ? outline : systemName
    }

    var body: some View {
        // One view, not two branches, so active<->inactive cross-fades the glyph
        // and fill instead of hard-swapping. Inactive keeps the same chip footprint
        // with a faint gray fill (Wi-Fi non-selected style); active fills with the
        // accent. Color still marks state, the change just animates.
        Image(systemName: glyph)
            .font(.system(size: glyphSize, weight: .regular))
            // Inactive glyph at full label strength (not .secondary) so it stays legible
            // on the faint chip; the lack of color, not a dimmer glyph, marks it inactive.
            .foregroundColor(active ? .white : .primary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(active ? color : Color.primary.opacity(0.10)))
            // Same curve as the panel's section reveal, so a toggle that recolors its
            // icon and glides a section open move together.
            .animation(.panelResize, value: active)
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
    static var suppressAutoDismiss = false {
        didSet { if suppressAutoDismiss { suppressGeneration &+= 1 } }
    }
    /// Bumped on every new suppression window. A DELAYED reset (the admin-auth
    /// helper's 500ms tail) captures this when it suppresses and skips its reset
    /// if another window started since, so it can't clear that newer window
    /// mid-flight (the smooth-scaling soft-reconnect holds one for ~2s).
    static var suppressGeneration = 0
    /// Ignore bare resign-key dismissals until this instant. After a smooth-scaling
    /// soft-reconnect completes (and suppressAutoDismiss releases), WindowServer keeps
    /// stealing key focus for a few seconds while the display settles; a late steal
    /// would close the panel out from under the user. Genuine outside clicks still
    /// dismiss through the global click monitor, which does not consult this.
    static var resignKeyGraceUntil = Date.distantPast
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
    /// Set per-screen on panel open; the scroll viewport caps at this so the
    /// panel only actually scrolls when content exceeds the screen.
    static var maxContentHeight: CGFloat = 600
}

extension Notification.Name {
    /// Posted once the panel has finished hiding, so the menu content can reset
    /// transient UI (collapse the tool/nav sections) and reopen fresh like a native menu.
    static let crispPanelDidClose = Notification.Name("crisp.panelDidClose")

    /// Posted each time the panel opens, so content mirroring live external state
    /// (e.g. the system auto-brightness toggle) can re-read it, the view mounts once,
    /// so its .onAppear can't re-fire on later opens.
    static let crispPanelDidOpen = Notification.Name("crisp.panelDidOpen")

    /// Posted by the preset form before it commits and closes (object nil, stops
    /// every recorder), and by a recorder row starting a recording (object: its
    /// row identity, which the poster itself ignores), so an in-flight recording
    /// elsewhere stops. Hotkey registration resumes once no recorder suspends it
    /// (HotkeyService counts suspensions). The recorder's own onDisappear only
    /// fires after the close animation, hence the notification.
    static let crispStopShortcutRecording = Notification.Name("crisp.stopShortcutRecording")
}

extension Animation {
    /// Duration shared by the SwiftUI curtains nested inside blocks and the
    /// panel window's FrameSpring (PanelCanvas); change both by changing this.
    static let panelResizeDuration: Double = 0.16
    /// The one curve every panel size change shares (rows, footer, window, and
    /// icon state fades): the smooth spring Control Center panels use when a list
    /// expands.
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

extension View {
    /// Keep scroll content pinned to the top on first layout and while its
    /// size animates; without this the scroll offset transiently re-anchors
    /// during expansion and the whole panel content shifts up for a moment.
    /// The role-scoped anchors are macOS 15+; on 14 the all-roles anchor is
    /// close enough (it additionally top-aligns short content, which the
    /// panel fills anyway).
    @ViewBuilder func topAnchoredScroll() -> some View {
        if #available(macOS 15.0, *) {
            self.defaultScrollAnchor(.top, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .initialOffset)
        } else {
            self.defaultScrollAnchor(.top)
        }
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

/// Secondary text that clears WCAG AA on the light popover background. The system
/// .secondary measures ~3.9:1 there (below the 4.5:1 required at caption sizes);
/// dark mode measures ~5.8:1, so keep the system color and darken only light mode.
extension Color {
    static let secondaryReadable = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.40, alpha: 1.0)  // ~5.4:1 on the 245-251 light material
    })
}

/// A group label in the native menu-bar idiom (the "Known Networks" /
/// "Energy Mode" captions in the Wi-Fi and Battery menus): a small semibold
/// secondary caption sitting above a group of rows.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(LocalizedStringKey(title))
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(Color.secondaryReadable)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 3)
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    var iconActive: Bool = true
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
            MenuItemIcon(systemName: icon, color: iconColor, active: iconActive)
            Text(localizedLabel).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondaryReadable)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            action()
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Update available, version \(version)")
        .accessibilityHint("Click to open the release page")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - SupportRow

/// Optional "buy me a coffee" link at the bottom of Settings, styled as a normal
/// menu row (icon badge + label + hover + trailing ↗) so it's as findable as the
/// update row, the genre standard for free apps. Never a popup or launch-time
/// nag, and every feature stays free.
struct SupportRow: View {
    // Owned by the parent (SettingsView) so its panel-close handler can collapse
    // it; a private @State here would survive the reset and reopen still expanded,
    // unlike every other submenu.
    @Binding var expanded: Bool

    private let kofi = "https://ko-fi.com/didriksg"
    private let afdian = "https://ifdian.net/a/didriksg"
    private let github = "https://github.com/sponsors/didriksg"

    /// A supporter's payment region can't be detected reliably in a sideloaded
    /// app (no App Store storefront; Locale.current.region is only a formatting
    /// hint mainland users often switch away), so the submenu lists them all and
    /// lets them pick. Mainland China can't complete the Stripe-based checkouts
    /// (Ko-fi, GitHub Sponsors) and needs Afdian's WeChat/Alipay, so the hint only
    /// ORDERS the list, surfacing the likely option first; none is ever hidden.
    private var prefersChinese: Bool {
        Locale.current.region?.identifier == "CN"
            || Bundle.main.preferredLocalizations.first?.hasPrefix("zh-Hans") == true
    }

    /// Afdian's own brand name is 爱发电; the "(Afdian)" romanization only helps a
    /// non-Chinese reader, so drop it when the UI itself is Chinese (keyed on the UI
    /// language, not region: an English UI in CN still needs the handle).
    private var afdianTitle: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
            ? "爱发电" : "爱发电 (Afdian)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ExpandableRow(
                icon: "heart.fill",
                iconColor: .pink,
                label: "Support Crisp",
                isExpanded: $expanded
            )

            // Always laid out so the curtain glides the links open with the panel
            // spring, instead of popping to full height while the row animates.
            // prefersChinese only orders the rows (static per launch), so branching
            // on it here doesn't affect the reveal.
            VStack(spacing: 0) {
                if prefersChinese {
                    SupportLinkRow(title: afdianTitle, url: afdian)
                    SupportLinkRow(title: "Ko-fi", url: kofi)
                    SupportLinkRow(title: "GitHub Sponsors", url: github)
                } else {
                    SupportLinkRow(title: "Ko-fi", url: kofi)
                    SupportLinkRow(title: "GitHub Sponsors", url: github)
                    SupportLinkRow(title: afdianTitle, url: afdian)
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
        .padding(.vertical, 3)
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

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    // SettingsView stays mounted (only height-clipped) across panel opens, so the
    // support submenu's expansion must be reset explicitly on close like every
    // other section, or it reopens still expanded.
    @State private var showSupport = false
    @State private var showBrightnessKeys = false
    @State private var showHiDPIShortcut = false
    // Accessibility trust drives which Brightness Keys UI shows (toggle vs target menu).
    // AXIsProcessTrusted() isn't observable and the panel content mounts once, so re-read
    // it on every open (below) or the section shows a stale state after the user grants or
    // revokes in System Settings. (vx44)
    @State private var isTrusted = AXIsProcessTrusted()
    @EnvironmentObject var displayManager: DisplayManager

    /// Localized display name for a brightness-key target (row subtitle + choices).
    private func brightnessTargetName(_ target: BrightnessKeyTarget) -> String {
        switch target {
        case .underCursor: return String(localized: "Follow the pointer")
        case .allDisplays: return String(localized: "All connected displays")
        case .selected:    return String(localized: "Selected displays only")
        }
    }

    /// Opt-in control for brightness-key redirection, shown inside the Brightness Keys section
    /// only while Accessibility is missing. The toggle is the deliberate, in-context trigger for
    /// the native trust prompt (nothing is requested at launch); it also opens the exact Settings
    /// pane, and the tap arms live once granted, no restart. On grant the parent swaps this for
    /// the target menu. (b00d.1, jv1b)
    private struct BrightnessKeysPermissionNotice: View {
        // ponytail: local intent so the switch animates on tap. On grant the parent replaces
        // this whole view with the target menu; on deny it stays on until the section next
        // renders, which is harmless since the keys simply aren't armed.
        @State private var requesting = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { requesting },
                    set: { on in
                        requesting = on
                        if on {
                            requestAccess()
                            BrightnessKeyService.shared.start()
                        } else {
                            BrightnessKeyService.shared.stop()
                        }
                    }
                )) {
                    HStack(spacing: 8) {
                        MenuItemIcon(systemName: "keyboard", color: .accentColor, active: requesting)
                            .accessibilityHidden(true)
                        Text("Use brightness keys on external displays")
                            .font(.body)
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                Text("Brightness keys need Accessibility access to redirect them to external displays. Grant it once and they start working, no restart.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Returning from System Settings: if access still isn't granted (declined, or a
                // stale grant from a differently-signed build), un-stick the toggle so it can't
                // sit "on" while the caption still says access is needed and no target menu shows.
                if !AXIsProcessTrusted() { requesting = false }
            }
        }

        private func requestAccess() {
            // Fire the native trust prompt (shows the system dialog the first time)...
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            // ...and open the exact pane, so the toggle still lands somewhere useful after the
            // one-shot prompt has already been dismissed once.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    var body: some View {
        // spacing 0: each row carries its own .vertical padding (like the Tools group),
        // so rows sit ~10px apart instead of 5+6+5. Dividers/headers pad themselves.
        VStack(alignment: .leading, spacing: 0) {
            // Auto Brightness: a behavior preference (moved out of the Tools
            // group, which is display features only). Always shown, even with no
            // external connected: it's a preference, not a dead control, so you
            // can arm it before docking and it activates when a display appears.
            AutoBrightnessView()

            // Show combined brightness. Hidden unless more than one brightness
            // slider exists (one per connected display, virtuals excluded since
            // they get no slider): with a single slider, "combined" would just
            // duplicate it. The preference persists, so it returns on reconnect.
            if displayManager.displays.filter({ !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }).count > 1 {
                Toggle(isOn: Binding(
                    get: { settings.showCombinedBrightness },
                    set: { newValue in withAnimation(.panelResize) { settings.showCombinedBrightness = newValue } }
                )) {
                    HStack(spacing: 8) {
                        MenuItemIcon(systemName: "sun.min.fill", color: .yellow, active: settings.showCombinedBrightness)
                            .accessibilityHidden(true)
                        Text("Show Combined Brightness")
                            .font(.body)
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }

            // Show volume sliders (issue #23). Hidden while no connected monitor
            // exposes DDC volume: the toggle would control nothing. Hiding the
            // sliders does not disable the volume keys.
            if displayManager.displays.contains(where: { $0.volumeSupported }) {
                Toggle(isOn: Binding(
                    get: { settings.showVolumeSliders },
                    set: { newValue in withAnimation(.panelResize) { settings.showVolumeSliders = newValue } }
                )) {
                    HStack(spacing: 8) {
                        MenuItemIcon(systemName: "speaker.wave.2.fill", color: .blue, active: settings.showVolumeSliders)
                            .accessibilityHidden(true)
                        Text("Show Volume Sliders")
                            .font(.body)
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }

            // Which displays the hardware brightness keys adjust. Once Accessibility is granted,
            // an expandable row + checkmark list (the Resolution / Color Profile idiom). Before
            // that there is no row or target subtitle at all, only the opt-in toggle, so enabling
            // is discoverable without expanding and no target reads as live before it is. (jv1b)
            if isTrusted {
                ExpandableRow(
                    icon: "keyboard",
                    iconColor: .accentColor,
                    iconActive: true,
                    label: "Brightness Keys",
                    subtitle: brightnessTargetName(settings.brightnessKeyTarget),
                    isExpanded: $showBrightnessKeys
                )
                if showBrightnessKeys {
                    ForEach(BrightnessKeyTarget.allCases, id: \.self) { target in
                        CheckmarkRow(
                            label: brightnessTargetName(target),
                            isSelected: settings.brightnessKeyTarget == target
                        ) {
                            settings.brightnessKeyTarget = target
                        }
                    }
                    // "Selected displays only": a checklist of the current displays.
                    // Real toggles (not CheckmarkRow, which can't deselect) since this is
                    // multi-select. Membership is keyed by the stable displayUUID so it
                    // survives reconnects; built-in included, since "All" affects it too.
                    if settings.brightnessKeyTarget == .selected {
                        ForEach(displayManager.displays) { display in
                            Toggle(isOn: Binding(
                                get: { settings.brightnessKeySelectedDisplayUUIDs.contains(display.displayUUID) },
                                set: { isOn in
                                    if isOn {
                                        settings.brightnessKeySelectedDisplayUUIDs.insert(display.displayUUID)
                                    } else {
                                        settings.brightnessKeySelectedDisplayUUIDs.remove(display.displayUUID)
                                    }
                                }
                            )) {
                                Text(display.name).font(.callout)
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .padding(.leading, 46)
                            .padding(.trailing, 12)
                            .padding(.vertical, 1)
                        }
                    }
                }
            } else {
                BrightnessKeysPermissionNotice()
            }

            // Global shortcuts: the curated action list (issue #61).
            ShortcutsSection(expanded: $showHiDPIShortcut)

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
                HStack(spacing: 8) {
                    MenuItemIcon(systemName: "power", color: .green, active: settings.launchAtLogin)
                        .accessibilityHidden(true)
                    Text("Launch at Login")
                        .font(.body)
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            SectionDivider()

            Text("Crisp v\(UpdateService.shared.currentVersion)")
                .font(.caption)
                .foregroundColor(.secondaryReadable)
                .padding(.horizontal, 12)

            // Optional support link, tucked next to the version stamp where
            // "about" info lives. Muted, but with a link affordance so it doesn't
            // read as static text, no popup, no launch nag; every feature stays free.
            SupportRow(expanded: $showSupport)
        }
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            // Re-read trust on every open so the section reflects a grant/revoke made in
            // System Settings since the last open (the content mounts once). (vx44)
            isTrusted = AXIsProcessTrusted()
            // Arm the tap whenever trust is effective, not only at launch. After an upgrade the
            // launch-time check reads false while macOS re-validates the replaced bundle, so the
            // tap never arms; the target menu then shows (trust settles true) while the keys are
            // dead, and re-granting can't recover it because the opt-in toggle that would re-arm
            // is hidden once trusted. start() is idempotent. (upgrade zombie)
            if isTrusted { BrightnessKeyService.shared.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Also refresh when the app reactivates (e.g. returning from System Settings after
            // granting), so the section flips from the opt-in toggle to the target menu without
            // needing the panel closed and reopened. (brightness-keys zombie toggle fix)
            isTrusted = AXIsProcessTrusted()
            if isTrusted { BrightnessKeyService.shared.start() }  // re-arm if trust became effective post-launch (upgrade zombie)
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            showSupport = false
            showBrightnessKeys = false
            showHiDPIShortcut = false
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
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        // Tap AFTER the padding so the clickable shape is the full padded row,
        // identical to the hover highlight; before it, the padding was a dead
        // border (clicks on the visibly highlighted edge did nothing).
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            onToggleExpand()
        }
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
        .accessibilityLabel(Text(verbatim: "Display: \(display.name)\(display.isMain ? NSLocalizedString(", main display", comment: "") : "")\(isExpanded ? NSLocalizedString(", expanded", comment: "") : NSLocalizedString(", collapsed", comment: ""))"))
        .accessibilityHint("Click to expand the control panel")
        .accessibilityAddTraits(.isButton)
    }
}
