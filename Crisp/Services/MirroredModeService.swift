import CoreGraphics
import Foundation
import ApplicationServices
import os.log

/// True HiDPI past WindowServer's scaled-backing cap (issue #65). On 5K2K
/// ultrawides macOS refuses scaled backings wider than ~6720px, so looks-like
/// sizes between the ladder top (~3360 wide) and native never enumerate as
/// HiDPI on the physical display. This service delivers them anyway: it creates
/// a hidden virtual display whose framebuffer is rendered, not scanned out (the
/// cap does not apply there), drives it to the wanted looks-like HiDPI mode,
/// and hardware-mirrors the physical panel onto it; the scanout engine
/// downscales. The findings behind the recipe (mode declaration rules, the
/// ~400-object applySettings ceiling, unmirror-before-destroy order) live in
/// scripts/mirror-hidpi-probe.swift and its commit history.
///
/// Lazy lifecycle: the virtual display exists only while a beyond-cap size is
/// active; `restore` unmirrors first, then destroys. Nothing is persisted, a
/// relaunch comes up unmirrored. Rotated panels are unverified with mirroring.
@MainActor
final class MirroredModeService: ObservableObject {
    static let shared = MirroredModeService()
    private init() {}

    /// Mirror mode only misbehaves on live hardware, so every failure branch
    /// logs; `log stream --predicate 'subsystem == "com.crisp.app"'` while
    /// reproducing tells which step broke without a debug build.
    private static let log = Logger(subsystem: "com.crisp.app", category: "mirroredmode")

    /// Live CGVirtualDisplay per mirrored physical display. Releasing a value
    /// is what destroys its virtual display, so this dictionary IS the state.
    private var active: [CGDirectDisplayID: CGVirtualDisplay] = [:]
    /// Stops declared on each active virtual. A request outside the bounded
    /// window can rebuild immediately instead of waiting through mode retries.
    private var declaredStops: [CGDirectDisplayID: Set<PanelResolution>] = [:]
    /// Virtual IDs whose strong reference was dropped but whose asynchronous
    /// WindowServer teardown has not yet been confirmed. Stable identity must
    /// not be recreated until these IDs leave the online list.
    private var retiringVirtualIDs: [UInt32: CGDirectDisplayID] = [:]
    /// The descriptor identity associated with each (volatile) physical ID.
    /// Kept across disconnects so a reconnect under a new CGDirectDisplayID
    /// still finds teardown state keyed by the stable virtual product ID.
    private var identityKeysByPhysicalID: [CGDirectDisplayID: UInt32] = [:]
    private struct PhysicalFingerprint: Equatable {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let uuid: String
    }
    /// Guards against macOS reusing a numeric display ID for different
    /// hardware during a reconnect storm.
    private var fingerprintsByPhysicalID: [CGDirectDisplayID: PhysicalFingerprint] = [:]

    private struct OperationTail {
        let token: UUID
        let task: Task<Bool, Never>
    }
    /// Serializes every apply/restore/native-size mutation per physical panel.
    /// MainActor alone is insufficient because these operations await and are
    /// therefore reentrant.
    private var operationTails: [UInt32: OperationTail] = [:]
    /// Physical displays with a mandatory unmirror queued behind a timed-out
    /// WindowServer call. New operations fail fast until its late completion
    /// repairs state, while the caller that requested teardown stays bounded.
    private var deferredCleanupIdentityKeys: Set<UInt32> = []
    /// Stable identities whose CGVirtualDisplay.apply is still queued/running
    /// after its caller timed out. No second object with the same descriptor
    /// identity may be constructed until the late result has been retired.
    private var deferredCreationIdentityKeys: Set<UInt32> = []
    /// Failed/timed-out creations kept alive during a bounded registration
    /// settle. The stable identity lease remains held until the object is
    /// explicitly released and the online descriptor list is rescanned.
    private var failedCreationObjects: [UInt32: CGVirtualDisplay] = [:]

    /// Published mirror of `active`'s keys so views can observe activity.
    @Published private(set) var activePhysicalIDs: Set<CGDirectDisplayID> = []

    /// Serial-number marker stamped on every mirror virtual ("MIRR"), alongside
    /// the shared 0xEEEE vendor stamp (which keeps every existing
    /// isVirtualDisplay filter treating these as virtual). Lets launch recovery
    /// recognize a stray mirror virtual left by a crash.
    static let mirrorSerialMarker: UInt32 = 0x4D49_5252

