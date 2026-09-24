import SwiftUI
import AppKit
import Combine

// Resolution and refresh-rate selection as native checkmarked lists, each a
// top-level expandable row like the System Settings display menu: resolution
// is one click away, and refresh rate is its own section, shown only when the
// current resolution offers more than one.
//
// Split into canvas blocks (docs/panel-resize.md). DisplayModeController holds
// the shared mutable state (pending switches, slider position, smooth-scaling
// flags) so the sibling blocks stay in sync.

/// Per-display mode-switching state and data, shared by the resolution /
/// refresh-rate blocks of one display section. Created per display when the
/// block list is (re)built; the block hosts retain it.
@MainActor
final class DisplayModeController: ObservableObject {
    let display: DisplayInfo
    private let displayManager: DisplayManager
    @Published var pendingResolutionID: String?
    @Published var pendingRefreshID: Int32?
    @Published var errorMessage: String?
    /// Set when a smooth-scaling toggle's soft-reconnect couldn't happen, so the write landed
    /// but needs a real reconnect to be read. Unlike errorMessage this does not auto-clear.
    @Published var reconnectHint: String?
    @Published var sliderIndex: Double = 0
    @Published var smoothBusy: Bool = false
    @Published var smoothOn: Bool = false
    @Published var smoothWouldPrompt: Bool = true
    private var isSwitching: Bool = false
    private var cachedGroups: [ResolutionGroup]?
    private var cachedSliderModes: [DisplayMode]?
    /// Panel's adaptive-sync floor (48 on a 48-180Hz panel), for the Variable row label.
    private lazy var vrrMinimumRate: Int? = VariableRefreshRange.minimumRate(
        vendorNumber: display.vendorNumber, modelNumber: display.modelNumber)
    private var displayRelay: AnyCancellable?

    init(display: DisplayInfo, displayManager: DisplayManager) {
        self.display = display
        self.displayManager = displayManager
        // Relay only mode/availableModes changes rather than the whole DisplayInfo, or
        // brightness click-glide re-renders every block. dropFirst(2) skips the initial
        // replay both @Published publishers emit on subscribe.
        // Measured: see docs/ui-notes.md (DisplayModeController: mode relay)
        displayRelay = display.$currentDisplayMode.map { _ in }
            .merge(with: display.$availableModes.map { _ in })
            .dropFirst(2)
            .sink { [weak self] _ in
                self?.cachedGroups = nil
                self?.cachedSliderModes = nil
                self?.objectWillChange.send()
            }
    }

    var currentMode: DisplayMode? { display.currentDisplayMode }

    /// Group modes by (resolution + HiDPI), sorted by resolution descending.
    /// Cached; several block views read this per render. The relay above invalidates it.
    fileprivate var resolutionGroups: [ResolutionGroup] {
        if let cachedGroups { return cachedGroups }
        let computed = computeResolutionGroups()
        cachedGroups = computed
        return computed
    }

