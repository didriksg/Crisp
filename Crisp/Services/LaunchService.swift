import Foundation
import ServiceManagement

/// Manages "Launch at Login" using SMAppService (macOS 13+).
@MainActor
final class LaunchService: @unchecked Sendable {
    static let shared = LaunchService()
    private init() {}

    // MARK: - State

    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    // MARK: - Enable / Disable

    @discardableResult
    func enable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return true
            } catch {
                #if DEBUG
                print("[LaunchService] register failed: \(error)")
                #endif
                return false
            }
        }
        return false
    }

    @discardableResult
    func disable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                return true
            } catch {
                #if DEBUG
                print("[LaunchService] unregister failed: \(error)")
                #endif
                return false
            }
        }
        return false
    }

    /// Toggle and return the new state.
    @discardableResult
    func toggle() -> Bool {
        if isEnabled {
            disable()
            return false
        } else {
            enable()
            return true
        }
    }
}
