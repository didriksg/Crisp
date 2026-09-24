import Foundation

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {

    /// Runs a blocking operation with a timeout, returning `fallback` if it doesn't finish
    /// in time. For CoreGraphics / WindowServer IPC calls that can hang indefinitely.
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

/// Hands the continuation to whichever of the two closures gets there first. A captured
/// `var` reads as a race to the compiler even when a lock guards it, so it lives in here.
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
