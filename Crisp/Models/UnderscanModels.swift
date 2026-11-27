import CoreGraphics
import Foundation

// MARK: - Value Validation & Conversion

/// Validated value math for native macOS underscan (`MonitorPanel` / `pscn` basis-point scale:
/// `10000` = 100% full desktop area, `7500` = 75% desktop area with black borders).
enum UnderscanValue {
    static let defaultMinimumPercentage = 75
    static let defaultMaximumPercentage = 100
    static let defaultPercentage = 100
    static let defaultPercentageRange: ClosedRange<Int> = defaultMinimumPercentage...defaultMaximumPercentage

    /// Raw units per 1% in macOS `MonitorPanel` / `pscn` coordinates (`100% == 10000`).
    static let rawScalePerPercent: Int32 = 100
    static let defaultMinimumRaw: Int32 = 7500
    static let defaultMaximumRaw: Int32 = 10000
    static let defaultRawRange: ClosedRange<Int32> = defaultMinimumRaw...defaultMaximumRaw

    /// Defensive sanity bounds for hardware-reported `minUnderscan`/`maxUnderscan`.
    /// Rejects nonsense values (0, negative, or overscan > 100%).
    static let sanityMinimumRaw: Int32 = 5000
    static let sanityMaximumRaw: Int32 = 10000

    static func validatePercentage(
        _ percentage: Int,
        allowedRange: ClosedRange<Int> = defaultPercentageRange
    ) -> Result<Int, UnderscanError> {
        guard allowedRange.contains(percentage) else {
            return .failure(.invalidValue(percentage, allowedRange))
        }
        return .success(percentage)
    }

    static func clampPercentage(
        _ percentage: Int,
        allowedRange: ClosedRange<Int> = defaultPercentageRange
    ) -> Int {
        min(allowedRange.upperBound, max(allowedRange.lowerBound, percentage))
    }

    /// Validates raw hardware bounds returned by `MPDisplay.minUnderscan` / `maxUnderscan`.
    /// Returns nil if bounds are inverted or outside defensive sanity limits.
    static func validatedHardwareRange(minRaw: Int32, maxRaw: Int32) -> ClosedRange<Int32>? {
        guard minRaw >= sanityMinimumRaw,
              maxRaw <= sanityMaximumRaw,
              minRaw < maxRaw else {
            return nil
        }
        return minRaw...maxRaw
    }

    /// Converts a raw basis-point range (e.g. `7500...10000`) to a user-facing percentage
    /// range constrained inside `defaultMinimumPercentage...defaultMaximumPercentage`.
    static func percentageRange(forRawRange rawRange: ClosedRange<Int32>) -> ClosedRange<Int> {
        let minPct = max(defaultMinimumPercentage, Int(ceil(Double(rawRange.lowerBound) / Double(rawScalePerPercent))))
        let maxPct = min(defaultMaximumPercentage, Int(floor(Double(rawRange.upperBound) / Double(rawScalePerPercent))))
        if minPct < maxPct {
            return minPct...maxPct
        }
        return defaultPercentageRange
    }

    static func rawValue(forPercentage percentage: Int, clampedTo rawRange: ClosedRange<Int32>) -> Int32 {
        let raw = Int32(percentage) * rawScalePerPercent
        return min(rawRange.upperBound, max(rawRange.lowerBound, raw))
    }

    static func percentage(fromRaw raw: Int32) -> Int {
        Int((Double(raw) / Double(rawScalePerPercent)).rounded())
    }
}

// MARK: - Host & Capability

enum HostArchitecture: String, Codable, Equatable, Sendable {
    case appleSilicon
    case intel
    case unknown

    static var current: HostArchitecture {
        #if arch(arm64)
        return .appleSilicon
        #elseif arch(x86_64)
        return .intel
        #else
        return .unknown
        #endif
    }
}

enum UnderscanAvailability: Equatable, Sendable {
    case nativeSupported(minRaw: Int32, maxRaw: Int32, canReadback: Bool)
    case unsupportedHardware(reason: String)
    case builtInRestricted
    case virtualDisplayUnsupported
    case frameworkUnavailable(framework: String)
    case symbolMissing(symbol: String)
    case invalidSignature(symbol: String)
    case displayNotFound

