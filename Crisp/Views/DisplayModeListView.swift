import SwiftUI
import AppKit
import Combine

// Resolution and refresh-rate selection as native checkmarked lists, each a
// top-level expandable row like the System Settings display menu: resolution is
// one click away (not nested under a "Display Mode" popup), and refresh rate is
// its own section, shown only when the current resolution offers more than one.
//
// Split into canvas blocks (docs/panel-resize.md): the header rows, the
// dropdown lists, and the trailing rows are separate PanelBlocks, so opening a
// dropdown animates a clip over content that rendered once at natural height —
// no SwiftUI geometry animates per frame. The shared mutable state (pending
// switches, slider position, smooth-scaling flags) lives in
// DisplayModeController so the sibling blocks stay in sync.

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
    /// Set when a smooth-scaling toggle's soft-reconnect couldn't happen (e.g. this is the
    /// only active display and macOS refused to blink it, or the re-enable retries all
    /// failed). The plist write itself still landed on disk; this tells the user how to make
    /// it take effect instead of the switch just silently snapping back. Unlike errorMessage
    /// this does NOT auto-clear after a few seconds: "go replug the cable" isn't something to
    /// blink-and-miss, so it stays put while the section is open.
    @Published var reconnectHint: String?
    @Published var sliderIndex: Double = 0
    @Published var smoothBusy: Bool = false
    @Published var smoothOn: Bool = false
    @Published var smoothWouldPrompt: Bool = true
    private var isSwitching: Bool = false
    private var cachedGroups: [ResolutionGroup]?
    private var cachedSliderModes: [DisplayMode]?
    private var panelResolutionReloadTask: Task<Void, Never>?
    /// Panel's adaptive-sync floor (48 on a 48-180Hz panel), for the Variable row label.
    private lazy var vrrMinimumRate: Int? = VariableRefreshRange.minimumRate(
        vendorNumber: display.vendorNumber, modelNumber: display.modelNumber)
    private var displayRelay: AnyCancellable?

    init(display: DisplayInfo, displayManager: DisplayManager) {
        self.display = display
        self.displayManager = displayManager
        // The mode blocks render only from currentDisplayMode/availableModes,
        // so relay exactly those instead of having the views observe the whole
        // DisplayInfo: its brightness publishes at 125Hz during a click-glide,
        // and re-rendering six hosting views per step (each regrouping the
        // AOC's ~100-mode list) was the glide jank. dropFirst(4) skips the
        // initial replays these four @Published publishers emit on subscribe.
        displayRelay = display.$currentDisplayMode.map { _ in }
            .merge(with: display.$availableModes.map { _ in })
            .merge(with: display.$detectedPanelResolution.map { _ in })
            .merge(with: display.$manualPanelResolution.map { _ in })
            .dropFirst(4)
            .sink { [weak self] _ in
                self?.cachedGroups = nil
                self?.cachedSliderModes = nil
                self?.objectWillChange.send()
            }
    }

    var currentMode: DisplayMode? { display.currentDisplayMode }

    /// Group modes by (resolution + HiDPI), sorted by resolution descending.
    /// Cached: several block views read this per render, and it rebuilds the
    /// full grouped/sorted mode list. The relay above invalidates it.
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

        // Native label convention (matches System Settings): a non-HiDPI mode is
        // "low resolution" only when a HiDPI mode of the same logical size also
        // exists (so the retina twin is strictly better). The display's native mode
        // is the "(Default)"; only tagged for external displays, since the built-in's
        // native mode is a 1x physical size that macOS does not treat as the default.
        let hiDPISizes = Set(base.filter { $0.isHiDPI }.map { "\($0.width)x\($0.height)" })
        // Low-res twins: macOS pairs each of the panel's standard scaled sizes with a
        // non-HiDPI ("low resolution") mode, but does NOT twin the dense smooth-scaling
        // ladder it injects. So a HiDPI size with a LoDPI twin is a known/native one, and a
        // twinless HiDPI size is exactly one of the injected in-between steps.
        let lodpiSizes = Set(base.filter { !$0.isHiDPI }.map { "\($0.width)x\($0.height)" })

        let mapped = grouped.map { (_, modes) -> ResolutionGroup in
            let sorted = modes.sorted {
                if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
                // Variable above its same-rate fixed twin, matching System Settings.
                return $0.isVariableRefresh && !$1.isVariableRefresh
            }
            // One Variable row per size, like System Settings: macOS mints a variable
            // twin for every rate inside the panel's adaptive range, but only the top
            // one is a meaningful choice; the lesser twins would just render as
            // duplicate Hz rows. Keep whatever is current, as everywhere else.
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

        // Only collapse the list to the known sizes when the dense ladder is actually live
        // (lots of twinless HiDPI entries). A normal display's list is left exactly as before.
        // ponytail: count > 8 is the "smooth scaling is on" signal (it injects ~80 twinless).
        let denseLadderActive = mapped.filter {
            $0.isHiDPI && !lodpiSizes.contains("\($0.width)x\($0.height)")
        }.count > 8
        // At native size the crisp non-HiDPI Default beats a same-size HiDPI (which downscales a
        // 2x backing onto the panel and looks soft with no size benefit). Hide the HiDPI twin of
        // native when the Default is present.
        let hasNativeDefault = mapped.contains { $0.isDefault }
        // The widest HiDPI size on offer: native-aspect 1x sizes beyond it are kept below
        // (they are the only route to those in-between sizes), sizes under it stay clutter.
        let maxEligibleHiDPIWidth = base.lazy.filter { $0.isHiDPI }.map(\.width).max() ?? 0

        return mapped.filter { group in
            // Built-in (notched) panel: macOS only offers scaled sizes at the panel's
            // native aspect. CGDisplayCopyAllDisplayModes also returns 16:10 "non-notch"
            // modes (e.g. 1512x945, 2560x1600) that letterbox the notch away and aren't
            // selectable in System Settings, so drop them; always keep the active mode.
            // Non-notched built-ins share the native aspect, so nothing is dropped there.
            // ponytail: 2% tolerance cleanly splits 1.60 (16:10) from ~1.54 (notched).
            if display.isBuiltin {
                let nativeAR = Double(nativeW) / Double(nativeH)
                let ar = Double(group.width) / Double(group.height)
                return abs(ar - nativeAR) / nativeAR < 0.02
                    || group.modes.contains { $0.id == currentMode?.id }
            }
            // External: the HiDPI twin of native is redundant with the crisp Default and looks
            // softer, so drop it (unless the display is currently on it).
            if hasNativeDefault, group.isHiDPI, group.width == nativeW, group.height == nativeH,
               !group.modes.contains(where: { $0.id == currentMode?.id }) {
                return false
            }
            // External, dense ladder live: keep only the known sizes (those with a low-res
            // twin) in the list. The injected in-between steps stay off the list but remain
            // on the slider, so people who want the "known ones" aren't wading through 100.
            if denseLadderActive, group.isHiDPI, !group.isDefault,
               !lodpiSizes.contains("\(group.width)x\(group.height)"),
               !group.modes.contains(where: { $0.id == currentMode?.id }) {
                return false
            }
            // External: drop standalone 1x oddballs (non-HiDPI, no HiDPI twin, not
            // the native default) that clutter the list, e.g. 2048x1152, 1344x756,
            // and the off-aspect 4:3/5:4/portrait sizes. Keep native, the HiDPI
            // ladder, the "(low resolution)" twins, and whatever is current.
            if group.isHiDPI || group.isDefault || group.isLowResolution { return true }
            // Non-retina scaled sizes past the HiDPI ladder's reach: WindowServer caps
            // scaled backings per display, and on a 5K2K ultrawide the sizes between the
            // ladder top (~3360 wide) and native exist only as 1x modes (4608x1296,
            // 4096x1152, 3840x1080 on a U4924DW). They are what System Settings offers
            // there, so keep native-aspect 1x sizes wider than every HiDPI mode; the
            // off-aspect compat sizes and the sub-ladder clutter above stay dropped.
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
        let displayUUID = display.displayUUID
        Task { @MainActor in
            var success: Bool
            if mode.id < 0 {
                // Synthetic beyond-cap stop (#65, negative id): no CG mode exists
                // on the physical display; MirroredModeService renders the size on
                // a hidden virtual display the panel hardware-mirrors.
                success = await MirroredModeService.shared.apply(
                    display: display, width: mode.width, height: mode.height)
            } else {
                // Leaving a mirrored stop for a real mode: unmirror and destroy
                // first, otherwise the physical display is still a mirror target
                // and the mode change would be redirected to the virtual source.
                // A failed unmirror keeps the mirror up (restore leaves the
                // bookkeeping alone then), so report failure instead of pushing
                // a mode change at a panel that is still a target.
                success = await MirroredModeService.shared.withMirrorRestored(for: display) {
                    var applied = await ResolutionService.shared.setDisplayMode(
                        mode, for: displayID, expectedDisplayUUID: displayUUID)
                    if !applied {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        applied = await ResolutionService.shared.setDisplayMode(
                            mode, for: displayID, expectedDisplayUUID: displayUUID)
                    }
                    return applied
                }
            }
            if success {
                // Optimistic: the reconfiguration callback's setModeFlag branch
                // re-reads the authoritative mode into display.currentDisplayMode
                // moments later (refreshExistingDisplayModes); this only moves the
                // checkmark instantly instead of after a 300ms re-read.
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

    /// The ladder the Resolution slider steps through. Built-in: the native-aspect HiDPI
    /// "looks like" stops macOS's own slider shows (no 1x "native" stop, since macOS caps
    /// More Space at the largest HiDPI mode). External: smoothModes (HiDPI ladder + native
    /// pixel-for-pixel as the More Space end), which the smooth-scaling toggle densifies.
    /// Cached like resolutionGroups; the relay invalidates it.
    var sliderModes: [DisplayMode] {
        if let cachedSliderModes { return cachedSliderModes }
        let computed = display.isBuiltin ? builtinLooksLikeModes : smoothModes
        cachedSliderModes = computed
        return computed
    }

    /// Built-in "looks like" stops: the native-aspect HiDPI modes (e.g. 1024×665 …
    /// 1800×1169). The aspect test also excludes the 16:10 non-notch modes, matching
    /// the resolution list. One representative per size, ascending (left = Larger Text).
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

    /// The "looks like" ladder for the slider: every HiDPI logical size plus the native
    /// (max) resolution as the top "More Space" stop. On a standard panel the native mode
    /// is non-HiDPI, and the HiDPI ladder can't reach it (native-as-HiDPI needs a backing
    /// the panel/DCP won't enumerate), so without this the slider topped out below the
    /// display's real maximum. One representative per logical size (prefer HiDPI, then
    /// highest refresh), ascending: left = Larger Text, right = More Space.
    private var smoothModes: [DisplayMode] {
        let (nativeW, nativeH) = display.nativeResolution
        // Floor the slider at 50% of native (the 2× Retina point), matching the injected
        // ladder and BetterDisplay. Without this, small HiDPI modes macOS also enumerates
        // (e.g. 800×600 accessibility sizes) would drag the left stop far below anything usable.
        let minWidth = nativeW / 2
        // Top stop = the crisp non-HiDPI native, not its same-size HiDPI twin (which downscales a
        // 2x backing onto the panel and looks soft with no size benefit). Drop that twin when the
        // native exists, so the dedup below keeps the crisp one for the "More Space" end.
        let hasNativeDefault = display.availableModes.contains { !$0.isHiDPI && $0.width == nativeW && $0.height == nativeH }
        var seen = Set<String>()
        var ladder = display.availableModes
            .filter {
                guard DisplayModeGeometry.hasSameOrientation(
                    width: $0.width, height: $0.height, as: nativeW, nativeH
                ) else { return false }
                // Native aspect only (same 2% tolerance as builtinLooksLikeModes):
                // macOS also enumerates accessibility sizes off the panel's aspect
                // (800×600; 600×800 when rotated), and on a 1200-wide portrait
                // native the rotated one clears the 50% width floor exactly.
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
        // Beyond-cap synthetic stops (#65): WindowServer refuses scaled backings
        // above a per-display cap, so on 5K2K ultrawides the sizes between the
        // enumerable ladder top (~looks-like 3360) and native exist as no HiDPI
        // mode at all. Mint slider stops for them on the same 16px grid, with
        // NEGATIVE ids so they can never collide with a real ioDisplayModeID or
        // reach the CG apply path: switchTo routes them to MirroredModeService
        // (a hidden virtual display renders the 2x backing, the panel hardware-
        // mirrors it and downscales on scanout). Gated on the dense ladder being
        // live, like the rest of smooth scaling; which panels get stops at all is
        // MirroredModeService.beyondCapStops's call (empty on uncapped panels, so
        // the slider is exactly what it was).
        if smoothModesPresent {
            ladder += MirroredModeService.beyondCapStops(for: display)
                .map { DisplayMode(id: -Int32($0.width), width: $0.width, height: $0.height,
                                   pixelWidth: $0.width * 2, pixelHeight: $0.height * 2,
                                   refreshRate: 0, isHiDPI: true, isNative: false) }
        }
        return ladder.sorted { $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width }
    }

    /// Subtitle for the row while off: what smooth scaling does (the decision point), plus the
    /// admin/flash heads-up when enabling would actually prompt (the dense override isn't on
    /// disk yet). On shows nothing, the switch says it all.
    var smoothSubtitle: String? {
        // Ground truth, not the optimistic switch value: the hint stays put through the whole
        // operation (so the row height, and the icon centered against it, don't jump mid-prompt)
        // and only clears once the dense modes actually enumerate.
        guard !smoothModesPresent else { return nil }
        return smoothWouldPrompt
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            ? String(localized: "Adds finer in-between steps for how large everything looks. Enabling asks for an administrator password and briefly flashes the screen")
            : String(localized: "Adds finer in-between steps for how large everything looks")
    }

    /// Whether the dense smooth-scaling ladder is actually enumerated for this display. The
    /// real "is it on" signal, independent of any stored flag; it is exactly what the slider's
    /// density reflects. When true the enable row is hidden, there is nothing left to do.
    ///
    /// Counted as twinless hits on the injected grid, not as a share of the injected sizes:
    /// WindowServer silently refuses scaled backings above a per-display cap, so on a 5K2K
    /// ultrawide only a third of the ladder ever materializes (up to looks-like ~3360 wide)
    /// and a fixed fraction can never pass. Stock HiDPI sizes always carry a 1x twin while
    /// the injected in-between steps never do (the denseLadderActive signal), so a handful
    /// of twinless grid hits means the ladder, or what the hardware allows of it, is live.
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
        // Keep the current refresh rate at that logical size and scaling kind when offered.
        // Tolerant match: CG reports fractional rates (59.94) where the CGS-surfaced modes
        // carry whole Hz.
        let mode = currentMode.flatMap { cur in
            display.availableModes.first {
                $0.isHiDPI == target.isHiDPI && $0.width == target.width && $0.height == target.height &&
                ResolutionService.refreshMatches($0.refreshRate, cur.refreshRate)
            }
        } ?? target
        guard mode.id != currentMode?.id else { return }
        switchTo(mode) { }
    }

    /// Flips the dense HiDPI ladder on or off. ON writes the override, OFF removes it; both then
    /// soft-reconnect (screen blanks ~1s) so macOS re-enumerates in software rather than on a
    /// physical reconnect, and both touch /Library/Displays so both show one admin prompt. When
    /// the soft-reconnect itself can't complete (e.g. a re-enable that never lands), the write
    /// already landed on disk; reconnectHint tells the user how to make it take effect instead
    /// of the switch just silently snapping back (issue #58). Optimistic: the knob moves now,
    /// a settle re-read adopts whatever actually enumerated.
    func userToggleSmooth(_ on: Bool) {
        guard !smoothBusy, PanelOpenGuard.allowsActivation else { return }
        smoothOn = on   // optimistic; the re-enumeration below confirms it
        smoothBusy = true
        reconnectHint = nil   // fresh attempt: any hint from a previous one is now moot
        // Panel-space dims: the override plist is rotation-blind (see panelNativeResolution).
        let (nativeW, nativeH) = display.panelNativeResolution
        // Capture now, while the display is still connected and its UUID resolves; the
        // soft-reconnect below destroys this view, but the Task keeps running and uses
        // this to ask the rebuilt menu to re-expand the same display afterward.
        let targetUUID = display.displayUUID
        Task { @MainActor in
            var operationError: String?
            var reconnected = false
            let mirrorRestored = await MirroredModeService.shared.withMirrorRestored(for: display) { [self] in
                if on {
                    operationError = HiDPIService.shared.enableSmoothScaling(
                        vendor: display.vendorNumber, product: display.modelNumber,
                        nativeWidth: nativeW, nativeHeight: nativeH)
                } else {
                    operationError = HiDPIService.shared.disableHiDPI(
                        vendor: display.vendorNumber, product: display.modelNumber)
                }
                guard operationError == nil else { return true }

                // The reconnect must stay in the same per-display operation as
                // teardown and the plist mutation. Otherwise an apply can make
                // the panel a mirror target again before it is blinked.
                PanelOpenGuard.suppressAutoDismiss = true
                defer { PanelOpenGuard.suppressAutoDismiss = false }
                reconnected = await PhysicalDisplayToggleService.shared.softReconnect(display)
                HiDPIService.shared.refreshModes(for: display)
                try? await Task.sleep(nanoseconds: 800_000_000)
                return true
            }
            if !mirrorRestored {
                operationError = String(localized: "Failed to apply. Please try again.")
            }
            if let err = operationError {
                withAnimation { errorMessage = err }
                smoothOn = smoothModesPresent   // failed: snap back to reality
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { self.errorMessage = nil }
                }
            } else {
                // The soft-reconnect blanks the display ~1s, which makes the panel resign
                // key. That normally auto-closes it (windowDidResignKey), and closePanel
                // posts crispPanelDidClose, collapsing every expanded row, dumping the user
                // back to the top. Suppress the resign/outside-click dismissal for the
                // duration so the panel stays put on this display's Resolution section;
                // nothing to restore because it never closes.
                smoothOn = smoothModesPresent
                refreshSmoothWouldPrompt()
                if !reconnected && smoothOn != on {
                    // The blink was refused (Intel, or a portable's sleep guard failed to
                    // create) or never landed, and the re-read never happened:
                    // the switch above snapped back to ground truth, which would otherwise look
                    // like the toggle silently did nothing. It didn't: the plist write landed,
                    // it just needs a real reconnect (or reboot) to be read. The ground-truth
                    // check matters: when softReconnect returns false but its retry-exhausted
                    // sweep completed the blink anyway, the modes DID re-enumerate, a hint
                    // would be wrong, and that path also rebuilt this controller so a hint set
                    // here could never render (the rebuilt row reads the fresh controller).
                    withAnimation {
                        reconnectHint = String(
                            localized: "Saved. Unplug and replug the monitor cable, or restart your Mac, to apply.")
                    }
                }
                // The blank/auth prompt can steal key focus, greying the switch; re-key the panel.
                if let panel = NSApp.windows.first(where: { $0 is MenuPanel }), panel.isVisible {
                    panel.makeKey()
                }
                // The reconnect rebuilt this display's row (fresh, collapsed). Ask the menu to
                // re-expand it and reopen Resolution, so the user lands back where they were.
                displayManager.pendingResolutionExpandUUID = targetUUID
                // The settle storm keeps stealing key for a few seconds after the
                // suppression window (the defer above) releases; the makeKey above
                // re-armed resign-key, so a late steal would close the panel right
                // after a successful toggle. Ignore bare resigns for a grace period;
                // real outside clicks still dismiss via the global click monitor.
                PanelOpenGuard.resignKeyGraceUntil = Date().addingTimeInterval(5)
            }
            smoothBusy = false
        }
    }

    /// Persist a physical panel-size fallback after safely retiring any active
    /// mirror virtual, then rebuild this display's mode data from the new size.
    func setPanelResolutionOverride(width: Int, height: Int) -> Bool {
        let resolution = PanelResolution(width: width, height: height)
        guard resolution.isPlausible else { return false }
        queuePanelResolutionChange(resolution)
        return true
    }

    func clearPanelResolutionOverride() {
        queuePanelResolutionChange(nil)
    }

    private func queuePanelResolutionChange(_ resolution: PanelResolution?) {
        let previous = panelResolutionReloadTask
        panelResolutionReloadTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let applied = await MirroredModeService.shared.updatePanelResolution(for: display) {
                self.display.setManualPanelResolution(resolution)
                await self.display.loadDetails()
            }
            guard applied else {
                withAnimation {
                    self.errorMessage = String(localized: "Failed to apply. Please try again.")
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { self.errorMessage = nil }
                }
                return
            }
            self.cachedGroups = nil
            self.cachedSliderModes = nil
            self.refreshSmoothWouldPrompt()
            self.objectWillChange.send()
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
                // Continuous slider (no native step, which would swap in a bar-style thumb)
                // so its knob matches the brightness slider above. Snapped to whole stops
                // live via onChange, so it still clicks tick-to-tick with the round knob.
                // The mode only switches on release; dragging just moves the knob/label.
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

    /// A tick per stop, with the default stop drawn as a filled dot on top of its tick
    /// (the way BetterDisplay marks it). A dot rather than a "Default" label stays clean
    /// even when the default sits at the very edge. Positioned to track the slider thumb,
    /// which is inset from the track edges by ~half its width (see markX's thumbInset).
    ///
    /// The per-step ticks are dropped once the ladder is dense (smooth scaling on, ~80
    /// stops): at that count they read as an illegible picket fence and fight the
    /// continuous "smooth" feel, so the slider shows only the default dot and leans on
    /// the live "· NNN%" label. Ticks stay for the sparse default ladder.
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
            // HiDPI is surfaced once as a section header instead of per-row. The
            // native "(Default)" mode is neither HiDPI nor low-resolution, so it sits
            // alone at the top; everything else splits into HiDPI / Non-HiDPI.
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
                    // "Non-HiDPI" (not "Low Resolution"): accurate for both the
                    // external's soft 1x twins and the built-in's big 1x modes
                    // (e.g. 3024x1964, high pixel count but non-Retina).
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
            // Smooth scaling: on/off switch for the dense HiDPI ladder the Resolution slider
            // steps through. External displays only (built-ins already scale via System Settings).
            if !display.isBuiltin {
                smoothScalingSection
                PanelResolutionOverrideSection(controller: controller)
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

    /// Smooth scaling as an on/off switch. ON injects the dense HiDPI ladder (admin write +
    /// soft-reconnect, screen blanks ~1s); OFF removes the override + soft-reconnects, falling
    /// back to the panel's standard CGS scaled modes (HiDPI intact, just coarser steps). The
    /// switch tracks ground truth (are the dense modes enumerated), not a stored flag.
    private var smoothScalingSection: some View {
        Toggle(isOn: Binding(get: { controller.smoothOn }, set: { controller.userToggleSmooth($0) })) {
            HStack(spacing: 8) {
                // Track ground truth (are the dense modes live), not the optimistic switch value,
                // so the icon doesn't recolor or shift while the admin prompt blocks. The switch
                // still flips instantly for responsiveness; the icon settles when modes re-enumerate.
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

/// Compact fallback editor for panels whose EDID/native-format metadata is absent or wrong.
/// Dimensions are panel-space (unrotated), matching the override plist and monitor spec sheet.
private struct PanelResolutionOverrideSection: View {
    @ObservedObject var controller: DisplayModeController
    @State private var editing = false
    @State private var width = ""
    @State private var height = ""
    @State private var validationFailed = false
    @State private var hovered = false

    private var display: DisplayInfo { controller.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard PanelOpenGuard.allowsActivation else { return }
                loadCurrentValues()
                withAnimation(.panelResize) { editing.toggle() }
            } label: {
                HStack(spacing: 8) {
                    MenuItemIcon(systemName: "rectangle.on.rectangle", color: .blue,
                                 active: display.manualPanelResolution != nil)
                        .accessibilityHidden(true)
                    Text("Native resolution")
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    Text(resolutionSubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: editing ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuRowHover(hovered)
            .onHover { hovered = $0 }

            if editing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use this only when the detected panel size is wrong.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(resolutionSourceLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack(spacing: 5) {
                        PanelNumericField(text: $width, placeholder: String(localized: "Width"))
                        Text("×").foregroundColor(.secondary)
                        PanelNumericField(text: $height, placeholder: String(localized: "Height"))
                        Button("Save") { save() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if display.manualPanelResolution != nil {
                        Button("Use detected resolution") {
                            controller.clearPanelResolutionOverride()
                            loadCurrentValues()
                            validationFailed = false
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    if validationFailed {
                        Text("Enter a valid panel size from 640×480 up to 16384×16384.")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 5)
                .transition(.opacity)
            }
        }
    }

    private var resolutionSubtitle: String {
        let (width, height) = display.panelNativeResolution
        return "\(width) × \(height)"
    }

    private var resolutionSourceLabel: String {
        switch display.panelResolutionSource {
        case .manual: String(localized: "Manual")
        case .edid: String(localized: "Detected from EDID")
        case .registry: String(localized: "Detected from display metadata")
        case .displayModes: String(localized: "Inferred from display modes")
        case .currentPixels: String(localized: "Inferred from current mode")
        }
    }

    private func loadCurrentValues() {
        let resolution = display.manualPanelResolution
            ?? PanelResolution(width: display.panelNativeResolution.width,
                               height: display.panelNativeResolution.height)
        width = String(resolution.width)
        height = String(resolution.height)
        validationFailed = false
    }

    private func save() {
        guard let width = Int(width), let height = Int(height),
              controller.setPanelResolutionOverride(width: width, height: height) else {
            validationFailed = true
            return
        }
        validationFailed = false
        withAnimation(.panelResize) { editing = false }
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
    /// resolution)", the display's native mode "(Default)". Every unmarked row is
    /// therefore a HiDPI/retina mode; the "(low resolution)" tag flags the soft ones.
    var menuLabel: String {
        if isDefault { return "\(resolutionString) (Default)" }
        if isLowResolution { return "\(resolutionString) (low resolution)" }
        return resolutionString
    }
    var hasMultipleRates: Bool { modes.count > 1 }
    var bestMode: DisplayMode { modes[0] }
}
