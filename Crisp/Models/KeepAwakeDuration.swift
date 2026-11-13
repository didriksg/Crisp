import Foundation

enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case indefinite = 0
    case minutes15 = 900
    case minutes30 = 1800
    case hour1 = 3600
    case hours2 = 7200

    var id: Int { rawValue }

    /// Duration in seconds, or nil when indefinite (`Always`).
    var seconds: TimeInterval? {
        self == .indefinite ? nil : TimeInterval(rawValue)
    }

    /// Compact label rendered inside each duration pill.
    var pillLabel: String {
        switch self {
        case .indefinite: return String(localized: "Always")
        case .minutes15:  return String(localized: "15m")
        case .minutes30:  return String(localized: "30m")
        case .hour1:      return String(localized: "1h")
        case .hours2:     return String(localized: "2h")
        }
    }

    /// Spoken VoiceOver label for each duration pill.
    var accessibilityLabel: String {
        switch self {
        case .indefinite: return String(localized: "Always")
        case .minutes15:  return String(localized: "15 Minutes")
        case .minutes30:  return String(localized: "30 Minutes")
        case .hour1:      return String(localized: "1 Hour")
        case .hours2:     return String(localized: "2 Hours")
        }
    }

    /// Rounds positive remaining seconds up to whole minutes (`1...`), or `0` when expired (`<= 0`).
    static func remainingMinutes(for remainingSeconds: TimeInterval) -> Int {
        guard remainingSeconds > 0 else { return 0 }
        return max(1, Int(ceil(remainingSeconds / 60.0)))
    }

    /// Formats a positive minute count as a localized time span (`"42m"`, `"1h"`, `"1h 30m"`).
    /// Uses only single-argument `String(localized:)` keys (`"%lldh"`, `"%lldm"`) so `xcstrings-compile.py`
    /// and `xcodebuild -exportLocalizations` produce identical non-positional catalog keys.
    static func formattedSpan(minutes: Int) -> String {
        let clamped = max(1, minutes)
        let hours = clamped / 60
        let remMins = clamped % 60
        if hours > 0 {
            let hPart = String(localized: "\(hours)h")
            guard remMins > 0 else { return hPart }
            let mPart = String(localized: "\(remMins)m")
            return "\(hPart) \(mPart)"
        }
        return String(localized: "\(clamped)m")
    }

    /// Formats the inline countdown subtitle (`"42m left"`, `"1h 30m left"`).
    static func countdownLabel(minutes: Int) -> String {
        let span = formattedSpan(minutes: minutes)
        return String(localized: "\(span) left")
    }

    /// Formats the collapsed `Tools` row subtitle:
    /// - `nil` when `isActive == false`
    /// - `"Keep Awake"` when active indefinitely (`remainingMinutes == nil`)
    /// - `"Keep Awake · 42m left"` when timed (`remainingMinutes != nil`)
    static func toolsSubtitle(isActive: Bool, remainingMinutes: Int?) -> String? {
        guard isActive else { return nil }
        let title = String(localized: "Keep Awake")
        guard let mins = remainingMinutes, mins > 0 else { return title }
        return "\(title) · \(countdownLabel(minutes: mins))"
    }
}