    private func computeResolutionGroups() -> [ResolutionGroup] {
        let (nativeW, nativeH) = display.nativeResolution

        let base = display.availableModes.filter {
            DisplayModeGeometry.isResolutionMenuEligible(width: $0.width, height: $0.height)
                && DisplayModeGeometry.hasSameOrientation(
                    width: $0.width, height: $0.height, as: nativeW, nativeH
                )
        }

        var grouped: [String: [DisplayMode]] = [:]
        for mode in base {
            let key = "\(mode.width)x\(mode.height)_\(mode.isHiDPI)"
            grouped[key, default: []].append(mode)
        }

        // "(low resolution)" tags a non-HiDPI mode only when a same-size HiDPI mode also
        // exists. "(Default)" tags the native mode, external displays only: the built-in's
        // native mode is a 1x physical size macOS does not treat as the default.
        let hiDPISizes = Set(base.filter { $0.isHiDPI }.map { "\($0.width)x\($0.height)" })
        // Stock HiDPI sizes carry a non-HiDPI twin; the injected smooth-scaling ladder does
        // not, so a twinless HiDPI size is one of the injected in-between steps.
        let lodpiSizes = Set(base.filter { !$0.isHiDPI }.map { "\($0.width)x\($0.height)" })

        let mapped = grouped.map { (_, modes) -> ResolutionGroup in
            let sorted = modes.sorted {
                if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
                // Variable above its same-rate fixed twin, matching System Settings.
                return $0.isVariableRefresh && !$1.isVariableRefresh
            }
            // One Variable row per size, like System Settings: only the top VRR twin is
            // a meaningful choice, the rest would render as duplicate Hz rows.
            let maxVariableRate = sorted.lazy.filter { $0.isVariableRefresh }.map { $0.refreshRate }.max()
            let visible = sorted.filter {
                !$0.isVariableRefresh || $0.refreshRate == maxVariableRate
                    || $0.id == currentMode?.id
            }
            let w = visible[0].width, h = visible[0].height, hidpi = visible[0].isHiDPI
            let isDefault = !display.isBuiltin && !hidpi && w == nativeW && h == nativeH
            let isLowResolution = !hidpi && !isDefault && hiDPISizes.contains("\(w)x\(h)")
            return ResolutionGroup(
                width: w,
                height: h,
                isHiDPI: hidpi,
                isDefault: isDefault,
                isLowResolution: isLowResolution,
                modes: visible
            )
        }

        // ponytail: count > 8 is the "smooth scaling is on" signal (it injects ~80 twinless).
        let denseLadderActive = mapped.filter {
            $0.isHiDPI && !lodpiSizes.contains("\($0.width)x\($0.height)")
        }.count > 8
        // The crisp non-HiDPI Default beats its same-size HiDPI twin (softer, no size
        // benefit), so hide that twin when the Default is present.
        let hasNativeDefault = mapped.contains { $0.isDefault }
        // Native-aspect 1x sizes beyond the widest HiDPI size are the only route to the
        // in-between sizes past the ladder's cap; sizes under it are clutter.
        let maxEligibleHiDPIWidth = base.lazy.filter { $0.isHiDPI }.map(\.width).max() ?? 0

        return mapped.filter { group in
            // Built-in: keep only the panel's native aspect (CGDisplayCopyAllDisplayModes
            // also returns letterboxed 16:10 "non-notch" modes System Settings doesn't
            // offer); always keep the active mode.
            // ponytail: 2% tolerance cleanly splits 1.60 (16:10) from ~1.54 (notched).
            if display.isBuiltin {
                let nativeAR = Double(nativeW) / Double(nativeH)
                let ar = Double(group.width) / Double(group.height)
                return abs(ar - nativeAR) / nativeAR < 0.02
                    || group.modes.contains { $0.id == currentMode?.id }
            }
            // External: the HiDPI twin of native is redundant with the crisp Default.
            if hasNativeDefault, group.isHiDPI, group.width == nativeW, group.height == nativeH,
               !group.modes.contains(where: { $0.id == currentMode?.id }) {
                return false
            }
            // External, dense ladder live: keep only sizes with a low-res twin in the list;
            // the injected in-between steps stay off the list but remain on the slider.
            if denseLadderActive, group.isHiDPI, !group.isDefault,
               !lodpiSizes.contains("\(group.width)x\(group.height)"),
               !group.modes.contains(where: { $0.id == currentMode?.id }) {
                return false
            }
            // External: drop standalone 1x oddballs and off-aspect compat sizes that
            // clutter the list. Keep native, the HiDPI ladder, low-res twins, and current.
            if group.isHiDPI || group.isDefault || group.isLowResolution { return true }
            // Non-retina scaled sizes past the HiDPI ladder's cap (#65): WindowServer
            // refuses scaled backings above a per-display limit, so these exist only as 1x
            // modes and are what System Settings offers there.
            // Measured: see docs/ui-notes.md (DisplayModeListView: beyond-cap resolutions)
            if group.width > maxEligibleHiDPIWidth,
               DisplayModeGeometry.matchesNativeAspect(
                   width: group.width, height: group.height,
                   nativeAspect: Double(nativeW) / Double(nativeH)) {
                return true
            }
            return group.modes.contains { $0.id == currentMode?.id }
        }
        .sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return false
        }
    }

    fileprivate var currentGroup: ResolutionGroup? {
        resolutionGroups.first { $0.modes.contains { $0.id == currentMode?.id } }
    }

    /// Refresh-rate label, matching System Settings: the built-in's 120Hz variable-refresh
    /// mode reads "ProMotion" rather than a fixed number, an external VRR twin reads
    /// "Variable (up to NHz)", and everything else is its Hz string.
    func refreshLabel(_ mode: DisplayMode) -> String {
        if display.isBuiltin && Int(mode.refreshRate.rounded()) >= 120 { return "ProMotion" }
        if mode.isVariableRefresh {
            // Full range like System Settings ("Variable (48-180Hz)") when the registry
            // exposes the adaptive-sync floor; "up to" wording otherwise.
            if let minRate = vrrMinimumRate {
                return String(format: NSLocalizedString("Variable (%@-%@)", comment: "External VRR refresh-rate row, full range"),
                              String(minRate), mode.refreshRateString)
            }
            return String(format: NSLocalizedString("Variable (up to %@)", comment: "External VRR refresh-rate row"),
                          mode.refreshRateString)
        }
        return mode.refreshRateString
    }

    // MARK: - Actions

    fileprivate func selectResolution(_ group: ResolutionGroup) {
        guard group.id != currentGroup?.id, pendingResolutionID == nil else { return }
        // Keep the current refresh rate when the new resolution offers it. Tolerant match:
        // CG reports fractional rates (59.94) where the CGS-surfaced modes carry whole Hz.
        let target = currentMode.flatMap { cur in
            group.modes.first { ResolutionService.refreshMatches($0.refreshRate, cur.refreshRate) }
        } ?? group.bestMode
        pendingResolutionID = group.id
        switchTo(target) { self.pendingResolutionID = nil }
    }

    func selectRefresh(_ mode: DisplayMode) {
        guard mode.id != currentMode?.id, pendingRefreshID == nil else { return }
        pendingRefreshID = mode.id
        switchTo(mode) { self.pendingRefreshID = nil }
    }

    private func switchTo(_ mode: DisplayMode, done: @escaping () -> Void) {
        // Serialize across all three entry points (resolution row, refresh row, slider):
        // the per-row pending flags only guard their own path, and two concurrent
        // display-config transactions on one display race in WindowServer.
        guard !isSwitching else { done(); return }
        isSwitching = true
        let displayID = display.displayID
        Task { @MainActor in
            var success: Bool
            if mode.id < 0 {
                // Synthetic beyond-cap stop (#65, negative id): no CG mode exists
                // on the physical display; MirroredModeService renders the size on
                // a hidden virtual display the panel hardware-mirrors.
                success = await MirroredModeService.shared.apply(
                    display: display, width: mode.width, height: mode.height)
            } else {
                // Leaving a mirrored stop: unmirror first, or the mode change redirects to
                // the virtual source. A failed unmirror leaves the mirror up, so report
                // failure instead of pushing a mode change at a display still mirrored.
                var unmirrored = true
                if MirroredModeService.shared.isActive(for: displayID) {
                    unmirrored = await MirroredModeService.shared.restore(display: display)
                }
                if unmirrored {
                    success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
                    if !success {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
                    }
                } else {
                    success = false
                }
            }
            if success {
                // Optimistic: the reconfiguration callback re-reads the authoritative mode
                // moments later; this only moves the checkmark instantly.
                display.currentDisplayMode = mode
                errorMessage = nil
            } else {
                withAnimation {
                    errorMessage = String(localized: "Unable to switch to \(mode.resolutionString), please try again")
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { self.errorMessage = nil }
                }
            }
            done()
            isSwitching = false
        }
    }

    // MARK: - Smooth scaling

    /// The ladder the Resolution slider steps through: builtinLooksLikeModes on the
    /// built-in, smoothModes on externals. Cached; the relay invalidates it.
    var sliderModes: [DisplayMode] {
        if let cachedSliderModes { return cachedSliderModes }
        let computed = display.isBuiltin ? builtinLooksLikeModes : smoothModes
        cachedSliderModes = computed
        return computed
    }

    /// Built-in "looks like" stops: native-aspect HiDPI modes, one per size, ascending
    /// (left = Larger Text). Same 2% aspect test as resolutionGroups.
    private var builtinLooksLikeModes: [DisplayMode] {
        let (nativeW, nativeH) = display.nativeResolution
        let nativeAR = Double(nativeW) / Double(nativeH)
        var seen = Set<String>()
        return display.availableModes
            .filter { $0.isHiDPI && abs(Double($0.width) / Double($0.height) - nativeAR) / nativeAR < 0.02 }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert("\($0.width)x\($0.height)").inserted }
            .sorted { $0.width < $1.width }
    }

    /// The "looks like" ladder for the slider: every HiDPI logical size, plus native
    /// (non-HiDPI) as the top "More Space" stop, since the HiDPI ladder can't reach it.
    /// One representative per logical size, ascending: left = Larger Text, right = More Space.
    private var smoothModes: [DisplayMode] {
        let (nativeW, nativeH) = display.nativeResolution
        // Floor at 50% of native (the 2x Retina point), matching the injected ladder and
        // BetterDisplay, so small accessibility HiDPI modes don't drag the left stop down.
        let minWidth = nativeW / 2
        // Prefer the crisp non-HiDPI native over its softer same-size HiDPI twin for the
        // "More Space" end.
        let hasNativeDefault = display.availableModes.contains { !$0.isHiDPI && $0.width == nativeW && $0.height == nativeH }
        var seen = Set<String>()
        var ladder = display.availableModes
            .filter {
                guard DisplayModeGeometry.hasSameOrientation(
                    width: $0.width, height: $0.height, as: nativeW, nativeH
                ) else { return false }
                // Native aspect only (2% tolerance, as builtinLooksLikeModes).
                let nativeAR = Double(nativeW) / Double(nativeH)
                guard abs(Double($0.width) / Double($0.height) - nativeAR) / nativeAR < 0.02
                else { return false }
                if hasNativeDefault, $0.isHiDPI, $0.width == nativeW, $0.height == nativeH { return false }
                return ($0.isHiDPI && $0.width >= minWidth) || ($0.width == nativeW && $0.height == nativeH)
            }
            .sorted {
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }
            .filter { seen.insert("\($0.width)x\($0.height)").inserted }
        // Beyond-cap synthetic stops (#65): mint slider stops with NEGATIVE ids for sizes
        // WindowServer's per-display cap has no real HiDPI mode for; switchTo routes those
        // to MirroredModeService instead of the CG apply path.
        // Measured: see docs/ui-notes.md (DisplayModeListView: beyond-cap synthetic stops)
        if smoothModesPresent {
            ladder += MirroredModeService.beyondCapStops(for: display)
                .map { DisplayMode(id: -Int32($0.width), width: $0.width, height: $0.height,
                                   pixelWidth: $0.width * 2, pixelHeight: $0.height * 2,
                                   refreshRate: 0, isHiDPI: true, isNative: false) }
        }
        return ladder.sorted { $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width }
    }

    /// Subtitle for the row while off: what smooth scaling does, plus the admin/flash
    /// heads-up if enabling would prompt. On, the switch says it all.
    var smoothSubtitle: String? {
        // Ground truth, not the optimistic switch value, so the row height and icon
        // don't jump mid-prompt.
        guard !smoothModesPresent else { return nil }
        guard HiDPIService.smoothScalingSupported else {
            return String(localized: "Not available on this Mac. Its chip can't draw scaled sizes larger than the display")
        }
        return smoothWouldPrompt
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            ? String(localized: "Adds finer in-between steps for how large everything looks. Enabling asks for an administrator password and briefly flashes the screen")
            : String(localized: "Adds finer in-between steps for how large everything looks")
    }

    /// Whether the dense smooth-scaling ladder is actually enumerated: the real "is it on"
    /// signal, independent of any stored flag. When true the enable row is hidden.
    /// Measured: see docs/ui-notes.md (DisplayModeListView: smoothModesPresent threshold)
    var smoothModesPresent: Bool {
        let (w, h) = display.panelNativeResolution
        let injected = HiDPIService.shared.smoothScaledLogicalSizes(nativeWidth: w, nativeHeight: h)
            .filter { $0.width < w }  // native is a real mode, always present; ignore it
        guard !injected.isEmpty else { return false }
        let hidpi = Set(display.availableModes.lazy.filter { $0.isHiDPI }.map { "\($0.width)x\($0.height)" })
        let lodpi = Set(display.availableModes.lazy.filter { !$0.isHiDPI }.map { "\($0.width)x\($0.height)" })
        // Injected sizes are panel-space; a rotated display enumerates them swapped.
        let rotated = display.isRotated
        let hits = injected.filter {
            let key = rotated ? "\($0.height)x\($0.width)" : "\($0.width)x\($0.height)"
            return hidpi.contains(key) && !lodpi.contains(key)
        }.count
        return hits >= 8
    }

    /// Whether enabling smooth scaling would show the admin prompt (override not yet
    /// dense). Computed off the render path (on appear + after enable) to avoid a disk
    /// read on every redraw.
    func refreshSmoothWouldPrompt() {
        let (w, h) = display.panelNativeResolution
        smoothWouldPrompt = HiDPIService.shared.smoothScalingWouldPrompt(
            vendor: display.vendorNumber, product: display.modelNumber, nativeWidth: w, nativeHeight: h)
    }

    /// The stop the slider flags as "Default", i.e. macOS's recommended scaling: the 2×
    /// Retina point (native width / 2) on the high-PPI built-in, native pixel-for-pixel on
    /// an external. Returns nil when that stop isn't on the ladder.
    func defaultSliderIndex(_ modes: [DisplayMode]) -> Int? {
        let nativeW = display.nativeResolution.width
        let targetW = display.isBuiltin ? nativeW / 2 : nativeW
        return modes.firstIndex { $0.width == targetW }
    }

    func currentSmoothIndex(_ modes: [DisplayMode]) -> Double {
        guard let cur = currentMode,
              let idx = modes.firstIndex(where: { $0.width == cur.width && $0.height == cur.height })
        else { return Double(max(modes.count - 1, 0)) }
        return Double(idx)
    }

    func looksLikeLabel(_ modes: [DisplayMode]) -> String {
        let i = Int(sliderIndex.rounded())
        guard modes.indices.contains(i) else { return "" }
        let m = modes[i]
        // Effective magnification vs native: how much larger everything looks. Native = 100%;
        // the 2x Retina point (half native, e.g. 1280×720 on a 2560×1440 panel) = 200%.
        let (nativeW, _) = display.nativeResolution
        guard nativeW > 0, m.width > 0 else { return "\(m.width) × \(m.height)" }
        let pct = Int((Double(nativeW) / Double(m.width) * 100).rounded())
        return "\(m.width) × \(m.height) · \(pct)%"
    }

    func applySmooth(_ modes: [DisplayMode]) {
        let i = Int(sliderIndex.rounded())
        guard modes.indices.contains(i) else { return }
        let target = modes[i]
        // Already rendering this synthetic size? Nothing to do. The id guard
        // below can't catch it: while mirrored, currentMode carries the virtual
        // display's real (positive) mode id, never the synthetic negative one.
        if target.id < 0, let cur = currentMode,
           cur.width == target.width, cur.height == target.height { return }
        // Keep the current refresh rate and scaling kind when offered (tolerant Hz match,
        // see selectResolution above).
        let mode = currentMode.flatMap { cur in
            display.availableModes.first {
                $0.isHiDPI == target.isHiDPI && $0.width == target.width && $0.height == target.height &&
                ResolutionService.refreshMatches($0.refreshRate, cur.refreshRate)
            }
        } ?? target
        guard mode.id != currentMode?.id else { return }
        switchTo(mode) { }
    }

    /// Flips the dense HiDPI ladder on or off: writes or removes the override, then
    /// soft-reconnects so macOS re-enumerates in software. Optimistic: the knob moves now,
    /// a settle re-read adopts whatever actually enumerated. If the soft-reconnect can't
    /// complete, the write still landed; reconnectHint says how to make it take effect (#58).
    func userToggleSmooth(_ on: Bool) {
        guard !smoothBusy, PanelOpenGuard.allowsActivation else { return }
        smoothOn = on   // optimistic; the re-enumeration below confirms it
        smoothBusy = true
        reconnectHint = nil   // fresh attempt: any hint from a previous one is now moot
        // Panel-space dims: the override plist is rotation-blind (see panelNativeResolution).
        let (nativeW, nativeH) = display.panelNativeResolution
        // Capture now, before the soft-reconnect below destroys this view; the Task uses
        // it to ask the rebuilt menu to re-expand the same display afterward.
        let targetUUID = display.displayUUID
        Task { @MainActor in
            let err: String?
            if on {
                err = HiDPIService.shared.enableSmoothScaling(
                    vendor: display.vendorNumber, product: display.modelNumber,
                    nativeWidth: nativeW, nativeHeight: nativeH)
            } else {
                err = HiDPIService.shared.disableHiDPI(
                    vendor: display.vendorNumber, product: display.modelNumber)
            }
            if let err {
                withAnimation { errorMessage = err }
                smoothOn = smoothModesPresent   // failed: snap back to reality
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { self.errorMessage = nil }
                }
            } else {
                // The soft-reconnect blanks the display, which resigns the panel's key and
                // would auto-close it, collapsing every expanded row. Suppress that so the
                // panel stays on this display's Resolution section.
                PanelOpenGuard.suppressAutoDismiss = true
                defer { PanelOpenGuard.suppressAutoDismiss = false }
                let reconnected = await PhysicalDisplayToggleService.shared.softReconnect(display)
                HiDPIService.shared.refreshModes(for: display)
                try? await Task.sleep(nanoseconds: 800_000_000)  // let refreshModes land
                smoothOn = smoothModesPresent
                refreshSmoothWouldPrompt()
                if !reconnected && smoothOn != on {
                    // The blink was refused or never landed; the write is on disk but needs
                    // a real reconnect to be read. Checking ground truth (not just the
                    // `reconnected` flag) matters: a retry-exhausted sweep can still complete
                    // the blink and re-enumerate, which must not show this hint.
                    withAnimation {
                        reconnectHint = String(
                            localized: "Saved. Unplug and replug the monitor cable, or restart your Mac, to apply.")
                    }
                }
                // The blank/auth prompt can steal key focus, greying the switch; re-key the panel.
                if let panel = NSApp.windows.first(where: { $0 is MenuPanel }), panel.isVisible {
                    panel.makeKey()
                }
                // The reconnect rebuilt this display's row; ask the menu to re-expand it and
                // reopen Resolution so the user lands back where they were.
                displayManager.pendingResolutionExpandUUID = targetUUID
                // Key theft can continue briefly after the suppression window above releases;
                // ignore bare resigns for a grace period. Real outside clicks still dismiss.
                PanelOpenGuard.resignKeyGraceUntil = Date().addingTimeInterval(5)
            }
            smoothBusy = false
        }
    }
}

