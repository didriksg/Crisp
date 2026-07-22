import Foundation
import IOKit
import CoreGraphics

// DisplayServices private API — reads the builtin display's actual brightness
// (0.0–1.0), the value the slider/keys/ambient sensor move. Primary read path:
// CoreDisplay_Display_GetUserBrightness is pinned at 1.0 on macOS 26 (probe:
// slider changes moved DisplayServices 0.97→0.72 while CoreDisplay stayed 1.0).
private let _DisplayServices_GetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()

// CoreDisplay private API — reads the user-set brightness of a display (0.0–1.0).
// Loaded via dlsym at runtime to avoid linking against the private CoreDisplay framework.
private let _CoreDisplay_GetBrightness: (@convention(c) (CGDirectDisplayID) -> Double)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Double).self)
}()

/// Reads the built-in display's brightness (which macOS auto-adjusts based on ambient light)
/// and syncs it to external displays. This avoids needing Intel-only LMU hardware access.
@MainActor
final class AutoBrightnessService: ObservableObject, @unchecked Sendable {
    static let shared = AutoBrightnessService()
    private init() {
        loadPrefs()
    }

    // MARK: - State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startPolling()
            } else {
                stopPolling()
            }
            savePrefs()
        }
    }

    /// Multiplier 0.5–1.5. Applied to builtin brightness when syncing to external displays.
    @Published var sensitivity: Double = 1.0 {
        didSet { savePrefs() }
    }

    /// Last builtin brightness reading (0.0–1.0). 0 = unavailable / no builtin display.
    @Published private(set) var builtinBrightness: Double = 0
    private var lastAppliedBrightness: Double = -1

    /// Set to true after the first poll attempt completes (success or failure).
    /// Used by the UI to distinguish "not polled yet" from "no builtin display found".
    @Published private(set) var hasPolled: Bool = false

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval = 2.0  // seconds

    // MARK: - Builtin Brightness

    /// Reads the current brightness of the builtin display.
    /// Returns a value in 0.0–1.0, or nil if no builtin display is found.
    /// Safe to call from a background thread.
    nonisolated func readBuiltinBrightness() -> Double? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        // DisplayServices first: the only API that tracks the real brightness here.
        if let getBrightness = _DisplayServices_GetBrightness {
            var dsValue: Float = 0
            if getBrightness(builtinID, &dsValue) == 0, dsValue > 0 {
                return min(1.0, max(0.0, Double(dsValue)))
            }
        }

        // Fallback: CoreDisplay (stale on macOS 26, may work on older systems).
        let value = _CoreDisplay_GetBrightness?(builtinID) ?? 0
        if value > 0 {
            return min(1.0, max(0.0, value))
        }

        // Fallback: IODisplayGetFloatParameter via IOKit service matching
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            var floatValue: Float = 0
            let kr = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &floatValue)
            if kr == KERN_SUCCESS && floatValue > 0 {
                return min(1.0, max(0.0, Double(floatValue)))
            }
        }

        return nil
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let brightness = self.readBuiltinBrightness()
                await self.applyBrightness(builtin: brightness)
                try? await Task.sleep(nanoseconds: UInt64(self.pollingInterval * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    private func applyBrightness(builtin: Double?) async {
        builtinBrightness = builtin ?? 0
        hasPolled = true

        guard let builtin, builtin > 0 else { return }

        // Only apply if builtin brightness changed more than 2% since last application.
        guard abs(builtin - lastAppliedBrightness) >= 0.02 else { return }

        // Pause only after the user manually adjusts an EXTERNAL display (their
        // override wins); a manual builtin change is the signal we sync from.
        if let last = BrightnessService.shared.lastExternalManualAdjustDate,
           Date().timeIntervalSince(last) < 30.0 {
            return
        }

        let targetPercentage = min(100.0, max(0.0, builtin * sensitivity * 100.0))

        let snapshot = DisplayManagerAccessor.shared.displays
        for display in snapshot {
            // Only sync to external (non-builtin) displays.
            guard !display.isBuiltin else { continue }
            let current = display.brightness
            if abs(current - targetPercentage) >= 2.0 {
                // Glide over most of the poll interval so successive targets
                // blend into one motion, like the builtin panel's own fade.
                BrightnessService.shared.setBrightnessSmooth(
                    targetPercentage, for: display, isAutoAdjust: true, duration: 1.6)
            }
        }
        lastAppliedBrightness = builtin
    }

    // MARK: - Persistence

    private let enabledKey = "fd.AutoBrightnessEnabled"
    private let sensitivityKey = "fd.AutoBrightnessSensitivity"

    private func loadPrefs() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        if UserDefaults.standard.object(forKey: sensitivityKey) != nil {
            sensitivity = UserDefaults.standard.double(forKey: sensitivityKey)
        }
    }

    private func savePrefs() {
        UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(sensitivity, forKey: sensitivityKey)
    }
}

// MARK: - Display Manager Accessor

/// Thin wrapper so AutoBrightnessService can reach displays without a direct EnvironmentObject.
@MainActor
final class DisplayManagerAccessor {
    static let shared = DisplayManagerAccessor()
    var displays: [DisplayInfo] = []
    private init() {}
}
