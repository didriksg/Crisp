import CoreGraphics

/// Which display IDs need their DDC transport invalidated after a reconfiguration.
enum DDCTopologyChange {
    /// The IDs whose channel changed since the last refresh, plus the ones that went
    /// away. An ID whose fingerprint is unchanged keeps its in-flight work: a plug,
    /// unplug or rearrangement elsewhere must not cancel the write, the fade or the
    /// software fallback of a display the user is adjusting right now.
    ///
    /// A fingerprint is the display's identity plus its channel location, so an ID that
    /// survives a reconnect storm naming a different physical panel still counts as
    /// changed, and two identical monitors that swap IDs are both caught.
    static func changedChannels(
        previous: [CGDirectDisplayID: String],
        current: [CGDirectDisplayID: String]
    ) -> Set<CGDirectDisplayID> {
        var changed = Set(current.keys.filter { previous[$0] != current[$0] })
        changed.formUnion(previous.keys.filter { current[$0] == nil })
        return changed
    }
}