    /// Each stop becomes two CGVirtualDisplayMode declarations. Stay below the
    /// observed ~400-object applySettings ceiling with a little safety margin.
    private static let maximumVirtualStops = 190

    // MARK: - Queries

    func isActive(for physicalID: CGDirectDisplayID) -> Bool {
        active[physicalID] != nil
    }

    func virtualDisplayID(for physicalID: CGDirectDisplayID) -> CGDirectDisplayID? {
        active[physicalID]?.displayID
    }

    /// The looks-like size currently rendered for a mirrored physical display
    /// (read from the virtual master's active mode), or nil when not mirrored.
    func currentLooksLike(for physicalID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let vdID = active[physicalID]?.displayID,
              let cur = CGDisplayCopyDisplayMode(vdID) else { return nil }
        return (cur.width, cur.height)
    }

    // MARK: - Apply / Restore

    /// Puts `display` on a beyond-cap looks-like size: first call creates the
    /// mirror virtual and enables the mirror; subsequent calls only switch the
    /// virtual's mode. Returns false with everything unwound on failure, so a
    /// failed attempt never leaves a half-built mirror.
    @discardableResult
    func apply(display: DisplayInfo, width: Int, height: Int) async -> Bool {
        guard !display.isBuiltin else { return false }
        let physicalID = display.displayID
        guard await prepareIdentity(for: display) else { return false }

        return await enqueueOperation(for: physicalID) { [self] in
            await performApply(display: display, width: width, height: height)
        }
    }

    private func performApply(display: DisplayInfo, width: Int, height: Int) async -> Bool {
        let physicalID = display.displayID
        let identityKey = Self.mirrorIdentityKey(for: display)
        guard !deferredCleanupIdentityKeys.contains(identityKey) else {
            Self.log.error("apply \(width)x\(height): mandatory unmirror is still queued")
            return false
        }
        guard !deferredCreationIdentityKeys.contains(identityKey) else {
            Self.log.error("apply \(width)x\(height): virtual creation cleanup is still pending")
            return false
        }
        guard await confirmRetiredVirtual(for: physicalID) else {
            Self.log.error("apply \(width)x\(height): previous virtual is still online")
            return false
        }

        if let vdID = active[physicalID]?.displayID {
            let requested = PanelResolution(width: width, height: height)
            let isDeclared = declaredStops[physicalID]?.contains(requested) == true
            if isDeclared, await setLooksLike(width: width, height: height, on: vdID) {
                // Re-arm the mirror if something dropped it under us (a wake or a
                // WindowServer reset can collapse a mirror set without telling us).
                if CGDisplayMirrorsDisplay(physicalID) != vdID {
                    Self.log.info("apply \(width)x\(height): reused virtual \(vdID), re-arming mirror")
                    let enabled = await MirrorService.shared.enableMirror(
                        source: vdID, target: physicalID,
                        expectedTargetUUID: display.displayUUID)
                    if !enabled { _ = await performRestore(physicalID: physicalID) }
                    return enabled
                }
                Self.log.info("apply \(width)x\(height): reused virtual \(vdID)")
                return true
            }

            // A manual native-size correction, or movement outside a bounded
            // very-wide mode window, makes the old virtual's grid obsolete.
            // Tear it down and rebuild around the requested stop.
            Self.log.info("apply \(width)x\(height): rebuilding virtual \(vdID), requested stop declared: \(isDeclared)")
            guard await performRestore(physicalID: physicalID) else { return false }
        }

        // Retirement bookkeeping is process-local. A previous crashed process
        // can briefly leave the same stable virtual identity online, so verify
        // the authoritative display list immediately before constructing one.
        guard await confirmNoUntrackedVirtual(for: physicalID) else {
            Self.log.error("apply \(width)x\(height): matching mirror virtual is still online")
            return false
        }

        var pendingCreation = await createMirrorVirtual(
            for: display, mustInclude: (width, height))
        guard pendingCreation != nil else {
            Self.log.error("apply \(width)x\(height): createMirrorVirtual failed")
            // applySettings may have timed out while its serialized blocking
            // body continued. If it gave the virtual an ID, do not permit the
            // next attempt to reuse this monitor's stable identity until that
            // failed object has actually left WindowServer.
            _ = await confirmRetiredVirtual(for: physicalID)
            return false
        }
        let virtualID: CGDirectDisplayID
        do {
            // Limit the local strong reference to this scope. After assigning
            // `active`, that dictionary must be the sole owner so a failure
            // cleanup can actually destroy the display before confirming it.
            guard let created = pendingCreation else { return false }
            virtualID = created.display.displayID
            active[physicalID] = created.display
            declaredStops[physicalID] = created.stops
        }
        pendingCreation = nil
        activePhysicalIDs.insert(physicalID)

        guard await setLooksLike(width: width, height: height, on: virtualID) else {
            Self.log.error("apply \(width)x\(height): setLooksLike failed on fresh virtual \(virtualID)")
            _ = await performRestore(physicalID: physicalID)
            return false
        }
        guard await MirrorService.shared.enableMirror(source: virtualID,
                                                      target: physicalID,
                                                      expectedTargetUUID: display.displayUUID) else {
            Self.log.error("apply \(width)x\(height): enableMirror failed (virtual \(virtualID) -> physical \(physicalID))")
            _ = await performRestore(physicalID: physicalID)
            return false
        }
        Self.log.info("apply \(width)x\(height): mirrored physical \(physicalID) onto virtual \(virtualID)")
        return true
    }

