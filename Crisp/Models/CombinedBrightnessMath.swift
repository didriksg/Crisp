import Foundation

/// Pure absolute-luminance mapping for the combined brightness control.
/// Display slider percentages are not comparable: Apple panels use a strongly
/// perceptual curve while DDC exposes the monitor's luminance control directly.
enum CombinedBrightnessMath {
    /// Fine tuning after the nits-based match. 1.0 means equal estimated nits.
    static let builtinAdjustmentRange: ClosedRange<Double> = 0.1...1.5
    static let defaultBuiltinAdjustment = 1.0
    /// Must stay aligned with BrightnessService's DDC + gamma blend boundary.
    static let externalGammaBlendThreshold = 15.0

    /// Converts the shared 0...100 control to a target luminance.
    static func targetNits(combined: Double, referenceMaxNits: Double) -> Double {
        guard combined.isFinite, referenceMaxNits.isFinite, referenceMaxNits > 0 else { return 0 }
        return min(100.0, max(0.0, combined)) / 100.0 * referenceMaxNits
    }

    /// Converts target luminance to a display's native 0...maxBrightness scale.
    static func targetBrightness(
        combined: Double,
        maxBrightness: Double,
        displayMaxNits: Double?,
        referenceMaxNits: Double?
    ) -> Double {
        guard maxBrightness.isFinite, maxBrightness > 0,
              let displayMaxNits, displayMaxNits.isFinite, displayMaxNits > 0,
              let referenceMaxNits, referenceMaxNits.isFinite, referenceMaxNits > 0,
              maxBrightness <= 100.5 else {
            return min(maxBrightness, max(0.0, combined / 100.0 * maxBrightness))
        }
        let fraction = targetNits(combined: combined, referenceMaxNits: referenceMaxNits)
            / displayMaxNits
        let percent = externalBrightness(forLuminanceFraction: fraction)
        return min(maxBrightness, max(0.0, percent))
    }

    /// Converts a display's native brightness back to the shared control scale.
    static func controlValue(
        brightness: Double,
        maxBrightness: Double,
        displayMaxNits: Double?,
        referenceMaxNits: Double?
    ) -> Double {
        guard brightness.isFinite, maxBrightness.isFinite, maxBrightness > 0,
              let displayMaxNits, displayMaxNits.isFinite, displayMaxNits > 0,
              let referenceMaxNits, referenceMaxNits.isFinite, referenceMaxNits > 0,
              maxBrightness <= 100.5 else {
            return min(100.0, max(0.0, brightness / maxBrightness * 100.0))
        }
        let fraction = externalLuminanceFraction(forBrightness: brightness)
        let nits = fraction * displayMaxNits
        return min(100.0, max(0.0, nits / referenceMaxNits * 100.0))
    }

    /// Linear native-panel level (0...1) for the same absolute target. This is
    /// passed to DisplayServicesSetLinearBrightness so macOS performs its own
    /// nonlinear user-slider conversion instead of Crisp guessing the curve.
    static func builtinLinearTarget(
        combined: Double,
        referenceMaxNits: Double,
        builtinMaxNits: Double,
        adjustment: Double
    ) -> Double {
        guard builtinMaxNits.isFinite, builtinMaxNits > 0 else { return 0 }
        let safeAdjustment = adjustment.isFinite
            ? min(builtinAdjustmentRange.upperBound, max(builtinAdjustmentRange.lowerBound, adjustment))
            : defaultBuiltinAdjustment
        let nits = targetNits(combined: combined, referenceMaxNits: referenceMaxNits) * safeAdjustment
        return min(1.0, max(0.0, nits / builtinMaxNits))
    }

    /// Absolute-mode auto brightness runs in the opposite direction: derive
    /// the external target from the built-in panel's current linear level.
    static func externalBrightnessMatchingBuiltin(
        builtinLinear: Double,
        builtinMaxNits: Double,
        externalMaxNits: Double,
        builtinAdjustment: Double
    ) -> Double {
        guard builtinLinear.isFinite, builtinMaxNits.isFinite, builtinMaxNits > 0,
              externalMaxNits.isFinite, externalMaxNits > 0 else { return 0 }
        let safeAdjustment = builtinAdjustment.isFinite
            ? min(builtinAdjustmentRange.upperBound,
                  max(builtinAdjustmentRange.lowerBound, builtinAdjustment))
            : defaultBuiltinAdjustment
        let externalNits = builtinLinear * builtinMaxNits / safeAdjustment
        return externalBrightness(forLuminanceFraction: externalNits / externalMaxNits)
    }

    /// Below 15%, Crisp layers gamma dimming on top of DDC backlight dimming.
    /// The two factors multiply, so this inverse square root is required for
    /// the requested nits instead of treating the low range as linear.
    private static func externalBrightness(forLuminanceFraction fraction: Double) -> Double {
        let clamped = min(1.0, max(0.0, fraction))
        let thresholdFraction = externalGammaBlendThreshold / 100.0
        guard clamped < thresholdFraction else { return clamped * 100.0 }
        return sqrt(clamped * 100.0 * externalGammaBlendThreshold)
    }

    private static func externalLuminanceFraction(forBrightness brightness: Double) -> Double {
        let percent = min(100.0, max(0.0, brightness))
        guard percent < externalGammaBlendThreshold else { return percent / 100.0 }
        return percent / 100.0 * percent / externalGammaBlendThreshold
    }
}
