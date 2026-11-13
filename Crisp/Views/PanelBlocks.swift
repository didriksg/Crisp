import SwiftUI
import AppKit

// The panel's content, decomposed into split-canvas blocks: each block renders
// once at its natural size, and AppKit animates the clips and window instead
// of SwiftUI. See docs/panel-resize.md for the full architecture.

/// Section open/close state, lifted out of the view tree so both the SwiftUI
/// headers (chevrons, bindings) and the AppKit canvas (clip targets) share it.
@MainActor
final class PanelSectionState: ObservableObject {
    @Published var showTools = false
    @Published var showVirtualDisplays = false
    @Published var showArrangement = false
    @Published var showSettings = false
    @Published var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    // Per-display dropdown sections, lifted out of view @State so each reveal
    // is its own canvas block (docs/panel-resize.md).
    @Published var resolutionOpenIDs: Set<CGDirectDisplayID> = []
    @Published var allResolutionsOpenIDs: Set<CGDirectDisplayID> = []
    @Published var refreshOpenIDs: Set<CGDirectDisplayID> = []
    @Published var rotationOpenIDs: Set<CGDirectDisplayID> = []
    @Published var profileOpenIDs: Set<CGDirectDisplayID> = []
    @Published var imageOpenIDs: Set<CGDirectDisplayID> = []
    @Published var inputOpenIDs: Set<CGDirectDisplayID> = []

    /// Collapse every section so the panel reopens fresh; called once hidden.
    func collapseAll() {
        showTools = false
        showVirtualDisplays = false
        showArrangement = false
        showSettings = false
        expandedDisplayIDs.removeAll()
        resolutionOpenIDs.removeAll()
        allResolutionsOpenIDs.removeAll()
        refreshOpenIDs.removeAll()
        rotationOpenIDs.removeAll()
        profileOpenIDs.removeAll()
        imageOpenIDs.removeAll()
        inputOpenIDs.removeAll()
    }

    /// Drop state for displays that disappeared (disconnect, reconfiguration).
    func retainDisplays(_ valid: Set<CGDirectDisplayID>) {
        expandedDisplayIDs.formIntersection(valid)
        resolutionOpenIDs.formIntersection(valid)
        allResolutionsOpenIDs.formIntersection(valid)
        refreshOpenIDs.formIntersection(valid)
        rotationOpenIDs.formIntersection(valid)
        profileOpenIDs.formIntersection(valid)
        imageOpenIDs.formIntersection(valid)
        inputOpenIDs.formIntersection(valid)
    }

    /// Binding into one of the per-display sets, for ExpandableRow chevrons.
    func openBinding(
        _ keyPath: ReferenceWritableKeyPath<PanelSectionState, Set<CGDirectDisplayID>>,
        _ id: CGDirectDisplayID
    ) -> Binding<Bool> {
        Binding(
            get: { self[keyPath: keyPath].contains(id) },
            set: {
                if $0 { self[keyPath: keyPath].insert(id) } else { self[keyPath: keyPath].remove(id) }
            }
        )
    }
}

/// Wraps a block's content with the fixed panel width, natural-height sizing,
/// and the height reporter feeding the canvas.
struct BlockHost<Content: View>: View {
    let onHeight: (CGFloat) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        // Report natural height; the canvas springs the clip to it.
        content
            .frame(width: 308)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            // Top-glue: pin to .top so NSHostingView doesn't center a nested
            // curtain's shorter mid-reveal content (that drifts the top row).
            // Do not add .fixedSize: it defeats this fill.
            // Measured: see docs/ui-notes.md (PanelBlocks: BlockHost top-glue)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// An ExpandableRow bound to a PanelSectionState flag; observes the state so
/// the chevron re-renders when the flag flips.
struct ExpandableRowStateful: View {
    let icon: String
    var iconColor: Color = .blue
    var iconActive: Bool = true
    let label: String
    @ObservedObject var state: PanelSectionState
    let key: ReferenceWritableKeyPath<PanelSectionState, Bool>