    /// Leaves mirror mode: unmirrors the physical display, then destroys the
    /// virtual. The caller applies whatever real mode it wants afterwards.
    /// Order matters: destroying the master of a live mirror is undefined, so
    /// always unmirror first (the probe's verified-safe order).
    @discardableResult
    func restore(display: DisplayInfo) async -> Bool {
        guard await prepareIdentity(for: display) else { return false }
        return await restore(physicalID: display.displayID)
    }

    @discardableResult
    func restore(physicalID: CGDirectDisplayID) async -> Bool {
        if identityKeysByPhysicalID[physicalID] == nil,
           let virtualID = active[physicalID]?.displayID {
            identityKeysByPhysicalID[physicalID] = CGDisplayModelNumber(virtualID)
        }
        return await enqueueOperation(for: physicalID) { [self] in
            await performRestore(physicalID: physicalID)
        }
    }

    /// Changes the panel-resolution source only after any mirror virtual has
    /// been safely retired. The mutation and the ensuing detail reload stay in
    /// the same per-display operation, so an apply cannot race in between and
    /// rebuild from stale dimensions.
    @discardableResult
    func updatePanelResolution(
        for display: DisplayInfo,
        change: @escaping @MainActor () async -> Void
    ) async -> Bool {
        guard await prepareIdentity(for: display) else { return false }
        return await enqueueOperation(for: display.displayID) { [self] in
            guard await performRestore(physicalID: display.displayID) else { return false }
            await change()
            return true
        }
    }

    /// Runs a physical-display mode change after teardown, without allowing a
    /// new mirror apply to slip between those two steps.
    @discardableResult
    func withMirrorRestored(
        for display: DisplayInfo,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard await prepareIdentity(for: display) else { return false }
        return await enqueueOperation(for: display.displayID) { [self] in
            guard await performRestore(physicalID: display.displayID) else { return false }
            return await operation()
        }
    }

    private func performRestore(physicalID: CGDirectDisplayID) async -> Bool {
        guard let identityKey = identityKeysByPhysicalID[physicalID],
              !deferredCleanupIdentityKeys.contains(identityKey) else { return false }
        guard await confirmRetiredVirtual(for: physicalID) else { return false }
        guard let vdID = active[physicalID]?.displayID else { return true }
        guard let expectedTargetUUID = fingerprintsByPhysicalID[physicalID]?.uuid else {
            return false
        }
        Self.log.info("restore: unmirroring physical \(physicalID), destroying virtual \(vdID)")
        // Only a confirmed unmirror may let the virtual go. Mandatory teardown
        // waits for older timed-out transactions to drain before it runs, so a
        // late enable cannot escape this cleanup. If CG still refuses it and the
        // panel remains a target, keep the master alive for the next retry.
        deferredCleanupIdentityKeys.insert(identityKey)
        let disableResult = await MirrorService.shared.disableMirror(
            displayID: physicalID,
            expectedSource: vdID,
            expectedTargetUUID: expectedTargetUUID,
            lateCompletion: { [weak self] disabled in
                Task { @MainActor [weak self] in
                    await self?.finishDeferredRestore(
                        identityKey: identityKey, physicalID: physicalID,
                        virtualID: vdID, disabled: disabled)
                }
            })
        switch disableResult {
        case .timedOut:
            Self.log.error("restore: unmirror of physical \(physicalID) timed out; cleanup remains queued")
            return false
        case .completed(let disabled):
            deferredCleanupIdentityKeys.remove(identityKey)
            guard disabled else {
                Self.log.error("restore: unmirror of physical \(physicalID) failed (result \(disabled)), keeping virtual \(vdID)")
                return false
            }
        }

        guard beginVirtualRetirement(physicalID: physicalID, virtualID: vdID) else {
            Self.log.error("restore: unmirror of physical \(physicalID) failed, keeping virtual \(vdID)")
            return false
        }
        return await confirmRetiredVirtual(for: physicalID)
    }

