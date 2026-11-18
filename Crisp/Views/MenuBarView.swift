import SwiftUI
import ApplicationServices

// MARK: - Shared Icon Helper

/// A colored circular SF Symbol icon chip, macOS 26 Control Center style.
/// `active` follows the native menu-bar rule: the colored chip is spent on
/// state (connected, on, selected); inactive rows render a bare monochrome glyph.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue
    var active: Bool = true
    /// Optical size compensation: sparse glyphs read smaller than dense ones at the
    /// same point size. Leave at 13 unless a call site needs the nudge.
    var glyphSize: CGFloat = 13

    /// Colored chips keep the filled glyph; the gray inactive chip takes the outline
    /// twin (falling back to the filled name if no outline variant exists).
    private var glyph: String {
        guard !active else { return systemName }
        let outline = systemName.replacingOccurrences(of: ".fill", with: "")
        return NSImage(systemSymbolName: outline, accessibilityDescription: nil) != nil ? outline : systemName
    }

    var body: some View {
        // One view, not two branches, so active<->inactive cross-fades the glyph
        // and fill instead of hard-swapping.
        Image(systemName: glyph)
            .font(.system(size: glyphSize, weight: .regular))
            // Full label strength, not .secondary: color, not glyph dimness, marks inactive.
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
    /// While true, the panel ignores resign-key and outside-click dismissal. Set around
    /// a system-modal prompt we raise ourselves (e.g. the HiDPI-override admin dialog).
    static var suppressAutoDismiss = false {
        didSet { if suppressAutoDismiss { suppressGeneration &+= 1 } }
    }
    /// Bumped on every suppression window so a delayed reset from an older one can't
    /// clear a newer one still in flight.
    static var suppressGeneration = 0
    /// Ignore bare resign-key dismissals until this instant: WindowServer keeps stealing
    /// key focus briefly after some settle operations. Real outside clicks still dismiss.
    static var resignKeyGraceUntil = Date.distantPast
    /// True while a SwiftUI `Menu` (e.g. a row's ⋯) is tracking: it renders outside the
    /// panel frame, so a click on it would otherwise read as an outside-click.
    static var isMenuTracking = false
    /// True while an in-panel confirmation alert is presented, so an outside-click or
    /// resign-key can't tear the panel down mid-decision.
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

    /// Posted each time the panel opens, so content mirroring live external state can
    /// re-read it (the view mounts once, so .onAppear can't re-fire on later opens).
    static let crispPanelDidOpen = Notification.Name("crisp.panelDidOpen")

    /// Stops an in-flight shortcut recording elsewhere: posted by the preset form before
    /// it commits/closes, and by a recorder row starting its own recording. A recorder's
    /// onDisappear alone is too late, firing only after the close animation.
    static let crispStopShortcutRecording = Notification.Name("crisp.stopShortcutRecording")
}

extension Animation {
    /// Duration shared by the SwiftUI curtains nested inside blocks and the
    /// panel window's FrameSpring (PanelCanvas); change both by changing this.
    static let panelResizeDuration: Double = 0.16
    /// The one curve every panel size change shares (rows, footer, window, icon fades):
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
            // A nested curtain toggle changes this height in one step, so
            // re-animate with the shared spring, or rows below this curtain jump instantly.
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
    /// Keep scroll content pinned to the top during expansion, or the offset transiently
    /// re-anchors and the panel content shifts up for a moment. Role-scoped anchors are
    /// macOS 15+; the all-roles anchor on 14 is close enough.
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

/// The one canonical section separator, used across the whole panel so the
/// divider rhythm is consistent everywhere.
struct SectionDivider: View {
    var body: some View {
        Divider()
            .opacity(0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
    }
}

// MARK: - SectionHeader

/// Secondary text that clears WCAG AA on the light popover background: system
/// .secondary falls short there. Dark mode keeps the system color.
/// Measured: see docs/ui-notes.md (Color.secondaryReadable)
extension Color {
    static let secondaryReadable = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.40, alpha: 1.0)
    })
}

extension Color {
    /// Group headers are dimmer than the values at the right of a row, as in the Battery
    /// menu: measured there in dark mode, the header is about 40% white where the
    /// secondary label is 55%. Light mode keeps secondaryReadable (not measured).
    static let groupHeader = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.40)
            : NSColor(white: 0.40, alpha: 1.0)
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
            .foregroundStyle(Color.groupHeader)
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
/// menu row so it's as findable as the update row. Never a popup or launch-time nag.
struct SupportRow: View {
    // Owned by the parent (SettingsView) so its panel-close handler can collapse it,
    // like every other submenu.
    @Binding var expanded: Bool

    private let kofi = "https://ko-fi.com/didriksg"
    private let afdian = "https://ifdian.net/a/didriksg"
    private let github = "https://github.com/sponsors/didriksg"

    /// Payment region can't be detected reliably in a sideloaded app, so the submenu
    /// lists every link and this only orders them: mainland China needs Afdian's
    /// WeChat/Alipay over the Stripe-based Ko-fi/GitHub checkouts.
    private var prefersChinese: Bool {
        Locale.current.region?.identifier == "CN"
            || Bundle.main.preferredLocalizations.first?.hasPrefix("zh-Hans") == true
    }

    /// Drop the "(Afdian)" romanization when the UI itself is Chinese (keyed on UI
    /// language, not region).
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

