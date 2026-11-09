import CoreGraphics

/// A sleep's layout is only reusable once the same displays and geometry are back.
struct DisplayLayoutSnapshot {
    struct Display {
        let id: CGDirectDisplayID
        let uuid: String
        let bounds: CGRect
        let rotation: Double
        let isMain: Bool
    }

    let displays: [Display]

    func originsToRestore(in current: [Display]) -> [(id: CGDirectDisplayID, x: Int, y: Int)]? {
        let savedUUIDs = Set(displays.map(\.uuid))
        guard displays.count > 1, savedUUIDs.count == displays.count,
              current.count == displays.count, Set(current.map(\.uuid)) == savedUUIDs else { return nil }
        let savedByUUID = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0) })
        guard current.allSatisfy({ display in
            guard let saved = savedByUUID[display.uuid] else { return false }
            return display.bounds.size == saved.bounds.size && display.rotation == saved.rotation
                && display.isMain == saved.isMain
        }), current.contains(where: { $0.bounds.origin != savedByUUID[$0.uuid]?.bounds.origin }) else { return nil }

        return current.compactMap { display in
            guard let saved = savedByUUID[display.uuid] else { return nil }
            return (display.id, Int(saved.bounds.minX), Int(saved.bounds.minY))
        }
    }
}
