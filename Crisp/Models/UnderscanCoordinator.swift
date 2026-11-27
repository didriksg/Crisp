import CoreGraphics
import Foundation

/// Timing and retry budgets for `UnderscanCoordinator`.
/// Production uses conservative WindowServer stabilization delays; unit tests inject
/// millisecond-scale values for fast, deterministic verification.
struct UnderscanTiming: Equatable, Sendable {
    let sliderThrottleNs: UInt64
    let startupStabilizeNs: UInt64
    let wakeStabilizeNs: UInt64
    let reconnectStabilizeNs: UInt64
    let modeChangeStabilizeNs: UInt64
    let retryDelaysNs: [UInt64]
    let maxConsecutiveFailuresBeforeSuspend: Int
    let selfApplySuppressionSeconds: TimeInterval
    let rollbackTimeoutSeconds: Int
    let rollbackTickNs: UInt64

    static let production = UnderscanTiming(
        sliderThrottleNs: 90_000_000,
        startupStabilizeNs: 1_200_000_000,
        wakeStabilizeNs: 1_500_000_000,
        reconnectStabilizeNs: 1_200_000_000,
        modeChangeStabilizeNs: 600_000_000,
        retryDelaysNs: [800_000_000, 1_800_000_000],
        maxConsecutiveFailuresBeforeSuspend: 3,
        selfApplySuppressionSeconds: 0.8,
        rollbackTimeoutSeconds: 12,
        rollbackTickNs: 1_000_000_000
    )

    func stabilizeDelayNs(for trigger: UnderscanRestoreTrigger) -> UInt64 {
        switch trigger {
        case .startup: return startupStabilizeNs
        case .wake: return wakeStabilizeNs
        case .reconnect, .displayConfigChange: return reconnectStabilizeNs
        case .resolutionChange, .refreshRateChange: return modeChangeStabilizeNs
        }
    }
}

/// Testable, MainActor-isolated coordinator managing underscan capability probing,
/// throttled slider application, per-display persistence, event-driven restoration,
/// bounded retries, automatic suspension, and fail-safe rollback.
@MainActor
final class UnderscanCoordinator: ObservableObject {
    @Published private(set) var statesByKey: [String: UnderscanDisplayState] = [:]

    private let backend: any UnderscanBackend
    private let store: UnderscanStore
    private let timing: UnderscanTiming
    private let isDisplayOnline: @Sendable (CGDirectDisplayID) -> Bool
    private let now: () -> Date

    /// Serializes per-display applies so rapid/concurrent slider moves cannot race out of order.
    private var applyGeneration: [String: UInt64] = [:]
    private var sliderThrottleTasks: [String: Task<Void, Never>] = [:]
    private var restoreTasks: [String: Task<Void, Never>] = [:]
    private var rollbackTasks: [String: Task<Void, Never>] = [:]
    private var activeKeyByDisplayID: [CGDirectDisplayID: String] = [:]
    private var lastSelfApplyAt: [String: Date] = [:]
    private var didRunLegacyMigration = false

    init(
        backend: any UnderscanBackend,
        store: UnderscanStore = UnderscanStore(),
        timing: UnderscanTiming = .production,
        isDisplayOnline: @escaping @Sendable (CGDirectDisplayID) -> Bool = { CGDisplayIsOnline($0) != 0 },
        now: @escaping () -> Date = Date.init
    ) {
        self.backend = backend
        self.store = store
        self.timing = timing
        self.isDisplayOnline = isDisplayOnline
        self.now = now
    }

    // MARK: - Key & State Access

    func stableKey(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) -> String {
        DisplayUnderscanIdentity.stableKey(for: display, among: allLive)
    }

    func state(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) -> UnderscanDisplayState {
        let key = stableKey(for: display, among: allLive)
        if let existing = statesByKey[key], existing.displayID == display.displayID {
            return existing
        }
        return buildState(
            for: display,
            key: key,
            existing: statesByKey[key],
            capabilityOverride: nonBlockingFallbackCapability(for: display)
        )
    }

