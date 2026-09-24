import CoreGraphics

/// Which display IDs need their DDC transport invalidated after a reconfiguration.
enum DDCTopologyChange {
    /// IDs whose fingerprint (identity + channel location) changed since the last
    /// refresh, plus ones that went away. An unchanged ID keeps its in-flight work,
    /// so ID reuse across a reconnect and swaps between identical monitors are caught.
    static func changedChannels(
        previous: [CGDirectDisplayID: String],
        current: [CGDirectDisplayID: String]
    ) -> Set<CGDirectDisplayID> {
        var changed = Set(current.keys.filter { previous[$0] != current[$0] })
        changed.formUnion(previous.keys.filter { current[$0] == nil })
        return changed
    }
}
