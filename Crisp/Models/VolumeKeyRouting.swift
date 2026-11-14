import Foundation

/// Which displays the volume and mute keys drive. No pointer or all-displays
/// target as for brightness: only one audio output is live at a time.
enum VolumeKeyTarget: String, CaseIterable, Codable {
    case audioOutput
    case selected
}

/// Picks the displays the volume keys drive. Identical monitors are the hard case
/// for following the audio output; see docs/ddc-notes.md (volume keys and the
/// audio output).
enum VolumeKeyRouting {
    struct Candidate: Equatable {
        let name: String
        let uuid: String
    }

    /// The default audio output.
    struct Output: Equatable {
        /// The display the IORegistry ties this output to, when it can.
        var displayUUID: String? = nil
        var name: String?
        /// HDMI or DisplayPort transport.
        var isDisplayAudio: Bool
        /// macOS sets this device's volume itself (built-in speakers, headphones).
        var hasSystemVolume: Bool
    }

    /// Indices into `candidates` to drive, or empty to pass the keys through. A
    /// selection applies only to an output macOS can't set itself, and falls back
    /// to the audio output when none of it is attached.
    static func targets(
        output: Output,
        candidates: [Candidate],
        target: VolumeKeyTarget,
        selectedUUIDs: Set<String> = []
    ) -> [Int] {
        guard target == .selected, !output.hasSystemVolume else {
            return followingOutput(output, candidates)
        }
        let picked = candidates.indices.filter { selectedUUIDs.contains(candidates[$0].uuid) }
        return picked.isEmpty ? followingOutput(output, candidates) : picked
    }

    /// The output's own display: the IORegistry tie, else an exact name, else every
    /// display matching without the " (n)" suffix (only one of them is audible),
    /// else a lone candidate on display audio.
    static func followingOutput(_ output: Output, _ candidates: [Candidate]) -> [Int] {
        if let uuid = output.displayUUID, let owner = candidates.firstIndex(where: { $0.uuid == uuid }) {
            return [owner]
        }
        if let name = output.name {
            if let exact = candidates.firstIndex(where: { $0.name == name }) {
                return [exact]
            }
            let sameModel = candidates.indices.filter { baseName(candidates[$0].name) == name }
            if !sameModel.isEmpty {
                return sameModel
            }
        }
        if candidates.count == 1, output.isDisplayAudio {
            return [0]
        }
        return []
    }

    /// The display coprocessor (`dispext1`, `disp0`) a registry path runs through.
    static func displayController(inRegistryPath path: String) -> String? {
        path.split(separator: "/")
            .map { String($0.prefix { $0 != "@" && $0 != ":" }) }
            .last { $0.range(of: #"^disp(ext)?\d+$"#, options: .regularExpression) != nil }
    }

    /// A display name without the " (1)", " (2)" macOS adds to identical displays.
    static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }
}