    /// Refreshes capability and persisted settings for all live displays without mutating hardware.
    func refreshDisplays(_ liveDisplays: [DisplayUnderscanDescriptor]) async {
        if !didRunLegacyMigration, !liveDisplays.isEmpty {
            store.migrateLegacyDisplayIDEntries(for: liveDisplays)
            didRunLegacyMigration = true
        }

        let liveIDs = Set(liveDisplays.map(\.displayID))
        let disappearedIDs = Set(activeKeyByDisplayID.keys).subtracting(liveIDs)
        for id in disappearedIDs {
            handleDisplayDisconnected(displayID: id)
        }

        for display in liveDisplays {
            let key = stableKey(for: display, among: liveDisplays)
            activeKeyByDisplayID[display.displayID] = key
            let cap = await probeCapabilityOffMain(for: display)
            let updated = buildState(for: display, key: key, existing: statesByKey[key], capabilityOverride: cap)
            statesByKey[key] = updated
        }
    }

    /// Probes one display and updates its cached state.
    @discardableResult
    func refreshDisplay(
        _ display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) async -> UnderscanDisplayState {
        if !didRunLegacyMigration, !allLive.isEmpty {
            store.migrateLegacyDisplayIDEntries(for: allLive)
            didRunLegacyMigration = true
        }
        let key = stableKey(for: display, among: allLive)
        activeKeyByDisplayID[display.displayID] = key
        let cap = await probeCapabilityOffMain(for: display)
        let updated = buildState(for: display, key: key, existing: statesByKey[key], capabilityOverride: cap)
        statesByKey[key] = updated
        return updated
    }

    // MARK: - User Actions & Slider Control