    var isNativelySupported: Bool {
        if case .nativeSupported = self { return true }
        return false
    }

    /// Experimental force-enable is permitted only when the private framework & setter symbol
    /// are verified present, the display is an online physical external monitor, and only the
    /// monitor's `supportsUnderscan` flag returned false.
    var canUseWithExperimentalForce: Bool {
        if case .unsupportedHardware = self { return true }
        return false
    }

    var rawRange: ClosedRange<Int32> {
        if case let .nativeSupported(minRaw, maxRaw, _) = self,
           let valid = UnderscanValue.validatedHardwareRange(minRaw: minRaw, maxRaw: maxRaw) {
            return valid
        }
        return UnderscanValue.defaultRawRange
    }

    var percentageRange: ClosedRange<Int> {
        UnderscanValue.percentageRange(forRawRange: rawRange)
    }
}

struct UnderscanCapability: Equatable, Sendable {
    let availability: UnderscanAvailability
    let architecture: HostArchitecture
    let osVersion: String
    /// True only when hardware readback via `MPDisplay.underscan` is verified safe for this
    /// display (natively supported display with valid bounds; never true for force-enabled
    /// Apple Silicon paths).
    let readbackAvailable: Bool
    /// Raw hardware-confirmed value from the display controller, or nil when readback is
    /// unavailable/unsafe. Never populated from local requested state.
    let hardwareConfirmedRaw: Int32?

    var hardwareConfirmedPercentage: Int? {
        hardwareConfirmedRaw.map(UnderscanValue.percentage(fromRaw:))
    }

    var isNativelySupported: Bool { availability.isNativelySupported }
    var canUseWithExperimentalForce: Bool { availability.canUseWithExperimentalForce }
    var percentageRange: ClosedRange<Int> { availability.percentageRange }
    var rawRange: ClosedRange<Int32> { availability.rawRange }
}

// MARK: - Errors

enum UnderscanError: Error, Equatable, Sendable, CustomStringConvertible {
    case frameworkUnavailable(String)
    case symbolMissing(String)
    case invalidSignature(String)
    case unsupportedDisplay(String)
    case builtInDisplayBlocked
    case virtualDisplayUnsupported
    case invalidValue(Int, ClosedRange<Int>)
    case experimentalConfirmationRequired
    case displayNotFound(CGDirectDisplayID)
    case applyFailed(String)
    case readbackUnsafe
    case autoRestoreSuspended

    var description: String {
        switch self {
        case .frameworkUnavailable(let framework):
            return String(localized: "Required macOS framework unavailable (\(framework)).")
        case .symbolMissing(let symbol):
            return String(localized: "Native underscan API symbol unavailable (\(symbol)).")
        case .invalidSignature(let symbol):
            return String(localized: "Incompatible macOS API signature (\(symbol)).")
        case .unsupportedDisplay(let reason):
            return reason
        case .builtInDisplayBlocked:
            return String(localized: "Native underscan is not supported on the built-in display.")
        case .virtualDisplayUnsupported:
            return String(localized: "Native underscan is not available on virtual displays.")
        case .invalidValue(let value, let range):
            return String(
                localized: "Underscan value \(String(value))% is outside the allowed \(String(range.lowerBound))%–\(String(range.upperBound))% range."
            )
        case .experimentalConfirmationRequired:
            return String(localized: "Confirm the experimental hardware test before applying forced underscan.")
        case .displayNotFound(let id):
            return String(localized: "Display \(String(id)) is no longer online.")
        case .applyFailed(let reason):
            return reason
        case .readbackUnsafe:
            return String(localized: "Hardware underscan readback is unavailable on this display.")
        case .autoRestoreSuspended:
            return String(localized: "Automatic restore paused after repeated failures.")
        }
    }
}

// MARK: - Apply & Runtime State

struct UnderscanApplyOutcome: Equatable, Sendable {
    /// Raw basis-point value submitted to the native setter.
    let submittedRaw: Int32
    /// Hardware-confirmed raw value read back after apply, or nil when readback is
    /// unavailable/unsafe (e.g. Apple Silicon experimental force-enable).
    let confirmedRaw: Int32?
    let wasExperimentalForce: Bool