    private func finishDeferredRestore(
        identityKey: UInt32,
        physicalID: CGDirectDisplayID,
        virtualID: CGDirectDisplayID,
        disabled: Bool
    ) async {
        guard deferredCleanupIdentityKeys.contains(identityKey) else { return }
        defer { deferredCleanupIdentityKeys.remove(identityKey) }

        guard disabled else {
            Self.log.error("restore: deferred unmirror of physical \(physicalID) failed (result \(disabled))")
            return
        }
        guard beginVirtualRetirement(physicalID: physicalID, virtualID: virtualID) else {
            return
        }
        _ = await confirmRetiredVirtual(for: physicalID)
    }

    private func beginVirtualRetirement(
        physicalID: CGDirectDisplayID,
        virtualID: CGDirectDisplayID
    ) -> Bool {
        guard active[physicalID]?.displayID == virtualID,
              let identityKey = identityKeysByPhysicalID[physicalID] else { return false }
        // Dropping the last strong reference starts WindowServer's async teardown.
        active.removeValue(forKey: physicalID)
        declaredStops.removeValue(forKey: physicalID)
        activePhysicalIDs.remove(physicalID)
        retiringVirtualIDs[identityKey] = virtualID
        return true
    }

    private func enqueueOperation(
        for physicalID: CGDirectDisplayID,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard let identityKey = identityKeysByPhysicalID[physicalID] else { return false }
        let previous = operationTails[identityKey]?.task
        let token = UUID()
        let task = Task { @MainActor in
            _ = await previous?.value
            guard await prepareQueuedState(for: physicalID, identityKey: identityKey) else {
                return false
            }
            return await operation()
        }
        operationTails[identityKey] = OperationTail(token: token, task: task)
        let result = await task.value
        if operationTails[identityKey]?.token == token {
            operationTails.removeValue(forKey: identityKey)
            // reconcile() deliberately leaves in-flight state alone. Re-read
            // the online set after the final queued operation so an unplug that
            // happened during an await cannot leave the virtual retained.
            if let online = currentOnlineDisplayIDs() {
                reconcile(online: online)
            }
        }
        return result
    }

    /// Keeps the bookkeeping truthful against the fresh online list (called from
    /// DisplayManager.refreshDisplays). Two cases matter: the mirrored physical
    /// was unplugged (nothing to unmirror anymore, dropping the entry lets the
    /// orphan virtual die), or our virtual died without us (WindowServer
    /// collapses the mirror set itself when a master disappears; dropping the
    /// stale entry makes the next slider move take the normal create path).
    /// Set-based rather than per removed ID because the mirror virtual is never
    /// in `DisplayManager.displays`, so its death never shows in that diff.
    func reconcile(online: Set<CGDirectDisplayID>) {
        for (physicalID, virtualDisplay) in active {
            let identityKey = identityKeysByPhysicalID[physicalID]
            guard identityKey.flatMap({ operationTails[$0] }) == nil else { continue }
            if online.contains(physicalID),
               let expected = fingerprintsByPhysicalID[physicalID],
               currentFingerprint(for: physicalID) != expected {
                // The numeric ID now names different hardware. Keep the master
                // alive and run the verified unmirror-first path asynchronously.
                Task { _ = await self.restore(physicalID: physicalID) }
                continue
            }
            guard !online.contains(physicalID)
                    || !online.contains(virtualDisplay.displayID) else { continue }
            if online.contains(virtualDisplay.displayID) {
                if let identityKey {
                    retiringVirtualIDs[identityKey] = virtualDisplay.displayID
                }
            }
            active.removeValue(forKey: physicalID)
            declaredStops.removeValue(forKey: physicalID)
            activePhysicalIDs.remove(physicalID)
            if let identityKey { deferredCleanupIdentityKeys.remove(identityKey) }
        }
        for (identityKey, virtualID) in retiringVirtualIDs where !online.contains(virtualID) {
            retiringVirtualIDs.removeValue(forKey: identityKey)
        }
    }

