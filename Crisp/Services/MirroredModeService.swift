import CoreGraphics
import Foundation
import os.log

/// True HiDPI past WindowServer's scaled-backing cap (issue #65): mirrors the physical
/// panel onto a hidden virtual display driven at the wanted looks-like HiDPI mode, whose
/// framebuffer is rendered rather than scanned out, so the cap doesn't apply. Lazy lifecycle:
/// the virtual exists only while a beyond-cap size is active; `restore` unmirrors first, then
/// destroys. Nothing persists; rotated panels are unverified with mirroring.
/// See docs/display-notes.md (MirroredModeService).
@MainActor
final class MirroredModeService: ObservableObject {
    static let shared = MirroredModeService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "mirroredmode")

    /// Live CGVirtualDisplay per mirrored physical display; releasing a value destroys it,
    /// so this dictionary IS the state.
    private var active: [CGDirectDisplayID: CGVirtualDisplay] = [:]

    @Published private(set) var activePhysicalIDs: Set<CGDirectDisplayID> = []

    /// Serial-number marker stamped on every mirror virtual, alongside the shared 0xEEEE
    /// vendor stamp, so launch recovery can recognize a stray left by a crash.
    static let mirrorSerialMarker: UInt32 = 0x4D49_5252

    // MARK: - Queries

    func isActive(for physicalID: CGDirectDisplayID) -> Bool {
        active[physicalID] != nil
    }

    func virtualDisplayID(for physicalID: CGDirectDisplayID) -> CGDirectDisplayID? {
        active[physicalID]?.displayID
    }

    /// Read from the virtual master's active mode, or nil when not mirrored.
    func currentLooksLike(for physicalID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let vdID = active[physicalID]?.displayID,
              let cur = CGDisplayCopyDisplayMode(vdID) else { return nil }
        return (cur.width, cur.height)
    }

    // MARK: - Apply / Restore

    /// Puts `display` on a beyond-cap looks-like size: first call creates the mirror virtual,
    /// later calls just switch its mode. Unwinds fully on failure.
    @discardableResult
    func apply(display: DisplayInfo, width: Int, height: Int) async -> Bool {
        guard !display.isBuiltin else { return false }
        let physicalID = display.displayID

        if let vdID = active[physicalID]?.displayID {
            guard await setLooksLike(width: width, height: height, on: vdID) else {
                Self.log.error("apply \(width)x\(height): setLooksLike failed on existing virtual \(vdID)")
                return false
            }
            // Re-arm if a wake or WindowServer reset collapsed the mirror set without telling us.
            if CGDisplayMirrorsDisplay(physicalID) != vdID {
                Self.log.info("apply \(width)x\(height): reused virtual \(vdID), re-arming mirror")
                return await MirrorService.shared.enableMirror(source: vdID, target: physicalID)
            }
            Self.log.info("apply \(width)x\(height): reused virtual \(vdID)")
            return true
        }

        guard let virtualDisplay = await createMirrorVirtual(for: display,
                                                             mustInclude: (width, height))
        else {
            Self.log.error("apply \(width)x\(height): createMirrorVirtual failed")
            return false
        }
        active[physicalID] = virtualDisplay
        activePhysicalIDs.insert(physicalID)

        guard await setLooksLike(width: width, height: height, on: virtualDisplay.displayID) else {
            Self.log.error("apply \(width)x\(height): setLooksLike failed on fresh virtual \(virtualDisplay.displayID)")
            await restore(physicalID: physicalID)
            return false
        }
        guard await MirrorService.shared.enableMirror(source: virtualDisplay.displayID,
                                                      target: physicalID) else {
            Self.log.error("apply \(width)x\(height): enableMirror failed (virtual \(virtualDisplay.displayID) -> physical \(physicalID))")
            await restore(physicalID: physicalID)
            return false
        }
        Self.log.info("apply \(width)x\(height): mirrored physical \(physicalID) onto virtual \(virtualDisplay.displayID)")
        return true
    }

    /// Unmirrors the physical display, then destroys the virtual. Order matters: destroying
    /// the master of a live mirror is undefined.
    @discardableResult
    func restore(display: DisplayInfo) async -> Bool {
        await restore(physicalID: display.displayID)
    }

    @discardableResult
    func restore(physicalID: CGDirectDisplayID) async -> Bool {
        guard let vdID = active[physicalID]?.displayID else { return true }
        Self.log.info("restore: unmirroring physical \(physicalID), destroying virtual \(vdID)")
        // Only a confirmed unmirror may let the virtual go: the panel may still be mirroring
        // it, so keep the entry and let the next slider move or reconcile() try again.
        guard await MirrorService.shared.disableMirror(displayID: physicalID) else {
            Self.log.error("restore: unmirror of physical \(physicalID) failed, keeping virtual \(vdID)")
            return false
        }
        // Dropping the last reference starts WindowServer's async teardown.
        active.removeValue(forKey: physicalID)
        activePhysicalIDs.remove(physicalID)
        await waitForDisplayOffline(vdID)
        return true
    }

    /// Drops bookkeeping for a mirrored physical that got unplugged, or a virtual that died
    /// without us (WindowServer can collapse the mirror set on its own). Checked against the
    /// online list, not a removed-ID diff, since the virtual is never in `DisplayManager.displays`.
    func reconcile(online: Set<CGDirectDisplayID>) {
        for (physicalID, virtualDisplay) in active
        where !online.contains(physicalID) || !online.contains(virtualDisplay.displayID) {
            active.removeValue(forKey: physicalID)
            activePhysicalIDs.remove(physicalID)
        }
    }

    /// A Crisp mirror virtual, ours or a stray from a crashed session (shared vendor stamp
    /// plus the mirror serial). DisplayManager keeps these out of `displays`.
    static func isMirrorVirtual(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == VirtualDisplayService.crispVirtualVendorID
            && CGDisplaySerialNumber(displayID) == mirrorSerialMarker
    }

    /// The looks-like sizes a display can only reach through mirror mode. One definition for
    /// the slider, presets, and the virtual's mode list, so they can never disagree.
    /// See docs/display-notes.md (MirroredModeService).
    static func beyondCapStops(for display: DisplayInfo) -> [(width: Int, height: Int)] {
        guard !display.isBuiltin else { return [] }
        let (nativeW, nativeH) = display.nativeResolution
        guard nativeW > 0, nativeH > 0 else { return [] }
        // ponytail: ultrawide-only (21:9+) until a 16:9 4K/5K panel is verified with the
        // mirror; also capped, untested. Drop this guard to widen.
        guard Double(nativeW) / Double(nativeH) >= 2.0 else { return [] }
        let hidpiTop = display.availableModes.filter { $0.isHiDPI }.map(\.width).max() ?? 0
        guard hidpiTop > 0 else { return [] }
        return HiDPIService.shared
            .smoothScaledLogicalSizes(nativeWidth: nativeW, nativeHeight: nativeH)
            .filter { $0.width > hidpiTop && $0.width < nativeW }
    }

    /// Frees a physical display left mirroring a stray Crisp mirror virtual (a crashed
    /// session's, not ours). Unmirrors rather than destroying, since we hold no object for it.
    func recoverStrandedMirrors() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids where CGDisplayVendorNumber(id) == VirtualDisplayService.crispVirtualVendorID
            && CGDisplaySerialNumber(id) == Self.mirrorSerialMarker
            && !active.values.contains(where: { $0.displayID == id }) {
            guard let target = MirrorService.shared.mirrorTargets(of: id) else { continue }
            Task { await MirrorService.shared.disableMirror(displayID: target) }
        }
    }

    /// Quit-path teardown: applicationWillTerminate can't await, so this unmirrors
    /// synchronously rather than leaving the panel mirrored.
    func teardownAll() {
        for physicalID in active.keys {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { continue }
            CGConfigureDisplayMirrorOfDisplay(cfg, physicalID, kCGNullDirectDisplay)
            if CGCompleteDisplayConfiguration(cfg, .forSession) != .success {
                CGCancelDisplayConfiguration(cfg)
            }
        }
        active.removeAll()
        activePhysicalIDs.removeAll()
    }

    // MARK: - Creation

    /// Builds the mirror virtual: stable identity, the panel's physical size, and a
    /// backing + half-size mode pair for every beyond-cap stop. See docs/display-notes.md
    /// (MirroredModeService) for why the pair is mandatory and the mode-count ceiling.
    private func createMirrorVirtual(for display: DisplayInfo,
                                     mustInclude: (width: Int, height: Int)) async -> CGVirtualDisplay? {
        let (nativeW, nativeH) = display.nativeResolution
        guard nativeW > 0, nativeH > 0 else { return nil }

        // Registration pops macOS's picker, which steals key focus and would trip the
        // panel's auto-dismiss; same suppression as VirtualDisplayService.create.
        PanelOpenGuard.suppressAutoDismiss = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PanelOpenGuard.suppressAutoDismiss = false
            }
        }

        let descriptor = CGVirtualDisplayDescriptor()
        let mm = CGDisplayScreenSize(display.displayID)
        descriptor.sizeInMillimeters = mm.width > 0 ? mm
            : CGSize(width: Double(nativeW) / 110.0 * 25.4, height: Double(nativeH) / 110.0 * 25.4)
        descriptor.maxPixelsWide = UInt32(nativeW * 2)
        descriptor.maxPixelsHigh = UInt32(nativeH * 2)
        // System UI lists the virtual while mirrored (Control Center, first-run Extend
        // picker); a distinct name reads as a feature, a duplicate "Name (2)" as a glitch.
        descriptor.name = String(localized: "\(display.name) (Crisp)")
        descriptor.vendorID = VirtualDisplayService.crispVirtualVendorID
        // Stable per monitor; two identical monitors mirroring at once would collide (accepted edge).
        let panelIdentity = display.vendorNumber ^ display.modelNumber
        descriptor.productID = panelIdentity != 0 ? panelIdentity : 0x4D52
        descriptor.serialNum = Self.mirrorSerialMarker

        // The requested size is force-included in case it sits off the smooth-scaling grid.
        var stops = Self.beyondCapStops(for: display)
        if !stops.contains(where: { $0.width == mustInclude.width && $0.height == mustInclude.height }) {
            stops.append((width: mustInclude.width, height: mustInclude.height))
        }

        // One rate only (the panel's own, 60 when unreadable): a second would push the
        // dense ladder past the object ceiling. See docs/display-notes.md (MirroredModeService).
        let panelRate = display.currentDisplayMode?.refreshRate ?? 60
        let rate: Double = panelRate > 0 ? panelRate : 60

        // Declares BOTH the 2x backing and half-size pixel mode per stop; backing-only
        // twins enumerate but fail every apply (verified on a 5K2K panel).
        var modes: [CGVirtualDisplayMode] = []
        for stop in stops where stop.width >= 1 && stop.height >= 1 {
            modes.append(CGVirtualDisplayMode(width: UInt(stop.width * 2),
                                              height: UInt(stop.height * 2),
                                              refreshRate: rate))
            modes.append(CGVirtualDisplayMode(width: UInt(stop.width),
                                              height: UInt(stop.height),
                                              refreshRate: rate))
        }
        guard !modes.isEmpty else {
            Self.log.error("createMirrorVirtual: no beyond-cap stops (native \(nativeW)x\(nativeH))")
            return nil
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = true
        settings.modes = modes

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            Self.log.error("createMirrorVirtual: CGVirtualDisplay init returned nil")
            return nil
        }
        // apply blocks on WindowServer IPC; off-main with a timeout like every CG transaction.
        let vd = virtualDisplay
        let s = settings
        let applied: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applied, virtualDisplay.displayID != kCGNullDirectDisplay else {
            Self.log.error("createMirrorVirtual: applySettings \(applied ? "ok but null displayID" : "failed") (\(modes.count) modes)")
            return nil
        }
        Self.log.info("createMirrorVirtual: virtual \(virtualDisplay.displayID) up, \(modes.count) modes declared")
        return virtualDisplay
    }

    // MARK: - Helpers

    /// Retries while WindowServer finishes enumerating the fresh display; prefers the
    /// highest refresh rate offered at that size.
    private func setLooksLike(width: Int, height: Int, on virtualID: CGDirectDisplayID) async -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for attempt in 0..<10 {
            if attempt > 0 {
                await ReconfigEvents.shared.next(for: virtualID,
                                                 matching: [.setModeFlag, .addFlag], timeout: 0.4)
            }
            if let cur = CGDisplayCopyDisplayMode(virtualID),
               cur.width == width, cur.height == height, cur.pixelWidth == width * 2 { return true }
            guard let modes = CGDisplayCopyAllDisplayModes(virtualID, options) as? [CGDisplayMode],
                  let target = modes.filter({
                      $0.width == width && $0.height == height && $0.pixelWidth == width * 2
                  }).max(by: { $0.refreshRate < $1.refreshRate })
            else { continue }
            if await ResolutionService.applyModeSync(target, on: virtualID) { return true }
        }
        // Distinguish "twin never enumerated" from "apply kept failing".
        let options2 = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let seen = (CGDisplayCopyAllDisplayModes(virtualID, options2) as? [CGDisplayMode]) ?? []
        let hasTwin = seen.contains { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }
        Self.log.error("setLooksLike \(width)x\(height) on \(virtualID): gave up after 10 attempts, \(seen.count) modes enumerated, HiDPI twin \(hasTwin ? "present (apply failed)" : "never minted")")
        return false
    }

    /// Bounded wait for a torn-down virtual display to leave the online list.
    private func waitForDisplayOffline(_ displayID: CGDirectDisplayID) async {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard ids.contains(displayID) else { return }
        await ReconfigEvents.shared.next(for: displayID, matching: .removeFlag, timeout: 1.5)
    }
}
