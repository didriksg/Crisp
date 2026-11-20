import Foundation

/// The time limits Keep Awake offers (#274). The switch alone means `untilTurnedOff`.
enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case untilTurnedOff = 0
    case minutes15 = 15
    case minutes30 = 30
    case hour1 = 60
    case hours2 = 120
    case hours4 = 240
    case hours8 = 480

    var id: Int { rawValue }

    /// nil for `untilTurnedOff`.
    var seconds: TimeInterval? {
        self == .untilTurnedOff ? nil : TimeInterval(rawValue * 60)
    }

    /// "Until turned off", "15 minutes", "1 hour" in the app's language.
    var label: String {
        guard let seconds else { return String(localized: "Until turned off") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute]
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? ""
    }
}
