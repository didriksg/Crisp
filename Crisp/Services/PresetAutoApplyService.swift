import AppKit
import Combine
import os.log

/// Lives entirely inside Crisp. No helper process, polling timer, CLI or network.
@MainActor
final class PresetAutoApplyService {
    static let shared = PresetAutoApplyService()
    private static let log = Logger(subsystem: "com.crisp.app", category: "preset-auto-apply")
    private weak var displayManager: DisplayManager?
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var state = PresetAutoApplyState()
    private var revision = 0
    private let settleNanoseconds: UInt64

    init(settleNanoseconds: UInt64 = 3_000_000_000) {
        self.settleNanoseconds = settleNanoseconds
    }

    private struct Binding: Equatable {
        let id: UUID
        let displays: [String]
    }

    func start(displayManager: DisplayManager) {
        stop()
        self.displayManager = displayManager
        state = PresetAutoApplyState()
        displayManager.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &subscriptions)
        PresetService.shared.$presets
            .map { presets in
                presets.compactMap { preset -> Binding? in
                    guard let displays = preset.autoApplyDisplayUUIDs else { return nil }
                    return Binding(id: preset.id, displays: displays.sorted())
                }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: center.publisher(for: NSWorkspace.screensDidWakeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &subscriptions)
    }

    func stop() {
        cancelPending()
        subscriptions.removeAll()
        displayManager = nil
    }

    /// Manual sliders and preset selection win over a queued automatic change.
    func cancelPending() {
        revision += 1
        pending?.cancel()
        pending = nil
    }

    private func schedule(force: Bool = false) {
        let displays = PhysicalDisplayToggleService.shared.attachedExternalDisplayUUIDs
        guard state.observe(displays, force: force) else { return }
        cancelPending()
        let requestRevision = revision
        let delay = settleNanoseconds
        pending = Task { @MainActor [weak self] in
            // A dock's displays can arrive separately. One finite, cancellable delay
            // coalesces the burst and lets the existing mode/DDC initialization settle.
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self else { return }
            await self.applyMatchingPreset(displays: displays, revision: requestRevision)
        }
    }

    private func applyMatchingPreset(displays: Set<String>, revision requestRevision: Int) async {
        guard let displayManager, revision == requestRevision, !Task.isCancelled,
              !PresetService.shared.isApplying,
              PhysicalDisplayToggleService.shared.attachedExternalDisplayUUIDs == displays,
              PresetAutoApplyPolicy.match(in: PresetService.shared.presets, externalDisplays: displays) != nil else { return }
        // Details load asynchronously on connect. Use the current objects/modes, then
        // recheck the request and read the latest preset instead of retaining a snapshot.
        for display in displayManager.displays where display.isOnline && display.availableModes.isEmpty {
            await display.loadDetails()
        }
        guard revision == requestRevision, !Task.isCancelled, !PresetService.shared.isApplying,
              PhysicalDisplayToggleService.shared.attachedExternalDisplayUUIDs == displays,
              let preset = PresetAutoApplyPolicy.match(in: PresetService.shared.presets, externalDisplays: displays) else { return }
        Self.log.notice("Auto-applying preset \(preset.id.uuidString, privacy: .public) for \(displays.count) external display(s)")
        await PresetService.shared.applyPreset(preset, automatically: true)
    }
}
