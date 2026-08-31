import SwiftUI

/// Toggle that hides the notch by switching the built-in panel to the 16:10
/// letterboxed twin of the current mode, the way the hidden 16:10 sizes in the
/// stock resolution chooser do it: the menu bar drops below the notch at full
/// width and the notch strip goes dark (issue #63). Shown whenever the panel
/// itself is notched (native aspect taller than 16:10), independent of the
/// current mode and of NSScreen: a builtin mirroring a virtual display has no
/// NSScreen at all, which is why the old safeAreaInsets gate never fired there.
struct NotchView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isSwitching = false
    @State private var isHovered = false

    private var nativeAspect: Double {
        let (w, h) = display.nativeResolution
        return h > 0 ? Double(w) / Double(h) : 0
    }

    private var hasNotch: Bool {
        display.isBuiltin && DisplayModeGeometry.isNotchedPanelAspect(nativeAspect)
    }

    /// Hidden = the current mode is one of the 16:10 letterboxed sizes.
    private var isNotchHidden: Bool {
        guard let mode = display.currentDisplayMode else { return false }
        return !DisplayModeGeometry.matchesNativeAspect(width: mode.width, height: mode.height,
                                                        nativeAspect: nativeAspect)
    }

    var body: some View {
        if hasNotch {
            HStack {
                MenuItemIcon(systemName: isNotchHidden ? "eye.slash" : "eye", color: .teal, active: isNotchHidden)
                Text("Hide Notch Area")
                    .font(.body)
                Spacer()
                Toggle("", isOn: Binding(get: { isNotchHidden }, set: { setNotchHidden($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(isSwitching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
        }
    }

    /// Switches to the current mode's twin in the other aspect family: same
    /// HiDPI, same width (every notched size has a same-width 16:10 twin),
    /// nearest width as fallback for the 16:10-only sizes (1280×800,
    /// 1920×1200), keeping refresh rate and the ProMotion/fixed choice.
    private func setNotchHidden(_ hide: Bool) {
        guard !isSwitching, hide != isNotchHidden,
              let current = display.currentDisplayMode else { return }
        let aspect = nativeAspect
        let target = display.availableModes
            .filter {
                $0.isHiDPI == current.isHiDPI &&
                    DisplayModeGeometry.matchesNativeAspect(width: $0.width, height: $0.height,
                                                            nativeAspect: aspect) != hide
            }
            .min { a, b in
                if abs(a.width - current.width) != abs(b.width - current.width) {
                    return abs(a.width - current.width) < abs(b.width - current.width)
                }
                if abs(a.refreshRate - current.refreshRate) != abs(b.refreshRate - current.refreshRate) {
                    return abs(a.refreshRate - current.refreshRate) < abs(b.refreshRate - current.refreshRate)
                }
                return a.isVariableRefresh == current.isVariableRefresh
                    && b.isVariableRefresh != current.isVariableRefresh
            }
        guard let target, target.id != current.id else { return }
        isSwitching = true
        Task { @MainActor in
            // One retry like DisplayModeController.switchTo: a transient CG
            // config failure right after another reconfig is common.
            var success = await ResolutionService.shared.setDisplayMode(
                target, for: display.displayID,
                expectedDisplayUUID: display.displayUUID)
            if !success {
                try? await Task.sleep(nanoseconds: 200_000_000)
                success = await ResolutionService.shared.setDisplayMode(
                    target, for: display.displayID,
                    expectedDisplayUUID: display.displayUUID)
            }
            if success {
                // Optimistic, like DisplayModeController: the reconfig callback
                // re-reads the authoritative mode moments later.
                display.currentDisplayMode = target
            }
            isSwitching = false
        }
    }
}
