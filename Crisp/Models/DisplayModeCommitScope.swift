import CoreGraphics

enum DisplayModeCommitScope {
    /// A user-selected mode on a physical display should survive the next login.
    /// Crisp-managed virtual displays have no stable configuration to restore.
    static func forUserSelection(isVirtualDisplay: Bool) -> CGConfigureOption {
        isVirtualDisplay ? .forSession : .permanently
    }
}