// MARK: - Blocks

/// Resolution header row: its own block, always visible while the display's
/// detail is expanded.
struct ResolutionHeadBlock: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }
    @ObservedObject var state: PanelSectionState

    var body: some View {
        ExpandableRow(
            icon: "rectangle.on.rectangle",
            iconActive: false,
            label: "Resolution",
            subtitle: controller.currentGroup?.menuLabel,
            isExpanded: state.openBinding(\.resolutionOpenIDs, display.displayID)
        )
    }
}

/// The Resolution picker: a "looks like" slider (matching System Settings) over
/// sliderModes, with the full exact-mode list kept behind a "Show all resolutions"
/// disclosure (its own block, below). Falls back to the plain list when there
/// are too few slider stops.
struct ResolutionSliderBlock: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }
    @ObservedObject var state: PanelSectionState

    var body: some View {
        let modes = controller.sliderModes
        if modes.count >= 2 {
            VStack(alignment: .leading, spacing: 0) {
                modeSlider(modes)
                DisclosureSubRow(
                    label: "Show all resolutions",
                    isExpanded: state.openBinding(\.allResolutionsOpenIDs, display.displayID)
                )
            }
        } else {
            ResolutionListView(controller: controller)
        }
    }

    @ViewBuilder
    private func modeSlider(_ modes: [DisplayMode]) -> some View {
        if modes.count >= 2 {
            let defaultIdx = controller.defaultSliderIndex(modes)
            VStack(alignment: .leading, spacing: 2) {
                // Continuous, not stepped (a step swaps in a bar-style thumb); snapped to
                // whole stops via onChange instead, keeping the round knob. Applies on release.
                Slider(
                    value: $controller.sliderIndex,
                    in: 0...Double(modes.count - 1),
                    onEditingChanged: { editing in
                        if !editing { controller.applySmooth(modes) }
                    }
                )
                .controlSize(.small)
                .tint(Color.accentColor)
                .onChange(of: controller.sliderIndex) { _, v in
                    let snapped = v.rounded()
                    if snapped != controller.sliderIndex { controller.sliderIndex = snapped }
                }

                stepMarks(count: modes.count, defaultIdx: defaultIdx)

                HStack(spacing: 0) {
                    Text("Larger Text")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(controller.looksLikeLabel(modes))
                        .font(.caption2)
                    Spacer()
                    Text("More Space")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .onAppear { controller.sliderIndex = controller.currentSmoothIndex(modes) }
            .onChange(of: display.currentDisplayMode?.id) { _, _ in
                if !controller.smoothBusy { controller.sliderIndex = controller.currentSmoothIndex(modes) }
            }
        }
    }

    /// A tick per stop, default stop marked with a filled dot (as BetterDisplay does).
    /// Ticks drop once the ladder is dense (smooth scaling on) since they'd read as an
    /// illegible picket fence; the dot and the live "· NNN%" label carry it instead.
    private func stepMarks(count: Int, defaultIdx: Int?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if count <= 12 {
                    ForEach(0..<count, id: \.self) { i in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 1, height: 4)
                            .position(x: markX(i, count: count, width: geo.size.width), y: 3)
                    }
                }
                if let di = defaultIdx, count > 1 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: markX(di, count: count, width: geo.size.width), y: 3)
                }
            }
        }
        .frame(height: 8)
    }

    /// X of stop `index` along a slider of the given width, accounting for the thumb inset.
    private func markX(_ index: Int, count: Int, width: Double) -> Double {
        let thumbInset = 8.0
        let frac = count > 1 ? Double(index) / Double(count - 1) : 0
        return thumbInset + frac * max(width - thumbInset * 2, 1)
    }
}