    /// Updates a display's requested underscan percentage from slider input.
    /// When `commitImmediately` is false (mid-drag), paces native writes via `sliderThrottleNs`.
    func setSliderPercentage(
        _ percentage: Int,
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor],
        commitImmediately: Bool
    ) {
        let key = stableKey(for: display, among: allLive)
        activeKeyByDisplayID[display.displayID] = key
        var current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)

        // Cancel outdated background restore or older throttle task whenever the user takes control.
        cancelRestoreTask(forKey: key)
        sliderThrottleTasks[key]?.cancel()
        sliderThrottleTasks[key] = nil

        let range = current.capability.percentageRange
        if case .failure(let error) = UnderscanValue.validatePercentage(percentage, allowedRange: range) {
            current.status = .failed(error)
            statesByKey[key] = current
            return
        }

        current.requestedPercentage = percentage
        if percentage < UnderscanValue.defaultPercentage {
            current.settings.isEnabled = true
        }
        if current.settings.rememberValue {
            current.settings.requestedPercentage = percentage
            store.save(current.settings, forKey: key)
        }
        statesByKey[key] = current

        let generation = nextGeneration(forKey: key)
        if commitImmediately {
            Task { @MainActor [weak self] in
                await self?.performUserApply(
                    percentage: percentage,
                    for: display,
                    key: key,
                    generation: generation,
                    triggerRollbackIfExperimental: true
                )
            }
        } else {
            let throttleNs = timing.sliderThrottleNs
            sliderThrottleTasks[key] = Task { @MainActor [weak self] in
                if throttleNs > 0 {
                    try? await Task.sleep(nanoseconds: throttleNs)
                }
                guard let self, !Task.isCancelled else { return }
                await self.performUserApply(
                    percentage: percentage,
                    for: display,
                    key: key,
                    generation: generation,
                    triggerRollbackIfExperimental: false
                )
            }
        }
    }

    /// Directly applies a validated percentage and returns the outcome (useful for buttons & tests).
    @discardableResult
    func applyPercentage(
        _ percentage: Int,
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor],
        triggerRollbackIfExperimental: Bool = true
    ) async -> Result<UnderscanApplyOutcome, UnderscanError> {
        let key = stableKey(for: display, among: allLive)
        activeKeyByDisplayID[display.displayID] = key
        cancelRestoreTask(forKey: key)
        sliderThrottleTasks[key]?.cancel()
        sliderThrottleTasks[key] = nil

        let current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        var updated = current
        if case .failure(let error) = UnderscanValue.validatePercentage(percentage, allowedRange: current.capability.percentageRange) {
            updated.status = .failed(error)
            statesByKey[key] = updated
            return .failure(error)
        }
        updated.requestedPercentage = percentage
        if percentage < UnderscanValue.defaultPercentage {
            updated.settings.isEnabled = true
        }
        if updated.settings.rememberValue {
            updated.settings.requestedPercentage = percentage
            store.save(updated.settings, forKey: key)
        }
        statesByKey[key] = updated

        let generation = nextGeneration(forKey: key)
        return await performUserApply(
            percentage: percentage,
            for: display,
            key: key,
            generation: generation,
            triggerRollbackIfExperimental: triggerRollbackIfExperimental
        )
    }

    /// Resets underscan to 100% (full desktop area) for a single display.
    @discardableResult
    func resetToFullScreen(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) async -> Result<UnderscanApplyOutcome, UnderscanError> {
        let key = stableKey(for: display, among: allLive)
        activeKeyByDisplayID[display.displayID] = key
        cancelAllTasks(forKey: key)

        var current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        current.pendingRollback = nil
        current.requestedPercentage = UnderscanValue.defaultPercentage
        current.settings.requestedPercentage = UnderscanValue.defaultPercentage
        current.settings.lastKnownGoodPercentage = UnderscanValue.defaultPercentage
        current.settings.autoRestoreSuspended = false
        current.settings.consecutiveRestoreFailures = 0
        statesByKey[key] = current

        let generation = nextGeneration(forKey: key)
        let result = await submitToBackend(
            percentage: UnderscanValue.defaultPercentage,
            for: display,
            key: key,
            generation: generation,
            allowExperimental: current.settings.forceEnableExperimental
        )

        var after = statesByKey[key] ?? current
        switch result {
        case .success(let outcome):
            after.lastSubmittedPercentage = outcome.submittedPercentage
            after.hardwareConfirmedPercentage = outcome.confirmedPercentage
            after.status = .resetToFullScreen
            after.settings.lastApplicationStatus = UnderscanApplyStatus.resetToFullScreen.persistedSummary
        case .failure(let error):
            after.status = .failed(error)
            after.settings.lastApplicationStatus = UnderscanApplyStatus.failed(error).persistedSummary
        }
        store.save(after.settings, forKey: key)
        statesByKey[key] = after
        return result
    }

    /// Disables underscan for one display, stops automatic restoration, and resets to 100%
    /// when underscan was active.
    func disableUnderscan(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) async {
        let key = stableKey(for: display, among: allLive)
        cancelAllTasks(forKey: key)

        var current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        let needsHardwareReset = current.isControlUsable
            && (current.requestedPercentage < UnderscanValue.defaultPercentage
                || (current.lastSubmittedPercentage ?? UnderscanValue.defaultPercentage) < UnderscanValue.defaultPercentage
                || (current.hardwareConfirmedPercentage ?? UnderscanValue.defaultPercentage) < UnderscanValue.defaultPercentage)

        current.pendingRollback = nil
        current.settings.isEnabled = false
        current.settings.autoRestoreSuspended = false
        current.settings.consecutiveRestoreFailures = 0
        if !current.settings.rememberValue {
            current.settings.requestedPercentage = UnderscanValue.defaultPercentage
        }
        store.save(current.settings, forKey: key)
        statesByKey[key] = current

        if needsHardwareReset {
            let generation = nextGeneration(forKey: key)
            let result = await submitToBackend(
                percentage: UnderscanValue.defaultPercentage,
                for: display,
                key: key,
                generation: generation,
                allowExperimental: current.settings.forceEnableExperimental
            )
            var after = statesByKey[key] ?? current
            if case .success(let outcome) = result {
                after.lastSubmittedPercentage = outcome.submittedPercentage
                after.hardwareConfirmedPercentage = outcome.confirmedPercentage
                after.status = .resetToFullScreen
                after.settings.lastApplicationStatus = UnderscanApplyStatus.resetToFullScreen.persistedSummary
                store.save(after.settings, forKey: key)
                statesByKey[key] = after
            }
        }
    }

    /// Global recovery action: cancels all tasks, resets all active displays back to 100%
    /// where possible, and disables underscan settings across every stored monitor.
    func disableAllUnderscan(liveDisplays: [DisplayUnderscanDescriptor]) async {
        for key in Array(restoreTasks.keys) { cancelRestoreTask(forKey: key) }
        for key in Array(sliderThrottleTasks.keys) {
            sliderThrottleTasks[key]?.cancel()
            sliderThrottleTasks[key] = nil
        }
        for key in Array(rollbackTasks.keys) {
            rollbackTasks[key]?.cancel()
            rollbackTasks[key] = nil
        }

        for display in liveDisplays where !display.isBuiltin && !display.isVirtual {
            let key = stableKey(for: display, among: liveDisplays)
            let state = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
            if state.isControlUsable {
                let generation = nextGeneration(forKey: key)
                _ = await submitToBackend(
                    percentage: UnderscanValue.defaultPercentage,
                    for: display,
                    key: key,
                    generation: generation,
                    allowExperimental: state.settings.forceEnableExperimental
                )
            }
        }

        store.disableAllSettings()

        for display in liveDisplays {
            let key = stableKey(for: display, among: liveDisplays)
            var refreshed = buildState(for: display, key: key, existing: statesByKey[key])
            refreshed.requestedPercentage = UnderscanValue.defaultPercentage
            refreshed.pendingRollback = nil
            refreshed.status = .resetToFullScreen
            if refreshed.isControlUsable {
                refreshed.lastSubmittedPercentage = UnderscanValue.defaultPercentage
            }
            statesByKey[key] = refreshed
        }
    }

    // MARK: - Settings Mutations

    func updateSettings(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor],
        mutate: (inout DisplayUnderscanSettings) -> Void
    ) {
        let key = stableKey(for: display, among: allLive)
        activeKeyByDisplayID[display.displayID] = key
        var current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        let previousEnabled = current.settings.isEnabled
        let previousForce = current.settings.forceEnableExperimental

        mutate(&current.settings)

        // Built-in and virtual displays can never enable experimental forced underscan.
        if display.isBuiltin || display.isVirtual {
            current.settings.forceEnableExperimental = false
            current.settings.isEnabled = false
        }

        // Turning off force-enable clears experimental confirmation state and active rollback.
        if previousForce && !current.settings.forceEnableExperimental {
            cancelRollbackTask(forKey: key)
            current.pendingRollback = nil
        }

        // Changing settings cancels any outdated in-flight restore.
        cancelRestoreTask(forKey: key)
        store.save(current.settings, forKey: key)
        statesByKey[key] = current

        // Re-enabling with a remembered percentage < 100 applies it if ready.
        if !previousEnabled && current.settings.isEnabled
            && current.requestedPercentage < UnderscanValue.defaultPercentage
            && current.isControlUsable {
            let needsConfirm = !current.capability.isNativelySupported
                && current.settings.forceEnableExperimental
                && !current.settings.hasConfirmedExperimentalRisk
            if !needsConfirm {
                let target = current.requestedPercentage
                Task { @MainActor [weak self] in
                    _ = await self?.applyPercentage(
                        target,
                        for: display,
                        among: allLive,
                        triggerRollbackIfExperimental: true
                    )
                }
            }
        }
    }

    /// Explicit user confirmation gate before the first experimental forced hardware test.
    func confirmExperimentalRisk(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) {
        updateSettings(for: display, among: allLive) { settings in
            settings.hasConfirmedExperimentalRisk = true
        }
    }

    /// User accepted the experimental underscan value during the rollback countdown.
    func keepExperimentalChange(forKey key: String) {
        cancelRollbackTask(forKey: key)
        guard var current = statesByKey[key], let rollback = current.pendingRollback else { return }
        current.pendingRollback = nil
        current.settings.lastKnownGoodPercentage = rollback.testedPercentage
        current.settings.hasConfirmedExperimentalRisk = true
        store.save(current.settings, forKey: key)
        statesByKey[key] = current
    }

    /// Reverts an unconfirmed experimental underscan test back to the previous known-good value.
    func revertExperimentalChange(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) async {
        let key = stableKey(for: display, among: allLive)
        await revertExperimentalChange(for: display, key: key)
    }

    private func revertExperimentalChange(
        for display: DisplayUnderscanDescriptor,
        key: String
    ) async {
        cancelRollbackTask(forKey: key)
        guard var current = statesByKey[key] else { return }
        let restorePct = current.pendingRollback?.previousKnownGoodPercentage
            ?? current.settings.lastKnownGoodPercentage
        current.pendingRollback = nil
        current.requestedPercentage = restorePct
        current.settings.requestedPercentage = restorePct
        if restorePct == UnderscanValue.defaultPercentage {
            current.settings.isEnabled = false
        }
        store.save(current.settings, forKey: key)
        statesByKey[key] = current

        let generation = nextGeneration(forKey: key)
        let result = await submitToBackend(
            percentage: restorePct,
            for: display,
            key: key,
            generation: generation,
            allowExperimental: current.settings.forceEnableExperimental
        )
        var after = statesByKey[key] ?? current
        switch result {
        case .success(let outcome):
            after.lastSubmittedPercentage = outcome.submittedPercentage
            after.hardwareConfirmedPercentage = outcome.confirmedPercentage
            after.status = restorePct == UnderscanValue.defaultPercentage
                ? .resetToFullScreen
                : (outcome.confirmedPercentage.map { .appliedConfirmed($0) }
                    ?? .submittedUnconfirmed(outcome.submittedPercentage))
        case .failure(let error):
            after.status = .failed(error)
        }
        after.settings.lastApplicationStatus = after.status.persistedSummary
        store.save(after.settings, forKey: key)
        statesByKey[key] = after
    }

    /// Recovery action after automatic restoration has been suspended due to repeated failures.
    func resumeAutoRestore(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) {
        let key = stableKey(for: display, among: allLive)
        var current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        current.settings.autoRestoreSuspended = false
        current.settings.consecutiveRestoreFailures = 0
        current.status = .idle
        store.save(current.settings, forKey: key)
        statesByKey[key] = current

        scheduleRestore(for: display, among: allLive, trigger: .reconnect)
    }

    // MARK: - Event-Driven Automatic Restoration

    /// Cancels all pending operations for a disconnected display so stale tasks cannot
    /// target a recycled `CGDirectDisplayID`.
    func handleDisplayDisconnected(displayID: CGDirectDisplayID) {
        guard let key = activeKeyByDisplayID.removeValue(forKey: displayID) else { return }
        cancelAllTasks(forKey: key)
        if var state = statesByKey[key] {
            state.isApplying = false
            state.pendingRollback = nil
            statesByKey[key] = state
        }
    }

    /// Schedules a debounced, stabilized, bounded-retry restoration for `display`.
    @discardableResult
    func scheduleRestore(
        for display: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor],
        trigger: UnderscanRestoreTrigger
    ) -> Task<Void, Never>? {
        guard !display.isBuiltin, !display.isVirtual else { return nil }
        let key = stableKey(for: display, among: allLive)
        activeKeyByDisplayID[display.displayID] = key

        let settings = store.settings(forKey: key)
        guard settings.shouldRestore(for: trigger) else { return nil }

        // Never auto-apply unconfirmed experimental settings on startup to prevent boot/launch loops.
        if settings.forceEnableExperimental && !settings.hasConfirmedExperimentalRisk {
            return nil
        }

        // Prevent feedback loops from reconfiguration events triggered by our own underscan apply.
        if trigger == .resolutionChange || trigger == .refreshRateChange || trigger == .displayConfigChange,
           let lastSelf = lastSelfApplyAt[key],
           now().timeIntervalSince(lastSelf) < timing.selfApplySuppressionSeconds {
            return nil
        }

        cancelRestoreTask(forKey: key)
        let targetPercentage = settings.requestedPercentage
        let stabilizeNs = timing.stabilizeDelayNs(for: trigger)
        let generation = nextGeneration(forKey: key)

        let task = Task { @MainActor [weak self] in
            if stabilizeNs > 0 {
                try? await Task.sleep(nanoseconds: stabilizeNs)
            }
            guard let self, !Task.isCancelled else { return }
            await self.runBoundedRestore(
                display: display,
                key: key,
                targetPercentage: targetPercentage,
                trigger: trigger,
                generation: generation
            )
        }
        restoreTasks[key] = task
        return task
    }

    /// Schedules restoration for all eligible live displays on a global event (startup, wake).
    func scheduleRestoreAll(
        liveDisplays: [DisplayUnderscanDescriptor],
        trigger: UnderscanRestoreTrigger
    ) {
        if !didRunLegacyMigration, !liveDisplays.isEmpty {
            store.migrateLegacyDisplayIDEntries(for: liveDisplays)
            didRunLegacyMigration = true
        }
        for display in liveDisplays {
            _ = scheduleRestore(for: display, among: liveDisplays, trigger: trigger)
        }
    }

    // MARK: - Internal Execution

    private func runBoundedRestore(
        display: DisplayUnderscanDescriptor,
        key: String,
        targetPercentage: Int,
        trigger: UnderscanRestoreTrigger,
        generation: UInt64
    ) async {
        defer {
            if applyGeneration[key] == generation {
                restoreTasks[key] = nil
            }
        }

        let maxAttempts = 1 + timing.retryDelaysNs.count
        var lastError: UnderscanError = .applyFailed(String(localized: "Underscan restore did not complete."))

        for attempt in 0..<maxAttempts {
            guard !Task.isCancelled, applyGeneration[key] == generation else { return }
            guard isDisplayOnline(display.displayID) else { return }

            let liveSettings = store.settings(forKey: key)
            guard liveSettings.shouldRestore(for: trigger),
                  liveSettings.requestedPercentage == targetPercentage else {
                return
            }

            let capability = await probeCapabilityOffMain(for: display)
            guard !Task.isCancelled, applyGeneration[key] == generation else { return }
            var current = buildState(for: display, key: key, existing: statesByKey[key], capabilityOverride: capability)

            // Skip if hardware readback already confirms the target percentage.
            if let confirmed = capability.hardwareConfirmedPercentage,
               confirmed == targetPercentage {
                current.lastSubmittedPercentage = targetPercentage
                current.hardwareConfirmedPercentage = confirmed
                current.status = .appliedConfirmed(confirmed)
                current.settings.consecutiveRestoreFailures = 0
                current.settings.lastApplicationStatus = current.status.persistedSummary
                store.save(current.settings, forKey: key)
                statesByKey[key] = current
                return
            }

            // Refuse experimental auto-restore if experimental mode isn't confirmed or display isn't eligible.
            let useExperimental = !capability.isNativelySupported && liveSettings.forceEnableExperimental
            if useExperimental && (!capability.canUseWithExperimentalForce || !liveSettings.hasConfirmedExperimentalRisk) {
                lastError = .experimentalConfirmationRequired
                break
            }

            let result = await submitToBackend(
                percentage: targetPercentage,
                for: display,
                key: key,
                generation: generation,
                allowExperimental: useExperimental
            )

            guard !Task.isCancelled, applyGeneration[key] == generation else { return }

            switch result {
            case .success(let outcome):
                var after = statesByKey[key] ?? current
                after.capability = capability
                after.lastSubmittedPercentage = outcome.submittedPercentage
                after.hardwareConfirmedPercentage = outcome.confirmedPercentage
                after.status = outcome.confirmedPercentage.map { .appliedConfirmed($0) }
                    ?? .submittedUnconfirmed(outcome.submittedPercentage)
                after.settings.consecutiveRestoreFailures = 0
                after.settings.autoRestoreSuspended = false
                after.settings.lastKnownGoodPercentage = targetPercentage
                after.settings.lastApplicationStatus = after.status.persistedSummary
                store.save(after.settings, forKey: key)
                statesByKey[key] = after
                return
            case .failure(let error):
                lastError = error
                if attempt < timing.retryDelaysNs.count {
                    let backoffNs = timing.retryDelaysNs[attempt]
                    if backoffNs > 0 {
                        try? await Task.sleep(nanoseconds: backoffNs)
                    }
                }
            }
        }

        // All bounded attempts failed: increment persistent failure counter and suspend if threshold reached.
        guard !Task.isCancelled, applyGeneration[key] == generation else { return }
        var failed = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        failed.settings.consecutiveRestoreFailures += 1
        if failed.settings.consecutiveRestoreFailures >= timing.maxConsecutiveFailuresBeforeSuspend {
            failed.settings.autoRestoreSuspended = true
            failed.status = .suspended(
                failureCount: failed.settings.consecutiveRestoreFailures,
                lastError: lastError.description
            )
        } else {
            failed.status = .failed(lastError)
        }
        failed.settings.lastApplicationStatus = failed.status.persistedSummary
        store.save(failed.settings, forKey: key)
        statesByKey[key] = failed
    }

    @discardableResult
    private func performUserApply(
        percentage: Int,
        for display: DisplayUnderscanDescriptor,
        key: String,
        generation: UInt64,
        triggerRollbackIfExperimental: Bool
    ) async -> Result<UnderscanApplyOutcome, UnderscanError> {
        guard applyGeneration[key] == generation else {
            return .failure(.applyFailed(String(localized: "Superseded by a newer underscan request.")))
        }

        let current = statesByKey[key] ?? buildState(for: display, key: key, existing: nil)
        let isExperimentalPath = !current.capability.isNativelySupported
            && current.settings.forceEnableExperimental

        if isExperimentalPath && !current.settings.hasConfirmedExperimentalRisk {
            var blocked = current
            blocked.status = .failed(.experimentalConfirmationRequired)
            statesByKey[key] = blocked
            return .failure(.experimentalConfirmationRequired)
        }

        let previousKnownGood = current.settings.lastKnownGoodPercentage
        let result = await submitToBackend(
            percentage: percentage,
            for: display,
            key: key,
            generation: generation,
            allowExperimental: current.settings.forceEnableExperimental
        )

        guard applyGeneration[key] == generation else { return result }

        var after = statesByKey[key] ?? current
        switch result {
        case .success(let outcome):
            after.lastSubmittedPercentage = outcome.submittedPercentage
            after.hardwareConfirmedPercentage = outcome.confirmedPercentage
            after.settings.consecutiveRestoreFailures = 0
            after.settings.autoRestoreSuspended = false
            if percentage == UnderscanValue.defaultPercentage {
                after.status = .resetToFullScreen
                after.settings.lastKnownGoodPercentage = UnderscanValue.defaultPercentage
                cancelRollbackTask(forKey: key)
                after.pendingRollback = nil
            } else {
                after.status = outcome.confirmedPercentage.map { .appliedConfirmed($0) }
                    ?? .submittedUnconfirmed(outcome.submittedPercentage)
                if !isExperimentalPath {
                    after.settings.lastKnownGoodPercentage = percentage
                } else if triggerRollbackIfExperimental, timing.rollbackTimeoutSeconds > 0 {
                    startRollbackCountdown(
                        for: display,
                        key: key,
                        testedPercentage: percentage,
                        previousKnownGood: previousKnownGood
                    )
                    after.pendingRollback = statesByKey[key]?.pendingRollback
                }
            }
            after.settings.lastApplicationStatus = after.status.persistedSummary
            store.save(after.settings, forKey: key)
            statesByKey[key] = after
        case .failure(let error):
            after.status = .failed(error)
            after.settings.lastApplicationStatus = after.status.persistedSummary
            store.save(after.settings, forKey: key)
            statesByKey[key] = after
        }

        return result
    }

    private func submitToBackend(
        percentage: Int,
        for display: DisplayUnderscanDescriptor,
        key: String,
        generation: UInt64,
        allowExperimental: Bool
    ) async -> Result<UnderscanApplyOutcome, UnderscanError> {
        guard !display.isBuiltin else { return .failure(.builtInDisplayBlocked) }
        guard !display.isVirtual else { return .failure(.virtualDisplayUnsupported) }
        guard isDisplayOnline(display.displayID) else { return .failure(.displayNotFound(display.displayID)) }

        let state: UnderscanDisplayState
        if let cached = statesByKey[key], cached.displayID == display.displayID {
            state = cached
        } else {
            let cap = await probeCapabilityOffMain(for: display)
            let built = buildState(for: display, key: key, existing: statesByKey[key], capabilityOverride: cap)
            statesByKey[key] = built
            state = built
        }
        var mutableState = state
        let range = mutableState.capability.percentageRange
        if case .failure(let error) = UnderscanValue.validatePercentage(percentage, allowedRange: range) {
            return .failure(error)
        }

        mutableState.isApplying = true
        statesByKey[key] = mutableState

        let raw = UnderscanValue.rawValue(forPercentage: percentage, clampedTo: mutableState.capability.rawRange)
        let backendRef = backend
        lastSelfApplyAt[key] = now()

        let result = await Task.detached(priority: .userInitiated) {
            backendRef.applyUnderscan(rawValue: raw, to: display, forceExperimental: allowExperimental)
        }.value

        if applyGeneration[key] == generation, var current = statesByKey[key] {
            current.isApplying = false
            statesByKey[key] = current
        }
        return result
    }

    private func startRollbackCountdown(
        for display: DisplayUnderscanDescriptor,
        key: String,
        testedPercentage: Int,
        previousKnownGood: Int
    ) {
        cancelRollbackTask(forKey: key)
        let totalSeconds = timing.rollbackTimeoutSeconds
        let tickNs = timing.rollbackTickNs
        let confirmation = UnderscanRollbackConfirmation(
            displayKey: key,
            displayID: display.displayID,
            testedPercentage: testedPercentage,
            previousKnownGoodPercentage: previousKnownGood,
            remainingSeconds: totalSeconds
        )
        if var state = statesByKey[key] {
            state.pendingRollback = confirmation
            statesByKey[key] = state
        }

        rollbackTasks[key] = Task { @MainActor [weak self] in
            var remaining = totalSeconds
            while remaining > 0 {
                if tickNs > 0 {
                    try? await Task.sleep(nanoseconds: tickNs)
                }
                guard let self, !Task.isCancelled else { return }
                remaining -= 1
                if var state = self.statesByKey[key], var pending = state.pendingRollback {
                    pending.remainingSeconds = remaining
                    state.pendingRollback = pending
                    self.statesByKey[key] = state
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.revertExperimentalChange(for: display, key: key)
        }
    }

    private func probeCapabilityOffMain(for display: DisplayUnderscanDescriptor) async -> UnderscanCapability {
        let backendRef = backend
        return await Task.detached(priority: .userInitiated) {
            backendRef.probeCapability(for: display)
        }.value
    }

    private func nonBlockingFallbackCapability(for display: DisplayUnderscanDescriptor) -> UnderscanCapability {
        let availability: UnderscanAvailability
        if display.isBuiltin {
            availability = .builtInRestricted
        } else if display.isVirtual {
            availability = .virtualDisplayUnsupported
        } else if !isDisplayOnline(display.displayID) {
            availability = .displayNotFound
        } else {
            availability = .unsupportedHardware(
                reason: String(localized: "Checking display underscan capability…")
            )
        }
        return UnderscanCapability(
            availability: availability,
            architecture: backend.hostArchitecture,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            readbackAvailable: false,
            hardwareConfirmedRaw: nil
        )
    }

    private func buildState(
        for display: DisplayUnderscanDescriptor,
        key: String,
        existing: UnderscanDisplayState?,
        capabilityOverride: UnderscanCapability? = nil
    ) -> UnderscanDisplayState {
        let settings = store.settings(forKey: key)
        let capability = capabilityOverride ?? existing?.capability ?? nonBlockingFallbackCapability(for: display)
        let initialRequested: Int
        if let existing, !settings.rememberValue {
            initialRequested = existing.requestedPercentage
        } else if settings.isEnabled || store.hasStoredSettings(forKey: key) {
            initialRequested = UnderscanValue.clampPercentage(
                settings.requestedPercentage,
                allowedRange: capability.percentageRange
            )
        } else if let confirmed = capability.hardwareConfirmedPercentage {
            initialRequested = UnderscanValue.clampPercentage(confirmed, allowedRange: capability.percentageRange)
        } else {
            initialRequested = UnderscanValue.defaultPercentage
        }

        let status: UnderscanApplyStatus
        if settings.autoRestoreSuspended {
            status = .suspended(
                failureCount: settings.consecutiveRestoreFailures,
                lastError: settings.lastApplicationStatus ?? String(localized: "Automatic restore paused after repeated failures.")
            )
        } else if let existing {
            status = existing.status
        } else if let confirmed = capability.hardwareConfirmedPercentage, confirmed < UnderscanValue.defaultPercentage {
            status = .appliedConfirmed(confirmed)
        } else {
            status = .idle
        }

        return UnderscanDisplayState(
            displayKey: key,
            displayID: display.displayID,
            capability: capability,
            settings: settings,
            requestedPercentage: initialRequested,
            lastSubmittedPercentage: existing?.lastSubmittedPercentage,
            hardwareConfirmedPercentage: capability.hardwareConfirmedPercentage ?? existing?.hardwareConfirmedPercentage,
            status: status,
            isApplying: existing?.isApplying ?? false,
            pendingRollback: existing?.pendingRollback
        )
    }

    private func nextGeneration(forKey key: String) -> UInt64 {
        let next = (applyGeneration[key] ?? 0) &+ 1
        applyGeneration[key] = next
        return next
    }

    private func cancelRestoreTask(forKey key: String) {
        restoreTasks[key]?.cancel()
        restoreTasks[key] = nil
    }

    private func cancelRollbackTask(forKey key: String) {
        rollbackTasks[key]?.cancel()
        rollbackTasks[key] = nil
    }

    private func cancelAllTasks(forKey key: String) {
        cancelRestoreTask(forKey: key)
        cancelRollbackTask(forKey: key)
        sliderThrottleTasks[key]?.cancel()
        sliderThrottleTasks[key] = nil
    }
}