    /// A Crisp mirror virtual, ours or a stray from a crashed session: the shared
    /// vendor stamp plus the MIRR serial. DisplayManager keeps these out of
    /// `displays`, so no view, preset, or brightness path ever sees one.
    static func isMirrorVirtual(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == VirtualDisplayService.crispVirtualVendorID
            && CGDisplaySerialNumber(displayID) == mirrorSerialMarker
    }

    /// The looks-like sizes a display can only reach through mirror mode: every
    /// smooth-scaling grid step between the widest HiDPI mode WindowServer let
    /// the panel enumerate and native. Empty when the whole ladder enumerated
    /// (nothing is capped) and for the built-in panel. One definition for the
    /// slider, presets, and the virtual's mode list, so they can never disagree.
    static func beyondCapStops(for display: DisplayInfo) -> [(width: Int, height: Int)] {
        guard !display.isBuiltin else { return [] }
        let (nativeW, nativeH) = display.nativeResolution
        guard nativeW > 0, nativeH > 0 else { return [] }
        // ponytail: ultrawide-only (21:9 and wider) until a 16:9 4K or 5K panel is
        // verified with the mirror. Those are capped too (7680 and 10240 backings)
        // and would otherwise grow the same stops, untested. Drop this guard to widen.
        guard Double(nativeW) / Double(nativeH) >= 2.0 else { return [] }
        let hidpiTop = display.availableModes.filter { $0.isHiDPI }.map(\.width).max() ?? 0
        guard hidpiTop > 0 else { return [] }
        return HiDPIService.shared
            .smoothScaledLogicalSizes(
                nativeWidth: nativeW, nativeHeight: nativeH,
                enforcePlatformBackingLimit: false)
            .filter { $0.width > hidpiTop && $0.width < nativeW }
    }

