import Combine
import CoreGraphics
import Foundation
import os

/// Application-facing native underscan service, bridging Crisp's `DisplayInfo` and
/// display lifecycle events onto `UnderscanCoordinator` + `MonitorPanelUnderscanBackend`.
@MainActor
final class UnderscanService: ObservableObject {
    static let shared = UnderscanService()
    private static let log = Logger(subsystem: "com.crisp.app", category: "underscan")

    let coordinator: UnderscanCoordinator
    private var relay: AnyCancellable?

    /// Last observed logical/pixel/refresh timing per display so `.setModeFlag` callbacks
    /// only trigger restoration when resolution or refresh rate actually changed.
    private var lastObservedTimings: [CGDirectDisplayID: ModeTimingSignature] = [:]
    /// Cached IORegistry channel locations (populated off-main to avoid 2.5-8ms CoreDisplay
    /// IPC calls during SwiftUI body evaluations).
    private var cachedChannelLocations: [CGDirectDisplayID: String] = [:]
    private var cachedUUIDs: [CGDirectDisplayID: String] = [:]

    private struct ModeTimingSignature: Equatable {
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Int
    }

    private init() {
        let backend = MonitorPanelUnderscanBackend()
        let store = UnderscanStore(defaults: .standard)
        self.coordinator = UnderscanCoordinator(backend: backend, store: store)
        self.relay = coordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Descriptors & Queries

    func descriptor(for display: DisplayInfo) -> DisplayUnderscanDescriptor {
        let cgUUID = cachedUUIDs[display.displayID] ?? DisplayInfo.cgDisplayUUID(display.displayID)
        let location = display.isBuiltin ? nil : cachedChannelLocations[display.displayID]
        return DisplayUnderscanDescriptor(
            displayID: display.displayID,
            cgUUID: cgUUID,
            vendorNumber: display.vendorNumber,
            modelNumber: display.modelNumber,
            serialNumber: display.serialNumber,
            channelLocation: location,
            isBuiltin: display.isBuiltin,
            isVirtual: VirtualDisplayService.shared.isVirtualDisplay(display.displayID),
            displayName: display.name
        )
    }

    func descriptors(for displays: [DisplayInfo]) -> [DisplayUnderscanDescriptor] {
        displays.map(descriptor(for:))
    }

    func state(for display: DisplayInfo, among displays: [DisplayInfo]) -> UnderscanDisplayState {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        return coordinator.state(for: target, among: all)
    }

    func refresh(display: DisplayInfo, among displays: [DisplayInfo]) async {
        await refreshCachedMetadata(for: displays)
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        _ = await coordinator.refreshDisplay(target, among: all)
    }

    func refreshAll(displays: [DisplayInfo]) async {
        await refreshCachedMetadata(for: displays)
        let all = descriptors(for: displays)
        await coordinator.refreshDisplays(all)
        recordCurrentTimings(for: displays)
    }

    // MARK: - User Controls

    func setSliderPercentage(
        _ percentage: Int,
        for display: DisplayInfo,
        among displays: [DisplayInfo],
        commitImmediately: Bool
    ) {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        coordinator.setSliderPercentage(percentage, for: target, among: all, commitImmediately: commitImmediately)
    }

    func resetToFullScreen(for display: DisplayInfo, among displays: [DisplayInfo]) async {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        _ = await coordinator.resetToFullScreen(for: target, among: all)
    }

    func disableUnderscan(for display: DisplayInfo, among displays: [DisplayInfo]) async {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        await coordinator.disableUnderscan(for: target, among: all)
    }

    func disableAllUnderscan(displays: [DisplayInfo]) async {
        let all = descriptors(for: displays)
        await coordinator.disableAllUnderscan(liveDisplays: all)
    }

    func updateSettings(
        for display: DisplayInfo,
        among displays: [DisplayInfo],
        mutate: (inout DisplayUnderscanSettings) -> Void
    ) {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        coordinator.updateSettings(for: target, among: all, mutate: mutate)
    }

    func confirmExperimentalRisk(for display: DisplayInfo, among displays: [DisplayInfo]) {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        coordinator.confirmExperimentalRisk(for: target, among: all)
    }

    func keepExperimentalChange(forKey key: String) {
        coordinator.keepExperimentalChange(forKey: key)
    }

    func revertExperimentalChange(for display: DisplayInfo, among displays: [DisplayInfo]) async {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        await coordinator.revertExperimentalChange(for: target, among: all)
    }

    func resumeAutoRestore(for display: DisplayInfo, among displays: [DisplayInfo]) {
        let all = descriptors(for: displays)
        let target = descriptor(for: display)
        coordinator.resumeAutoRestore(for: target, among: all)
    }

    // MARK: - Lifecycle Hooks

    func handleAppStartup(displays: [DisplayInfo]) {
        recordCurrentTimings(for: displays)
        Task { @MainActor in
            await refreshCachedMetadata(for: displays)
            let all = descriptors(for: displays)
            await coordinator.refreshDisplays(all)
            coordinator.scheduleRestoreAll(liveDisplays: all, trigger: .startup)
        }
    }

    func handleSystemWake(displays: [DisplayInfo]) {
        recordCurrentTimings(for: displays)
        Task { @MainActor in
            await refreshCachedMetadata(for: displays)
            let all = descriptors(for: displays)
            coordinator.scheduleRestoreAll(liveDisplays: all, trigger: .wake)
        }
    }

    func handleDisplayDisconnected(displayID: CGDirectDisplayID) {
        lastObservedTimings.removeValue(forKey: displayID)
        cachedChannelLocations.removeValue(forKey: displayID)
        cachedUUIDs.removeValue(forKey: displayID)
        coordinator.handleDisplayDisconnected(displayID: displayID)
    }

    func handleDisplaysReconfigured(added: [DisplayInfo], kept: [DisplayInfo], all displays: [DisplayInfo]) {
        recordCurrentTimings(for: displays)
        Task { @MainActor in
            await refreshCachedMetadata(for: displays)
            let allDescriptors = descriptors(for: displays)
            for display in added where !display.isBuiltin {
                let desc = descriptor(for: display)
                Self.log.notice("display \(display.displayID, privacy: .public) reconnected; checking saved underscan")
                coordinator.scheduleRestore(for: desc, among: allDescriptors, trigger: .reconnect)
            }
            for display in kept where !display.isBuiltin {
                let desc = descriptor(for: display)
                coordinator.scheduleRestore(for: desc, among: allDescriptors, trigger: .displayConfigChange)
            }
        }
    }

    /// Invoked after `.setModeFlag` completes; distinguishes genuine resolution or refresh-rate
    /// changes from unrelated reconfiguration notifications.
    func handleModeChangeIfNeeded(for display: DisplayInfo, among displays: [DisplayInfo]) {
        guard !display.isBuiltin,
              let newTiming = currentTiming(for: display.displayID) else { return }
        let previous = lastObservedTimings[display.displayID]
        lastObservedTimings[display.displayID] = newTiming
        guard let previous, previous != newTiming else { return }

        let resolutionChanged = previous.width != newTiming.width
            || previous.height != newTiming.height
            || previous.pixelWidth != newTiming.pixelWidth
            || previous.pixelHeight != newTiming.pixelHeight
        let trigger: UnderscanRestoreTrigger = resolutionChanged ? .resolutionChange : .refreshRateChange
        let allDescriptors = descriptors(for: displays)
        let target = descriptor(for: display)
        coordinator.scheduleRestore(for: target, among: allDescriptors, trigger: trigger)
    }

    // MARK: - Timing & Metadata Cache

    private func refreshCachedMetadata(for displays: [DisplayInfo]) async {
        let liveIDs = Set(displays.map(\.displayID))
        cachedChannelLocations = cachedChannelLocations.filter { liveIDs.contains($0.key) }
        cachedUUIDs = cachedUUIDs.filter { liveIDs.contains($0.key) }

        let externalIDs = displays.filter { !$0.isBuiltin }.map(\.displayID)
        for display in displays {
            if let uuid = DisplayInfo.cgDisplayUUID(display.displayID) {
                cachedUUIDs[display.displayID] = uuid
            }
        }
        guard !externalIDs.isEmpty else { return }
        let fetchedLocations = await Task.detached(priority: .userInitiated) {
            var map: [CGDirectDisplayID: String] = [:]
            for id in externalIDs {
                if let loc = DDCService.shared.channelLocation(for: id) {
                    map[id] = loc
                }
            }
            return map
        }.value
        for (id, loc) in fetchedLocations where liveIDs.contains(id) {
            cachedChannelLocations[id] = loc
        }
    }

    private func recordCurrentTimings(for displays: [DisplayInfo]) {
        let liveIDs = Set(displays.map(\.displayID))
        lastObservedTimings = lastObservedTimings.filter { liveIDs.contains($0.key) }
        for display in displays {
            if let timing = currentTiming(for: display.displayID) {
                lastObservedTimings[display.displayID] = timing
            }
        }
    }

    private func currentTiming(for displayID: CGDirectDisplayID) -> ModeTimingSignature? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return ModeTimingSignature(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: Int(mode.refreshRate.rounded())
        )
    }
}