    var submittedPercentage: Int { UnderscanValue.percentage(fromRaw: submittedRaw) }
    var confirmedPercentage: Int? { confirmedRaw.map(UnderscanValue.percentage(fromRaw:)) }
}

enum UnderscanApplyStatus: Equatable, Sendable {
    case idle
    case appliedConfirmed(Int)
    case submittedUnconfirmed(Int)
    case resetToFullScreen
    case failed(UnderscanError)
    case suspended(failureCount: Int, lastError: String)

    var persistedSummary: String {
        switch self {
        case .idle:
            return "idle"
        case .appliedConfirmed(let pct):
            return "confirmed:\(pct)"
        case .submittedUnconfirmed(let pct):
            return "submitted_unconfirmed:\(pct)"
        case .resetToFullScreen:
            return "reset:100"
        case .failed(let err):
            return "failed:\(err.description)"
        case .suspended(let count, let msg):
            return "suspended(\(count)):\(msg)"
        }
    }
}

/// Active fail-safe rollback countdown shown after an experimental underscan test.
struct UnderscanRollbackConfirmation: Equatable, Sendable {
    let displayKey: String
    let displayID: CGDirectDisplayID
    let testedPercentage: Int
    let previousKnownGoodPercentage: Int
    var remainingSeconds: Int
}

/// Live UI/runtime state for one display, clearly separating requested, last-submitted,
/// and hardware-confirmed underscan values.
struct UnderscanDisplayState: Equatable, Sendable {
    let displayKey: String
    let displayID: CGDirectDisplayID
    var capability: UnderscanCapability
    var settings: DisplayUnderscanSettings
    /// Value requested by the user or saved configuration (75...100).
    var requestedPercentage: Int
    /// Last value successfully submitted to the native API without an error, if any.
    var lastSubmittedPercentage: Int?
    /// Hardware-confirmed value read from macOS only when readback is verified safe.
    /// Always nil when hardware readback is unavailable or skipped on Apple Silicon.
    var hardwareConfirmedPercentage: Int?
    var status: UnderscanApplyStatus
    var isApplying: Bool
    var pendingRollback: UnderscanRollbackConfirmation?

    /// True if the slider can currently submit underscan values to this display.
    var isControlUsable: Bool {
        if capability.isNativelySupported { return true }
        return settings.forceEnableExperimental && capability.canUseWithExperimentalForce
    }
}

// MARK: - Restoration Triggers

enum UnderscanRestoreTrigger: String, Equatable, Sendable {
    case startup
    case wake
    case reconnect
    case resolutionChange
    case refreshRateChange
    case displayConfigChange
}

// MARK: - Per-Display Persisted Settings