    /// Frees any physical display left mirroring a STRAY Crisp mirror virtual
    /// (vendor stamp + MIRR serial) that this process does not own, i.e. one a
    /// crashed session left behind. We hold no object for it so we cannot
    /// destroy it, but unmirroring gives the panel its desktop back; the ghost
    /// display stays hidden from the UI by the vendor-stamp filters. Called on
    /// every refreshDisplays; a cheap no-op when nothing is stray.
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
            let targetUUID = Self.displayUUID(for: target)
            Task {
                await MirrorService.shared.disableMirror(
                    displayID: target, expectedSource: id,
                    expectedTargetUUID: targetUUID)
            }
        }
    }

    /// Quit-path teardown. applicationWillTerminate cannot await, so the
    /// unmirror runs as a direct synchronous transaction; a rare WindowServer
    /// hang at quit beats leaving the panel mirrored. (Process death would
    /// also collapse the mirror set, this just makes it orderly.)
    func teardownAll() {
        for physicalID in active.keys {
            guard let virtualID = active[physicalID]?.displayID,
                  let expectedUUID = fingerprintsByPhysicalID[physicalID]?.uuid,
                  Self.displayUUID(for: physicalID) == expectedUUID,
                  CGDisplayMirrorsDisplay(physicalID) == virtualID else { continue }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { continue }
            CGConfigureDisplayMirrorOfDisplay(cfg, physicalID, kCGNullDirectDisplay)
            if CGCompleteDisplayConfiguration(cfg, .forSession) != .success {
                CGCancelDisplayConfiguration(cfg)
            }
        }
        active.removeAll()
        declaredStops.removeAll()
        retiringVirtualIDs.removeAll()
        identityKeysByPhysicalID.removeAll()
        fingerprintsByPhysicalID.removeAll()
        deferredCleanupIdentityKeys.removeAll()
        deferredCreationIdentityKeys.removeAll()
        failedCreationObjects.removeAll()
        activePhysicalIDs.removeAll()
    }

    // MARK: - Creation

    /// Builds the mirror virtual for a physical display: stable identity (so
    /// macOS's "what do you want to show" picker appears at most once per
    /// monitor and its answer is remembered), the panel's physical size (sane
    /// PPI), and a backing + half-size mode PAIR for every beyond-cap stop.
    /// The pair is mandatory: backing-only declarations get WindowServer to
    /// mint enumerable looks-like twins, but those twins fail every apply
    /// (verified live on a 5K2K panel). One refresh rate keeps the dense
    /// ladder under the ~400-object ceiling where applySettings rejects the
    /// whole set.
    private struct CreatedMirror {
        let display: CGVirtualDisplay
        let stops: Set<PanelResolution>
    }

    private func createMirrorVirtual(for display: DisplayInfo,
                                     mustInclude: (width: Int, height: Int)) async -> CreatedMirror? {
        let (nativeW, nativeH) = display.nativeResolution
        guard nativeW > 0, nativeH > 0 else { return nil }

        // The new-display registration pops macOS's picker, which steals key
        // focus and would trip the panel's auto-dismiss; same suppression as
        // VirtualDisplayService.create.
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
        // Panel name plus a marker: system UI lists the virtual while
        // mirrored (Control Center, the first-run Extend picker), and a
        // distinct name reads as a feature where a duplicate "Name (2)"
        // reads as a glitch.
        descriptor.name = String(localized: "\(display.name) (Crisp)")
        descriptor.vendorID = VirtualDisplayService.crispVirtualVendorID
        // Stable per monitor; the serial carries the mirror marker. Two
        // identical monitors mirroring at once would collide, accepted edge.
        let panelIdentity = Self.mirrorIdentityKey(for: display)
        descriptor.productID = panelIdentity
        descriptor.serialNum = Self.mirrorSerialMarker

        // Every beyond-cap stop on the smooth-scaling grid, in the same
        // (rotated) space as availableModes and the slider; the requested size
        // is force-included in case it sits off that grid.
        let required = PanelResolution(width: mustInclude.width, height: mustInclude.height)
        let candidates = Self.beyondCapStops(for: display).map {
            PanelResolution(width: $0.width, height: $0.height)
        }
        let stops = MirrorModeGeometry.boundedStops(
            candidates, including: required, maximumCount: Self.maximumVirtualStops)

        // One rate only (the panel's own, 60 when unreadable): every stop costs
        // TWO mode objects below, and a second rate would put a dense ladder
        // past the ~400-object ceiling where applySettings rejects the set.
        let panelRate = display.currentDisplayMode?.refreshRate ?? 60
        let rate: Double = panelRate > 0 ? panelRate : 60

        // Declare BOTH the 2x backing and the half-size pixel mode per stop
        // (the probe's recipe). Backing-only declarations look sufficient,
        // WindowServer mints enumerable looks-like twins for them, but those
        // twins refuse to apply: CGConfigureDisplayWithDisplayMode fails on
        // every attempt (found live on a 5K2K panel, 2026-08-25). Only the
        // declared pair yields a twin that can actually become current.
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
        // apply blocks on WindowServer IPC; off-main with a timeout like every
        // CG transaction (same as VirtualDisplayService.create).
        let vd = virtualDisplay
        let s = settings
        deferredCreationIdentityKeys.insert(panelIdentity)
        let applyResult = await CGHelpers.runMandatoryWithTimeout(
            seconds: 10,
            operation: { vd.apply(s) },
            lateCompletion: { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stageFailedCreation(
                        identityKey: panelIdentity, virtualDisplay: vd)
                }
            })
        guard case .completed(let applied) = applyResult else {
            Self.log.error("createMirrorVirtual: applySettings timed out; identity lease retained")
            return nil
        }
        guard applied, virtualDisplay.displayID != kCGNullDirectDisplay else {
            Self.log.error("createMirrorVirtual: applySettings \(applied ? "ok but null displayID" : "failed") (\(modes.count) modes)")
            stageFailedCreation(identityKey: panelIdentity, virtualDisplay: virtualDisplay)
            return nil
        }
        deferredCreationIdentityKeys.remove(panelIdentity)
        Self.log.info("createMirrorVirtual: virtual \(virtualDisplay.displayID) up, \(modes.count) modes declared")
        return CreatedMirror(display: virtualDisplay, stops: Set(stops))
    }

    // MARK: - Helpers

    /// Drives the virtual display to the looks-like HiDPI mode, retrying while
    /// WindowServer finishes enumerating the fresh display. Prefers the highest
    /// refresh rate offered at that size (the panel's own rate when kept).
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

    /// Waits (bounded) for a torn-down virtual display to leave the online
    /// list; same event-driven pattern as VirtualDisplayService, duplicated
    /// because both keep it private to their own teardown story.
    private func confirmRetiredVirtual(for physicalID: CGDirectDisplayID) async -> Bool {
        guard let identityKey = identityKeysByPhysicalID[physicalID],
              let virtualID = retiringVirtualIDs[identityKey] else { return true }
        guard await waitForDisplayOffline(virtualID) else {
            Self.log.error("restore: virtual \(virtualID) is still online; refusing stable-identity reuse")
            return false
        }
        retiringVirtualIDs.removeValue(forKey: identityKey)
        return true
    }

    private func stageFailedCreation(
        identityKey: UInt32,
        virtualDisplay: CGVirtualDisplay
    ) {
        guard deferredCreationIdentityKeys.contains(identityKey) else { return }
        failedCreationObjects[identityKey] = virtualDisplay
        Task { @MainActor [weak self] in
            await self?.settleFailedCreation(identityKey: identityKey)
        }
    }

    private func settleFailedCreation(identityKey: UInt32) async {
        guard deferredCreationIdentityKeys.contains(identityKey) else { return }

        // apply(_:) can return before WindowServer publishes displayID. Hold the
        // object and lease through a bounded registration window.
        var virtualID = kCGNullDirectDisplay
        for _ in 0..<15 {
            virtualID = failedCreationObjects[identityKey]?.displayID ?? kCGNullDirectDisplay
            if virtualID != kCGNullDirectDisplay { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if virtualID != kCGNullDirectDisplay {
            retiringVirtualIDs[identityKey] = virtualID
        }

        // Explicitly release the failed display, then rescan its stable
        // descriptor identity in case registration raced the last ID sample.
        failedCreationObjects.removeValue(forKey: identityKey)
        await Task.yield()
        if virtualID == kCGNullDirectDisplay {
            for _ in 0..<15 {
                let scan = matchingOnlineMirrorVirtual(identityKey: identityKey)
                if let conflict = scan.displayID {
                    virtualID = conflict
                    retiringVirtualIDs[identityKey] = conflict
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if virtualID == kCGNullDirectDisplay {
                // Only a successful scan at the END of the settle window can
                // prove that a late registration did not appear. An earlier
                // empty result becomes stale if the trailing queries fail.
                let finalScan = matchingOnlineMirrorVirtual(identityKey: identityKey)
                if let conflict = finalScan.displayID {
                    virtualID = conflict
                    retiringVirtualIDs[identityKey] = conflict
                } else if !finalScan.succeeded {
                    Self.log.error("createMirrorVirtual: final online rescan failed; identity lease retained")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self?.settleFailedCreation(identityKey: identityKey)
                    }
                    return
                }
            }
        }

        deferredCreationIdentityKeys.remove(identityKey)
        guard virtualID != kCGNullDirectDisplay else { return }
        guard await waitForDisplayOffline(virtualID) else {
            Self.log.error("createMirrorVirtual: failed virtual \(virtualID) remains online")
            return
        }
        if retiringVirtualIDs[identityKey] == virtualID {
            retiringVirtualIDs.removeValue(forKey: identityKey)
        }
    }

    private func matchingOnlineMirrorVirtual(
        identityKey: UInt32
    ) -> (succeeded: Bool, displayID: CGDirectDisplayID?) {
        guard let online = currentOnlineDisplayIDs() else { return (false, nil) }
        let conflict = online.first { candidate in
            Self.isMirrorVirtual(candidate) && CGDisplayModelNumber(candidate) == identityKey
                && !active.values.contains(where: { $0.displayID == candidate })
        }
        return (true, conflict)
    }

    private func confirmNoUntrackedVirtual(for physicalID: CGDirectDisplayID) async -> Bool {
        guard let identityKey = identityKeysByPhysicalID[physicalID] else { return false }
        guard !deferredCreationIdentityKeys.contains(identityKey) else { return false }
        while true {
            guard let online = currentOnlineDisplayIDs() else { return false }
            let currentPhysicalVirtualID = active[physicalID]?.displayID
            let conflicts = online.filter {
                $0 != currentPhysicalVirtualID
                    && Self.isMirrorVirtual($0)
                    && CGDisplayModelNumber($0) == identityKey
            }
            guard let conflict = conflicts.first else { return true }

            // Another physical panel with the same descriptor identity may own
            // one of these virtuals. Reject without poisoning its retirement
            // record; its owner must remain able to restore itself.
            if conflicts.contains(where: { conflictID in
                active.values.contains(where: { $0.displayID == conflictID })
            }) {
                Self.log.error("createMirrorVirtual: identity \(identityKey) is owned by another active virtual")
                return false
            }

            retiringVirtualIDs[identityKey] = conflict
            guard await confirmRetiredVirtual(for: physicalID) else { return false }
            // Re-read the authoritative list: more than one crash stray can
            // share the same descriptor identity.
        }
    }

    private static func mirrorIdentityKey(for display: DisplayInfo) -> UInt32 {
        let panelIdentity = display.vendorNumber ^ display.modelNumber
        return panelIdentity != 0 ? panelIdentity : 0x4D52
    }

    private func prepareIdentity(for display: DisplayInfo) async -> Bool {
        let physicalID = display.displayID
        let fingerprint = Self.fingerprint(for: display)
        guard currentFingerprint(for: physicalID) == fingerprint else {
            Self.log.error("operation rejected: physical ID \(physicalID) now names different hardware")
            return false
        }

        if let previousFingerprint = fingerprintsByPhysicalID[physicalID],
           previousFingerprint != fingerprint {
            guard identityKeysByPhysicalID[physicalID] != nil else { return false }
            let cleaned = await enqueueOperation(for: physicalID) { [self] in
                await performRestore(physicalID: physicalID)
            }
            guard cleaned else { return false }
        }

        identityKeysByPhysicalID[physicalID] = Self.mirrorIdentityKey(for: display)
        fingerprintsByPhysicalID[physicalID] = fingerprint
        return true
    }

    private static func fingerprint(for display: DisplayInfo) -> PhysicalFingerprint {
        PhysicalFingerprint(vendor: display.vendorNumber, model: display.modelNumber,
                            serial: display.serialNumber, uuid: display.displayUUID)
    }

    private func currentFingerprint(for physicalID: CGDirectDisplayID) -> PhysicalFingerprint {
        PhysicalFingerprint(vendor: CGDisplayVendorNumber(physicalID),
                            model: CGDisplayModelNumber(physicalID),
                            serial: CGDisplaySerialNumber(physicalID),
                            uuid: Self.displayUUID(for: physicalID))
    }

    private func prepareQueuedState(
        for physicalID: CGDirectDisplayID,
        identityKey: UInt32
    ) async -> Bool {
        guard let online = currentOnlineDisplayIDs() else { return false }
        for (storedID, _) in active
        where identityKeysByPhysicalID[storedID] == identityKey {
            let storedPanelStillLive = online.contains(storedID)
                && fingerprintsByPhysicalID[storedID] == currentFingerprint(for: storedID)
            // A distinct, still-live identical panel is a real identity-key
            // collision. Leave its mirror alone; the conflict scan will reject
            // creating a second descriptor with that key.
            if storedPanelStillLive { continue }
            if !(await performRestore(physicalID: storedID)) {
                return false
            }
        }
        return true
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        if let cf = CGDisplayCreateUUIDFromDisplayID(displayID),
           let value = CFUUIDCreateString(nil, cf.takeRetainedValue()) {
            return value as String
        }
        return "v\(CGDisplayVendorNumber(displayID))-m\(CGDisplayModelNumber(displayID))"
            + "-s\(CGDisplaySerialNumber(displayID))"
    }

    private func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        // A failed query is not evidence of removal; conservatively retain the
        // identity and let a later callback/retry confirm it.
        currentOnlineDisplayIDs()?.contains(displayID) ?? true
    }

    private func currentOnlineDisplayIDs() -> Set<CGDirectDisplayID>? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Set(ids.prefix(Int(count)))
    }

    /// The remove event is only a wake-up hint: always re-read the authoritative
    /// online list before allowing the stable identity to be created again.
    private func waitForDisplayOffline(_ displayID: CGDirectDisplayID) async -> Bool {
        guard isDisplayOnline(displayID) else { return true }
        await ReconfigEvents.shared.next(for: displayID, matching: .removeFlag, timeout: 1.5)
        return !isDisplayOnline(displayID)
    }
}
