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
            let lock = NSLock()
            var didResume = false

            DispatchQueue.global(qos: .userInitiated).async {
                let result = operation()
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                cont.resume(returning: result)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
#if DEBUG
                print("[CGHelpers] runWithTimeout: timed out after \(seconds)s — returning fallback")
#endif
                cont.resume(returning: fallback)
            }
        }
    }
}
