import ColorSync
import CoreGraphics
import Foundation

/// An explicit, session-only exception to the last-physical-screen guard.
/// Remote viewing/input must be checked by the caller before confirmation.
@MainActor
final class HeadlessDisplayService {
    static let shared = HeadlessDisplayService()
    private init() {}

    private var session: CrispControlHeadlessSession?
    private var physicalIdentity: CrispControlPhysicalIdentity?
    private var lastError: String?
    private var deadline: ContinuousClock.Instant?
    private var monitor: Task<Void, Never>?
    private var recovery: Task<Bool, Never>?
    private var recoverAfterLateCommit = false
    private let clock = ContinuousClock()

    var needsRecovery: Bool { session?.needsRecovery == true }

    func ownsPhysical(_ uuid: String) -> Bool {
        needsRecovery && session?.physicalUUID == uuid
    }

    func usesVirtual(_ id: UUID) -> Bool {
        needsRecovery && session?.virtualConfigID == id
    }

    func canRecoverRecordedPhysical(_ id: CGDirectDisplayID) -> Bool {
        physicalIdentity?.canRecoverRecorded(Self.identity(id)) == true
    }

    private static func identity(_ id: CGDirectDisplayID) -> CrispControlPhysicalIdentity {
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        }
        return .init(displayID: id, uuid: uuid, vendor: CGDisplayVendorNumber(id),
                     product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                     isBuiltin: CGDisplayIsBuiltin(id) != 0)
    }

    private var virtualReady: Bool {
        guard let session else { return false }
        return VirtualDisplayService.shared.controlSnapshots()
            .first { $0.config.id == session.virtualConfigID }?.ready == true
    }

    private var physicalOnline: Bool? {
        guard let session else { return nil }
        return PhysicalDisplayToggleService.shared.headlessPhysicalOnline(session.physicalUUID)
    }

    private var expired: Bool { deadline.map { clock.now >= $0 } ?? false }

    /// Used only by the explicit native disconnect, including after the DDC await.
    func allowsDisconnect(_ uuid: String) -> Bool {
        ownsPhysical(uuid) && session?.phase == .entering && virtualReady
    }

    func state() -> CrispControlHeadlessState {
        .init(session: session, physicalOnline: physicalOnline, virtualReady: virtualReady, lastError: lastError)
    }

    private func response(_ error: String? = nil) -> CrispControlResponse {
        .init(ok: error == nil, headless: state(), error: error)
    }

    func handle(_ request: CrispControlRequest, displays: [DisplayInfo]) async -> CrispControlResponse {
        if request.command == .headlessStatus { return response() }
        guard let selector = request.selector, selector.count == 36, let id = UUID(uuidString: selector) else {
            return response("an exact UUID is required")
        }
        switch request.command {
        case .headlessStart:
            guard let configID = request.headlessConfigID else { return response("a virtual config UUID is required") }
            return await start(physicalUUID: id.uuidString, configID: configID, displays: displays)
        case .headlessConfirm:
            guard let session, session.canConfirm(id, expired: expired, virtualReady: virtualReady,
                                                 physicalOnline: physicalOnline) else {
                return response("session cannot be confirmed; read headless status; do not retry blindly")
            }
            self.session?.phase = .active
            self.session?.confirmBy = nil
            deadline = nil
            return response()
        case .headlessRestore:
            guard session?.id == id else { return response("session ID does not match") }
            return await restore() ? response() : response("physical recovery is not verified; read headless status")
        default:
            return response("invalid headless command")
        }
    }

    private func start(physicalUUID: String, configID: UUID, displays: [DisplayInfo]) async -> CrispControlResponse {
        if let session, session.needsRecovery {
            guard session.physicalUUID == physicalUUID, session.virtualConfigID == configID,
                  session.phase == .awaitingConfirmation || session.phase == .active else {
                return response("another session or recovery is in progress")
            }
            guard session.canConfirm(session.id, expired: expired, virtualReady: virtualReady,
                                     physicalOnline: physicalOnline) else {
                return response("session is no longer ready; read headless status")
            }
            // Do not extend the trial or silently perform another native write.
            return response()
        }
        let physical = PhysicalDisplayToggleService.shared
        guard physical.isSupported,
              let display = displays.first(where: { $0.displayUUID == physicalUUID }),
              !VirtualDisplayService.shared.isVirtualDisplay(display.displayID),
              physical.headlessPhysicalOnline(physicalUUID) == true else {
            return response("the named physical screen must be online on an Apple Silicon Mac")
        }
        guard VirtualDisplayService.shared.controlSnapshots().contains(where: { $0.config.id == configID && $0.ready }) else {
            return response("the named Crisp virtual screen must already be ready")
        }
        let identity = Self.identity(display.displayID)
        guard identity.uuid == physicalUUID else { return response("physical identity changed; refresh display list") }
        physicalIdentity = identity
        recoverAfterLateCommit = false
        deadline = nil
        session = .init(id: UUID(), physicalUUID: physicalUUID, virtualConfigID: configID)
        lastError = nil
        startMonitor()
        let result = await physical.disconnectForHeadless(display)
        guard session?.phase == .entering else { return response("session is already recovering") }
        if case .failure(let error) = result {
            scheduleRecovery("disconnect failed or is uncertain: " + error.description)
            return response(lastError)
        }
        guard physicalOnline == false, virtualReady else {
            scheduleRecovery("disconnect read-back did not show a ready virtual-only desktop")
            return response(lastError)
        }
        session?.phase = .awaitingConfirmation
        session?.confirmBy = Date().timeIntervalSince1970 + 30
        deadline = clock.now.advanced(by: .seconds(30))
        return response()
    }

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.needsRecovery else { return }
                self.checkRecovery()
            }
        }
    }

    private func checkRecovery() {
        guard recovery == nil, let session else { return }
        if recoverAfterLateCommit {
            guard !PhysicalDisplayToggleService.shared.headlessCommitInFlight else { return }
            recoverAfterLateCommit = false
            scheduleRecovery(lastError ?? "recover after the native transaction completed")
        } else if let reason = session.recoveryReason(expired: expired, virtualReady: virtualReady) {
            scheduleRecovery(reason)
        } else if session.phase == .active || session.phase == .awaitingConfirmation, physicalOnline != false {
            scheduleRecovery("the physical screen returned or its state is unknown")
        }
    }

    private func scheduleRecovery(_ reason: String) {
        lastError = reason
        // Reserve before yielding so callbacks cannot enqueue a second recovery.
        guard recovery == nil else { return }
        session?.phase = .restoring
        recovery = Task { [weak self] in
            guard let self else { return false }
            let result = await self.recoverPhysical()
            self.recovery = nil
            return result
        }
    }

    /// Also used by normal Reconnect and App quit. Never drops the virtual screen first.
    func restore() async -> Bool {
        guard needsRecovery else { return true }
        if let recovery { return await recovery.value }
        scheduleRecovery("physical restoration requested")
        return await recovery?.value ?? false
    }

    private func recoverPhysical() async -> Bool {
        guard let session else { return true }
        let physical = PhysicalDisplayToggleService.shared
        deadline = nil
        self.session?.confirmBy = nil
        // A timeout stopped waiting, not the native transaction. Wait for its completion
        // before issuing the opposite write. If still pending, keep the virtual retained.
        let limit = clock.now.advanced(by: .seconds(30))
        while physical.headlessCommitInFlight, clock.now < limit {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !physical.headlessCommitInFlight else {
            recoverAfterLateCommit = true
            return recoveryFailed("native transaction is still in flight; recovery waits for completion")
        }
        let outcome = await physical.reconnectForHeadless(uuid: session.physicalUUID)
        if physical.headlessCommitInFlight {
            recoverAfterLateCommit = true
            return recoveryFailed("physical enable is still in flight; read headless status")
        }
        guard physicalOnline == true else {
            if case .failure(let error) = outcome { return recoveryFailed(error.description) }
            return recoveryFailed("physical screen has not returned online")
        }
        self.session?.phase = .restored
        monitor?.cancel()
        return true
    }

    private func recoveryFailed(_ message: String) -> Bool {
        session?.phase = .recoveryFailed
        lastError = message
        return false
    }
}