/// The full exact-mode list behind "Show all resolutions". Rendered only in the
/// slider case; the fallback (too few stops) shows the list inline in
/// ResolutionSliderBlock instead.
struct ResolutionFullListBlock: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }

    var body: some View {
        if controller.sliderModes.count >= 2 {
            ResolutionListView(controller: controller)
        }
    }
}

/// The checkmarked resolution list, grouped HiDPI / Non-HiDPI.
private struct ResolutionListView: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }

    var body: some View {
        let groups = controller.resolutionGroups
        if groups.isEmpty {
            Text("No display modes available")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            // HiDPI is a section header, not a per-row tag. Native "(Default)" sits alone
            // at the top; everything else splits into HiDPI / Non-HiDPI.
            let defaults = groups.filter { $0.isDefault }
            let hiDPI = groups.filter { $0.isHiDPI }
            let lowRes = groups.filter { !$0.isHiDPI && !$0.isDefault }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(defaults) { resolutionRow($0, label: $0.menuLabel) }
                if !hiDPI.isEmpty {
                    resolutionSectionHeader("HiDPI")
                    ForEach(hiDPI) { resolutionRow($0, label: $0.resolutionString) }
                }
                if !lowRes.isEmpty {
                    // "Non-HiDPI", not "Low Resolution": also covers the built-in's big
                    // non-Retina 1x modes, not just an external's soft twins.
                    resolutionSectionHeader("Non-HiDPI")
                    ForEach(lowRes) { resolutionRow($0, label: $0.resolutionString) }
                }
            }
        }
    }

    private func resolutionRow(_ group: ResolutionGroup, label: String) -> some View {
        CheckmarkRow(
            label: label,
            isSelected: group.id == controller.currentGroup?.id,
            isPending: group.id == controller.pendingResolutionID
        ) {
            controller.selectResolution(group)
        }
    }

    // LocalizedStringKey, not String: Text(String) is the non-localizing overload.
    private func resolutionSectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Refresh Rate header row: a sibling section, not nested under resolution.
