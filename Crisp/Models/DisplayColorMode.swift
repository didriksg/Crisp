import Foundation

/// One CADisplay color-format variant for an otherwise identical display timing.
struct DisplayColorMode: Identifiable, Equatable, Sendable {
    let id: UInt64
    let width: Int
    let height: Int
    let refreshRate: Double
    let bitDepth: Int
    let colorMode: String
    let hdrMode: String

    var title: String {
        String(format: NSLocalizedString("%d-bit", comment: "Display color mode bit depth"), bitDepth)
    }

    var colorEncoding: String {
        if colorMode.localizedCaseInsensitiveContains("YCbCr444") { return "YCbCr 4:4:4" }
        if colorMode.localizedCaseInsensitiveContains("YCbCr422") { return "YCbCr 4:2:2" }
        if colorMode.localizedCaseInsensitiveContains("YCbCr420") { return "YCbCr 4:2:0" }
        if colorMode.localizedCaseInsensitiveContains("YCbCr") { return "YCbCr" }
        if colorMode.localizedCaseInsensitiveContains("RGB") { return "RGB" }
        return colorMode
    }

    var rangeLabel: String? {
        if colorMode.localizedCaseInsensitiveContains("FullRange") {
            return String(localized: "Full Range")
        }
        if colorMode.localizedCaseInsensitiveContains("LimitedRange") {
            return String(localized: "Limited Range")
        }
        return nil
    }

    var details: [String] {
        [hdrMode, colorEncoding, rangeLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    var detailLabel: String { details.joined(separator: " · ") }

    func sameTiming(as other: DisplayColorMode) -> Bool {
        width == other.width && height == other.height
            && abs(refreshRate - other.refreshRate) < 0.02
            && hdrMode.caseInsensitiveCompare(other.hdrMode) == .orderedSame
    }

    var summary: String {
        ([title] + details).joined(separator: " ")
    }

    /// Keeps the section subtitle compact; encoding and range appear in the list.
    var shortSummary: String {
        [title, hdrMode].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct DisplayColorModeSnapshot: Equatable, Sendable {
    /// The display's current mode after refreshing its CADisplay instance.
    let current: DisplayColorMode
    let compatibleModes: [DisplayColorMode]
    /// Setting is available when the current timing has another compatible mode ID.
    var canSet: Bool { compatibleModes.contains { $0.id != current.id } }
}

/// Public display geometry recorded alongside a private color-format choice.
struct DisplayTiming: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    func matches(_ other: DisplayTiming) -> Bool {
        width == other.width && height == other.height
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && (refreshRate == 0 || other.refreshRate == 0
                || abs(refreshRate - other.refreshRate) < 1.0)
    }
}

/// Color-mode IDs can change when WindowServer rebuilds the mode list.
struct SavedColorMode: Codable, Sendable {
    let width: Int
    let height: Int
    let refreshRate: Double
    let bitDepth: Int
    let colorMode: String
    let hdrMode: String
    let timing: DisplayTiming?

    init(_ mode: DisplayColorMode, timing: DisplayTiming?) {
        width = mode.width
        height = mode.height
        refreshRate = mode.refreshRate
        bitDepth = mode.bitDepth
        colorMode = mode.colorMode
        hdrMode = mode.hdrMode
        self.timing = timing
    }

    func matchesCurrentTiming(_ current: DisplayTiming?) -> Bool {
        guard let timing else { return true }
        guard let current else { return false }
        return timing.matches(current)
    }

    func matches(_ mode: DisplayColorMode) -> Bool {
        width == mode.width && height == mode.height
            && abs(refreshRate - mode.refreshRate) < 0.02
            && bitDepth == mode.bitDepth
            && colorMode.caseInsensitiveCompare(mode.colorMode) == .orderedSame
            && hdrMode.caseInsensitiveCompare(mode.hdrMode) == .orderedSame
    }
}
