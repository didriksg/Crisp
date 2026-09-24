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
    @Published var profileOpenIDs: Set<CGDirectDisplayID> = []
    @Published var imageOpenIDs: Set<CGDirectDisplayID> = []

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
        profileOpenIDs.removeAll()
        imageOpenIDs.removeAll()
    }

    /// Drop state for displays that disappeared (disconnect, reconfiguration).
    func retainDisplays(_ valid: Set<CGDirectDisplayID>) {
        expandedDisplayIDs.formIntersection(valid)
        resolutionOpenIDs.formIntersection(valid)
        allResolutionsOpenIDs.formIntersection(valid)
        refreshOpenIDs.formIntersection(valid)
        profileOpenIDs.formIntersection(valid)
        imageOpenIDs.formIntersection(valid)
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

/// Keep Awake: hold a power assertion against idle-sleep. Session-only, off
/// each launch.
struct KeepAwakeRow: View {
    @ObservedObject private var keepAwake = KeepAwakeService.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { keepAwake.isActive },
            set: { keepAwake.setActive($0) }
        )) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "cup.and.saucer.fill", color: .orange, active: keepAwake.isActive)
                    .accessibilityHidden(true)
                Text("Keep Awake")
                    .font(.body)
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
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
