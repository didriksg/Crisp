import Foundation

/// Session-only decisions shared by the UI router and headless tests.
enum SoftwareVolumePolicy {
    static func gain(_ percent: Double) -> Float {
        percent.isFinite ? Float(max(0, min(100, percent)) / 100) : 0
    }

    static func unmutedLevel(_ previous: Double?) -> Double {
        guard let previous, previous.isFinite, previous > 0 else { return 25 }
        return min(100, previous)
    }

    static func matchingDisplay(audioName: String, displayNames: [String]) -> Int? {
        let matches = displayNames.indices.filter { displayNames[$0] == audioName }
        return matches.count == 1 ? matches[0] : nil
    }

    static func usesSoftware(selectedID: UInt32?, displayID: UInt32, active: Bool, routeMatches: Bool) -> Bool {
        active && routeMatches && selectedID == displayID
    }
}