struct DisplayUnderscanSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var isEnabled: Bool = false
    var requestedPercentage: Int = UnderscanValue.defaultPercentage
    var rememberValue: Bool = true
    var autoRestore: Bool = true
    var restoreAfterSleep: Bool = true
    var restoreAfterReconnect: Bool = true
    var restoreAfterResolutionChange: Bool = true
    var forceEnableExperimental: Bool = false
    /// Must be explicitly confirmed by the user before the first experimental hardware test.
    var hasConfirmedExperimentalRisk: Bool = false
    /// Previous known-good requested percentage preserved for fail-safe rollback.
    var lastKnownGoodPercentage: Int = UnderscanValue.defaultPercentage
    var lastApplicationStatus: String? = nil
    var autoRestoreSuspended: Bool = false
    var consecutiveRestoreFailures: Int = 0

    init(
        schemaVersion: Int = currentSchemaVersion,
        isEnabled: Bool = false,
        requestedPercentage: Int = UnderscanValue.defaultPercentage,
        rememberValue: Bool = true,
        autoRestore: Bool = true,
        restoreAfterSleep: Bool = true,
        restoreAfterReconnect: Bool = true,
        restoreAfterResolutionChange: Bool = true,
        forceEnableExperimental: Bool = false,
        hasConfirmedExperimentalRisk: Bool = false,
        lastKnownGoodPercentage: Int = UnderscanValue.defaultPercentage,
        lastApplicationStatus: String? = nil,
        autoRestoreSuspended: Bool = false,
        consecutiveRestoreFailures: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.requestedPercentage = UnderscanValue.clampPercentage(requestedPercentage)
        self.rememberValue = rememberValue
        self.autoRestore = autoRestore
        self.restoreAfterSleep = restoreAfterSleep
        self.restoreAfterReconnect = restoreAfterReconnect
        self.restoreAfterResolutionChange = restoreAfterResolutionChange
        self.forceEnableExperimental = forceEnableExperimental
        self.hasConfirmedExperimentalRisk = hasConfirmedExperimentalRisk
        self.lastKnownGoodPercentage = UnderscanValue.clampPercentage(lastKnownGoodPercentage)
        self.lastApplicationStatus = lastApplicationStatus
        self.autoRestoreSuspended = autoRestoreSuspended
        self.consecutiveRestoreFailures = max(0, consecutiveRestoreFailures)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
        let rawPct = (try? c.decode(Int.self, forKey: .requestedPercentage)) ?? UnderscanValue.defaultPercentage
        requestedPercentage = UnderscanValue.clampPercentage(rawPct)
        rememberValue = (try? c.decode(Bool.self, forKey: .rememberValue)) ?? true
        autoRestore = (try? c.decode(Bool.self, forKey: .autoRestore)) ?? true
        restoreAfterSleep = (try? c.decode(Bool.self, forKey: .restoreAfterSleep)) ?? true
        restoreAfterReconnect = (try? c.decode(Bool.self, forKey: .restoreAfterReconnect)) ?? true
        restoreAfterResolutionChange = (try? c.decode(Bool.self, forKey: .restoreAfterResolutionChange)) ?? true
        forceEnableExperimental = (try? c.decode(Bool.self, forKey: .forceEnableExperimental)) ?? false
        hasConfirmedExperimentalRisk = (try? c.decode(Bool.self, forKey: .hasConfirmedExperimentalRisk)) ?? false
        let rawGood = (try? c.decode(Int.self, forKey: .lastKnownGoodPercentage)) ?? UnderscanValue.defaultPercentage
        lastKnownGoodPercentage = UnderscanValue.clampPercentage(rawGood)
        lastApplicationStatus = try? c.decodeIfPresent(String.self, forKey: .lastApplicationStatus)
        autoRestoreSuspended = (try? c.decode(Bool.self, forKey: .autoRestoreSuspended)) ?? false
        consecutiveRestoreFailures = max(0, (try? c.decode(Int.self, forKey: .consecutiveRestoreFailures)) ?? 0)
    }

    func shouldRestore(for trigger: UnderscanRestoreTrigger) -> Bool {
        guard isEnabled, autoRestore, !autoRestoreSuspended else { return false }
        guard requestedPercentage < UnderscanValue.defaultPercentage else { return false }
        switch trigger {
        case .startup:
            return true
        case .wake:
            return restoreAfterSleep
        case .reconnect, .displayConfigChange:
            return restoreAfterReconnect
        case .resolutionChange, .refreshRateChange:
            return restoreAfterResolutionChange
        }
    }
}

// MARK: - Backend Abstraction

/// Mockable abstraction over the native macOS underscan API.
protocol UnderscanBackend: Sendable {
    var hostArchitecture: HostArchitecture { get }

    /// Probes hardware & private-framework capability without mutating display state.
    func probeCapability(for display: DisplayUnderscanDescriptor) -> UnderscanCapability

    /// Submits a validated raw underscan value (`7500...10000`) to the target display.
    func applyUnderscan(
        rawValue: Int32,
        to display: DisplayUnderscanDescriptor,
        forceExperimental: Bool
    ) -> Result<UnderscanApplyOutcome, UnderscanError>

    /// Safely reads the current hardware underscan value when supported and safe;
    /// returns nil when unavailable or unsafe (never crashes on Apple Silicon).
    func readHardwareUnderscan(for display: DisplayUnderscanDescriptor) -> Int32?
}
