import Foundation

/// How many active displays have something behind them, given what the ports say. After
/// an undock while asleep (#112), WindowServer re-enumerates absent externals at wake
/// with real EDID identities, so they look live until the dock returns; externals are
/// capped at the number of ports that can be carrying one.
enum PhantomPortCap {
    /// offPort: displays no port carries (built-in, a DisplayLink dock's USB framebuffer);
    /// never capped. portCap nil means no transport-node signal at all, not zero plugged in:
    /// capping on it would black out desks this rule can't see (#112). The cap never adds.
    static func activeCount(offPort: Int, onPort: Int, portCap: Int?) -> Int {
        guard let portCap else { return offPort + onPort }
        return offPort + min(onPort, portCap)
    }
}
