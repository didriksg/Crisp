/// Maps the screen under the pointer to the panel that owns its brightness.
/// A hidden scaling source is eligible only through a confirmed live mirror.
enum BrightnessDisplayRouting {
    struct Route: Equatable, Sendable {
        let physicalID: UInt32
        let mirrorSourceID: UInt32?
    }

    static func physicalID(for screenID: UInt32, routes: [Route]) -> UInt32? {
        // Keep ordinary screens' existing behavior, including the built-in.
        if let direct = routes.first(where: { $0.physicalID == screenID }) {
            return direct.physicalID
        }

        var owner: UInt32?
        for route in routes where route.mirrorSourceID == screenID {
            // Do not send a key to an arbitrary panel if an association is ambiguous.
            guard owner == nil else { return nil }
            owner = route.physicalID
        }
        return owner
    }
}