/// Only shown when the current resolution actually offers a choice.
struct RefreshHeadBlock: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }
    @ObservedObject var state: PanelSectionState

    var body: some View {
        if let group = controller.currentGroup, group.hasMultipleRates {
            ExpandableRow(
                icon: "waveform",
                iconActive: false,
                label: "Refresh Rate",
                subtitle: controller.currentMode.map(controller.refreshLabel),
                isExpanded: state.openBinding(\.refreshOpenIDs, display.displayID)
            )
        }
    }
}

/// The checkmarked refresh-rate list for the current resolution group.
struct RefreshListBlock: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }

    var body: some View {
        if let group = controller.currentGroup, group.hasMultipleRates {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.modes) { mode in
                    CheckmarkRow(
                        label: controller.refreshLabel(mode),
                        isSelected: mode.id == controller.currentMode?.id,
                        isPending: mode.id == controller.pendingRefreshID
                    ) {
                        controller.selectRefresh(mode)
                    }
                }
            }
        }
    }
}

/// Trailing rows of the mode section: the smooth-scaling switch (externals
/// only), the transient switch-failure message, the apply-it-yourself reconnect
/// hint, and the section divider.
struct ModeTailBlock: View {
    @ObservedObject var controller: DisplayModeController
    private var display: DisplayInfo { controller.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // External displays only: built-ins already scale via System Settings.
            if !display.isBuiltin {
                smoothScalingSection
            }

            if let msg = controller.errorMessage {
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

            // Informational, not an error (the plist write already succeeded): neutral
            // styling, and unlike errorMessage it does not auto-clear on a timer.
            if let hint = controller.reconnectHint {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(hint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .transition(.opacity)
            }

            SectionDivider()
        }
    }

    /// Smooth scaling as an on/off switch, tracking ground truth (are the dense modes
    /// enumerated) rather than a stored flag.
    private var smoothScalingSection: some View {
        Toggle(isOn: Binding(get: { controller.smoothOn }, set: { controller.userToggleSmooth($0) })) {
            HStack(spacing: 8) {
                // Icon tracks ground truth so it doesn't recolor while the admin prompt
                // blocks; the switch itself flips instantly.
                MenuItemIcon(systemName: "slider.horizontal.below.rectangle", color: .blue, active: controller.smoothModesPresent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Smooth scaling")
                        .font(.body)
                    if let hint = controller.smoothSubtitle {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if controller.smoothBusy {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!HiDPIService.smoothScalingSupported)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .onAppear {
            controller.smoothOn = controller.smoothModesPresent
            controller.refreshSmoothWouldPrompt()
        }
        .onChange(of: controller.smoothModesPresent) { _, present in
            // Adopt external truth (reconnect, another app) unless our own toggle is settling.
            if !controller.smoothBusy { controller.smoothOn = present }
        }
    }
}

// MARK: - Checkmark row

/// One selectable line in a native display-menu list (resolution, refresh rate,
/// preset): a leading checkmark column, the label, and a hover highlight. The
/// checkmark slot becomes a spinner while an async switch is pending.
struct CheckmarkRow: View {
    let label: String
    let isSelected: Bool
    var isPending: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if isPending {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .opacity(isSelected ? 1 : 0)
                }
            }
            .frame(width: 16)
            Text(label)
                .font(.body)
                .fontWeight(isSelected ? .semibold : .regular)
            Spacer()
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation, !isSelected, !isPending else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            isSelected
                ? "\(NSLocalizedString(label, comment: ""))\(NSLocalizedString(", selected", comment: ""))"
                : NSLocalizedString(label, comment: "")
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// A subordinate disclosure line (indented, chevron, hover) that reveals the full
/// "Show all resolutions" list beneath the Resolution slider. Lighter than
/// ExpandableRow (no leading icon chip) so it reads as a child of the slider.
private struct DisclosureSubRow: View {
    let label: LocalizedStringKey
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            withAnimation(.panelResize) { isExpanded.toggle() }
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Data model

private struct ResolutionGroup: Identifiable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    let isDefault: Bool
    let isLowResolution: Bool
    let modes: [DisplayMode] // sorted by refresh rate descending

    var id: String { "\(width)x\(height)_\(isHiDPI)" }
    var resolutionString: String { "\(width) × \(height)" }
    /// Native System Settings wording: retina modes clean, the 1x twin "(low
    /// resolution)", the native mode "(Default)".
    var menuLabel: String {
        if isDefault { return String(localized: "\(resolutionString) (Default)") }
        if isLowResolution { return String(localized: "\(resolutionString) (low resolution)") }
        return resolutionString
    }
    var hasMultipleRates: Bool { modes.count > 1 }
    var bestMode: DisplayMode { modes[0] }
}
