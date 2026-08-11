import SwiftUI
import AppKit

// The panel's content, decomposed into split-canvas blocks (docs/panel-resize.md).
// Each block renders at its natural size and never animates its own geometry;
// the AppKit canvas animates the clips and the window. Nested reveals INSIDE a
// block (Support, Brightness Keys targets, resolution lists) still use the
// SwiftUI curtain at the same duration; the block reports its height per frame
// and the window spring tracks it.

/// Section open/close state, lifted out of the view tree so both the SwiftUI
/// headers (chevrons, bindings) and the AppKit canvas (clip targets) share it.
@MainActor
final class PanelSectionState: ObservableObject {
    @Published var showTools = false
    @Published var showVirtualDisplays = false
    @Published var showArrangement = false
    @Published var showSettings = false
    @Published var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    // Per-display dropdown sections inside the expanded detail, lifted here
    // (out of view @State) so each reveal is its own canvas block: the clip
    // animates, the content renders once, nothing re-renders per frame.
    @Published var resolutionOpenIDs: Set<CGDirectDisplayID> = []
    @Published var allResolutionsOpenIDs: Set<CGDirectDisplayID> = []
    @Published var refreshOpenIDs: Set<CGDirectDisplayID> = []
    @Published var profileOpenIDs: Set<CGDirectDisplayID> = []
    @Published var imageOpenIDs: Set<CGDirectDisplayID> = []

    /// Reopen collapsed, like a native menu (called once the panel finished hiding).
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
        // Report the content's natural height (its final, fully-laid-out size);
        // the canvas springs the clip to it.
        content
            .frame(width: 308)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            // Top-glue, exactly like 1.3.2's PanelRootView (which has no
            // .fixedSize here): the AppKit host is a canvas at the FINAL block
            // height, but a nested curtain renders the content shorter
            // mid-reveal. Without this, NSHostingView CENTERS the shorter content
            // in the taller canvas, so the whole block (its top row included)
            // drops and floats back up: the "inner menu top drifts" on open.
            // Pinning to .top spills the excess off the bottom (clipped by the
            // block's clip) so the top never moves. A .fixedSize on the measured
            // content defeats this fill, so it is deliberately absent.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// An ExpandableRow bound to a PanelSectionState flag. Observes the state so
/// the chevron re-renders when the flag flips (a plain ad-hoc Binding inside
/// a static block closure would never re-render).
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
/// display section). The 8pt top padding separates stacked display sections;
/// the first sits flush.
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

            // Speaker volume, only for monitors that answered the DDC volume
            // probe (issue #23), and only while the setting is on (keys keep
            // working either way). Toggling the setting re-renders this block;
            // the height change flows through BlockHost to the panel spring.
            if settings.showVolumeSliders && display.volumeSupported {
                VolumeSliderView(display: display)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, isFirst ? 0 : 8)
    }
}

/// Keep Awake: hold a power assertion so the display and system don't
/// idle-sleep. Session-only (KeepAwakeService), off each launch.
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
        .padding(.vertical, 5)
    }
}

/// Update notice; renders nothing (height 0) until an update is known, so the
/// block glides in via the normal height-change path.
struct UpdateBlockView: View {
    @ObservedObject private var updateService = UpdateService.shared

    var body: some View {
        if updateService.hasUpdate, let ver = updateService.latestVersion {
            UpdateRow(version: ver) { updateService.openReleasePage() }
        }
    }
}

/// Fixed footer under the scroll region: divider + Quit, like the Wi-Fi
/// menu's settings footer.
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
            .padding(.vertical, 5)
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