    var body: some View {
        ExpandableRow(
            icon: icon,
            iconColor: iconColor,
            iconActive: iconActive,
            label: label,
            isExpanded: Binding(
                get: { state[keyPath: key] },
                set: { state[keyPath: key] = $0 }
            )
        )
    }
}

/// Display name row + inline brightness slider (the always-visible part of a
/// display section).
struct DisplayHeaderBlock: View {
    @ObservedObject var display: DisplayInfo
    let isFirst: Bool
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(spacing: 0) {
            DisplayRowView(
                display: display,
                isExpanded: state.expandedDisplayIDs.contains(display.displayID),
                onToggleExpand: {
                    withAnimation(.panelResize) {
                        if state.expandedDisplayIDs.contains(display.displayID) {
                            state.expandedDisplayIDs.remove(display.displayID)
                        } else {
                            state.expandedDisplayIDs.insert(display.displayID)
                        }
                    }
                }
            )
            BrightnessSliderView(display: display, compact: true)
                .padding(.bottom, 4)

            // Speaker volume: shown only when DDC volume answered (#23) and
            // the setting is on; height changes flow through BlockHost.
            if settings.showVolumeSliders && display.volumeSupported {
                VolumeSliderView(display: display)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, isFirst ? 0 : 8)
    }
}

/// Tools section header; surfaces Keep Awake status/countdown while collapsed.
struct ToolsHeaderBlock: View {
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var keepAwake = KeepAwakeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider()
            ExpandableRow(
                icon: "wrench.and.screwdriver.fill",
                iconActive: false,
                label: "Tools",
                subtitle: state.showTools ? nil : keepAwake.toolsSubtitle,
                isExpanded: $state.showTools
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            keepAwake.refreshRemaining()
        }
    }
}

/// Keep Awake: hold a power assertion against idle-sleep. Session-only, off
/// each launch.
struct KeepAwakeRow: View {
    @ObservedObject private var keepAwake = KeepAwakeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "cup.and.saucer.fill", color: .orange, active: keepAwake.isActive)
                    .accessibilityHidden(true)
                Text("Keep Awake")
                    .font(.body)
                Spacer()
                if let subtitle = keepAwake.rowSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondaryReadable)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Toggle("", isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { newValue in
                        guard PanelOpenGuard.allowsActivation else { return }
                        withAnimation(.panelResize) { keepAwake.setActive(newValue) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Keep Awake")
                .accessibilityValue(
                    keepAwake.rowSubtitle ?? (keepAwake.isActive ? String(localized: "Always") : String(localized: "Off"))
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            HStack(spacing: 4) {
                ForEach(KeepAwakeDuration.allCases) { item in
                    KeepAwakeDurationPill(
                        item: item,
                        isSelected: keepAwake.duration == item
                    ) {
                        keepAwake.selectDuration(item)
                    }
                }
            }
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.top, 1)
            .padding(.bottom, 4)
            .curtainReveal(keepAwake.isActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            keepAwake.refreshRemaining()
        }
    }
}

private struct KeepAwakeDurationPill: View {
    let item: KeepAwakeDuration
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            guard PanelOpenGuard.allowsActivation else { return }
            action()
        } label: {
            Text(item.pillLabel)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondaryReadable))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.orange : (isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Saved and off by default, unlike Keep Awake; see EdgeCrossingService. Hidden with one
/// display, which has no shared edge.
struct EdgeCrossingRow: View {
    @ObservedObject private var settings = SettingsService.shared
    @EnvironmentObject private var displayManager: DisplayManager

    var body: some View {
        if displayManager.displays.count > 1 {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(isOn: $settings.crossDisplayGaps) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "cursorarrow.motionlines", color: .purple, active: settings.crossDisplayGaps)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cross Unaligned Edges")
                        .font(.body)
                    Text("The pointer jumps to the nearest display where edges don't line up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

/// Saved and off by default. Hidden on a Mac with no built-in panel (battery as the laptop
/// test, since a disconnected built-in is gone from the display list) and on Intel. See
/// PhysicalDisplayToggleService (parked record and the Tools switch).
struct DisconnectBuiltinRow: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        if PhysicalDisplayToggleService.shared.isSupported && PhysicalDisplayToggleService.hasBattery {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(isOn: $settings.disconnectBuiltinWhenDocked) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "laptopcomputer.slash", color: .indigo,
                             active: settings.disconnectBuiltinWhenDocked)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-Disconnect Built-in")
                        .font(.body)
                    Text("Turns the built-in display off while an external display is connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .onChange(of: settings.disconnectBuiltinWhenDocked) { _, isOn in
            if isOn {
                PhysicalDisplayToggleService.shared.reapplyParkedIfDocked()
            } else {
                PhysicalDisplayToggleService.shared.clearParked()
            }
        }
    }
}

/// Update notice; renders nothing until an update is known, so it glides in.
struct UpdateBlockView: View {
    @ObservedObject private var updateService = UpdateService.shared

    var body: some View {
        if updateService.hasUpdate, let ver = updateService.latestVersion {
            UpdateRow(version: ver) { updateService.installUpdate() }
        }
    }
}

/// Fixed footer: divider + Quit, like the Wi-Fi menu's settings footer.
struct PanelFooterBlock: View {
    @State private var quitHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.25).padding(.horizontal, 12)
            HStack {
                Text("Quit Crisp")
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(quitHovered)
            .contentShape(Rectangle())
            .onTapGesture {
                NSApplication.shared.terminate(nil)
            }
            .onHover { quitHovered = $0 }
            .padding(.top, 4)
        }
        .padding(.bottom, 8)
    }
}
