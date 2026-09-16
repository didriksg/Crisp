import Foundation

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {

    /// Runs a blocking operation on a background thread with a timeout.
    ///
    /// The operation is dispatched to a `.userInitiated` global queue. If it
    /// completes within `seconds`, its return value is forwarded. If the
    /// deadline fires first, `fallback` is returned instead.
    ///
    /// This is useful for any CoreGraphics / WindowServer IPC call that can
    /// hang indefinitely (e.g. `CGCompleteDisplayConfiguration`,
    /// `CGVirtualDisplay.apply(_:)`).
    ///
    /// - Parameters:
    ///   - seconds:   Maximum time to wait before returning `fallback`.
    ///   - fallback:  Value returned on timeout.
    ///   - operation: The blocking work to execute off-thread.
    /// - Returns: The operation's result, or `fallback` on timeout.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { cont in
            let once = ResumeOnce()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = operation()
                if once.claim() { cont.resume(returning: result) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(returning: fallback) }
            }
        }
    }
}

/// Hands the continuation to whichever of the two closures gets there first.
/// The lock did that before from a captured `var`, which reads as a race to the
/// compiler even when a lock guards it, so the flag lives in here instead.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// True for the first caller only. The loser leaves the continuation alone.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