            // Always laid out so the curtain glides the links open with the panel spring
            // instead of popping to full height.
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

/// The last Settings row: opens the Advanced Settings window, which holds what Crisp
/// works without (docs/DESIGN.md). An action, not a disclosure, so no chevron.
private struct AdvancedSettingsRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: "slider.horizontal.3", active: false)
                .accessibilityHidden(true)
            Text("Advanced Settings…")
                .font(.body)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    // SettingsView stays mounted across panel opens, so expansion state must be reset
    // explicitly on close like every other section.
    @State private var showSupport = false
    // AXIsProcessTrusted() isn't observable, so re-read it on every open (below) or the
    // section shows stale state after the user grants/revokes in System Settings. (vx44)
    @State private var isTrusted = AXIsProcessTrusted()
    @EnvironmentObject var displayManager: DisplayManager
    /// Closes the panel and opens the Advanced Settings window (AppDelegate).
    let openAdvancedSettings: () -> Void

    private var physicalDisplays: [DisplayInfo] {
        displayManager.displays.filter {
            !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }
    }

    /// Opt-in control for brightness-key redirection, shown only while Accessibility is
    /// missing: the in-context trigger for the native trust prompt (nothing is requested
    /// at launch). On grant the parent hides it. (b00d.1, jv1b)
    private struct BrightnessKeysPermissionNotice: View {
        // ponytail: local intent so the switch animates on tap; harmless if denied.
        @State private var requesting = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { requesting },
                    set: { on in
                        requesting = on
                        if on {
                            BrightnessKeyService.requestAccess()
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
                // Returning from System Settings without granting: un-stick the toggle.
                if !AXIsProcessTrusted() { requesting = false }
            }
        }
    }

    var body: some View {
        // spacing 0: each row carries its own .vertical padding. Dividers/headers pad themselves.
        VStack(alignment: .leading, spacing: 0) {
            // Behavior preference, not a display feature, so it sits outside the Tools
            // group and stays shown with no external connected (can be armed before docking).
            AutoBrightnessView()

            // Hidden unless more than one brightness slider exists, or "combined" would
            // just duplicate the single slider.
            if physicalDisplays.count > 1 {
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

            // Shown while an external is connected. Hiding the sliders does not disable
            // the volume keys.
            if displayManager.displays.contains(where: { !$0.isBuiltin }) {
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

            // Asks for Accessibility while it is missing: without it the brightness keys only
            // reach the built-in, so the ask stays where everyone sees it. Which displays the
            // keys adjust, once granted, is set in Advanced Settings > Keyboard.
            if !isTrusted {
                BrightnessKeysPermissionNotice()
            }

            AdvancedSettingsRow(action: openAdvancedSettings)

            SectionDivider()

            Text("Crisp v\(UpdateService.shared.currentVersion)")
                .font(.caption)
                .foregroundColor(.secondaryReadable)
                .padding(.horizontal, 12)

            // Tucked next to the version stamp where "about" info lives; no popup, no
            // launch nag, every feature stays free.
            SupportRow(expanded: $showSupport)
        }
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            isTrusted = AXIsProcessTrusted()  // vx44, see isTrusted's declaration above
            // Re-arm whenever trust is effective, not only at launch: after an upgrade the
            // launch-time check can read false while macOS re-validates the bundle. start() is idempotent.
            if isTrusted { BrightnessKeyService.shared.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Also refresh on reactivate, so the notice goes away after a grant without
            // closing and reopening the panel.
            isTrusted = AXIsProcessTrusted()
            if isTrusted { BrightnessKeyService.shared.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            showSupport = false
        }
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var toggleService = PhysicalDisplayToggleService.shared
    @ObservedObject private var errors = ConnectionErrors.shared
    @State private var isHovered: Bool = false
    @State private var busy = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    /// Same rule as the Disconnect row: never offered for the last viewable screen.
    private var showsSwitch: Bool {
        settings.showConnectionSwitches && toggleService.isSupported
            && !toggleService.wouldLeaveNoActiveDisplay(display.displayID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if let msg = errors.messages[display.displayUUID] {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
        }
    }

    private var row: some View {
        // Native Display panel style: bold name, gray subtitle, chevron, no icon chip.
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
            if showsSwitch {
                // Holds the space; the live switch is the overlay below.
                connectionSwitch.hidden()
            } else {
                // The switch takes the chevron's place at the edge, as in the Wi-Fi menu header.
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        // Keep .contentShape after the padding, so the clickable area matches the full
        // padded row like the hover highlight: before the padding, the highlighted edge does not click.
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
        .accessibilityLabel(Text(verbatim: String(localized: "Display: \(display.name)") + "\(display.isMain ? NSLocalizedString(", main display", comment: "") : "")\(isExpanded ? NSLocalizedString(", expanded", comment: "") : NSLocalizedString(", collapsed", comment: ""))"))
        .accessibilityHint("Click to expand the control panel")
        .accessibilityAddTraits(.isButton)
        // Laid over the row so the row's tap and VoiceOver label do not reach the switch.
        .overlay(alignment: .trailing) {
            if showsSwitch { connectionSwitch.padding(.trailing, 14) }
        }
    }

    private var connectionSwitch: some View {
        Toggle(isOn: Binding(get: { !busy }, set: { if !$0 { disconnect() } })) {
            Text(verbatim: display.name)
        }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.regular)
        .disabled(busy)
    }

    private func disconnect() {
        guard PanelOpenGuard.allowsActivation, !busy else { return }
        busy = true
        errors.clear(display.displayUUID)
        Task { @MainActor in
            let result = await toggleService.disconnect(display)
            displayManager.refreshDisplays()
            if case .failure(let err) = result { errors.show(err.description, for: display.displayUUID) }
            busy = false
        }
    }
}
