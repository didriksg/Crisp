// Crisp/Utilities/BrightnessBoostMath.swift
import Foundation

/// Pure mapping logic for the Extra Brightness (EDR upscaling) feature.
/// Kept free of AppKit so scripts/check-boost-math.swift can compile it standalone.
enum BrightnessBoostMath {
    /// currentEDR at or below this means the panel has not ramped EDR yet.
    static let hdrReadyThreshold = 1.05
    /// Applied instead of the target factor while not HDR-ready: slightly
    /// above 1.0 content is itself what prompts macOS to ramp EDR headroom.
    static let pendingHDRBrightnessFactor = 1.12

    /// UI slider ceiling for a display, from its potential EDR headroom.
    /// Headroom at or below 1.05 is noise. Capped at 200% so the exponential
    /// mapping below spends the boost region perceptually evenly. See
    /// docs/brightness-notes.md (BrightnessBoostMath).
    static func sliderMax(potentialHeadroom: Double) -> Double {
        guard potentialHeadroom > 1.05 else { return 100 }
        return (100 * min(potentialHeadroom, 2.0)).rounded()
    }

    /// Overlay multiplier for brightness above 100: maps exponentially onto
    /// 1.0...currentEDR, since perceived luminance is roughly logarithmic. Below
    /// hdrReadyThreshold, uses the pending nudge instead of clipping before EDR
    /// ramps. See docs/brightness-notes.md (BrightnessBoostMath).
    static func overlayFactor(brightness: Double, sliderMax: Double, currentEDR: Double, potentialHeadroom: Double) -> Double {
        guard brightness > 100, sliderMax > 100 else { return 1.0 }
        guard potentialHeadroom > hdrReadyThreshold else { return 1.0 }
        guard currentEDR > hdrReadyThreshold else { return pendingHDRBrightnessFactor }
        let t = min(1.0, (brightness - 100) / (sliderMax - 100))
        return pow(currentEDR, t)
    }

    // ponytail: one fixed ceiling and gamma for all externals; make them
    // per-display (EDID maxFALL / measured gamma) if one constant fits some
    // panel badly.
    /// Gamma-table top for EXTERNAL HDR monitors: scales the display transfer
    /// table instead of the EDR overlay, since third-party headroom reporting
    /// isn't trustworthy. Linear luminance (4.0 = two stops); too high washes
    /// out. See docs/brightness-notes.md (BrightnessBoostMath).
    static let externalBoostCeilingLuminance = 4.0
    static let externalDisplayGamma = 2.2

    /// Exponential over the boost region like overlayFactor, but against the
    /// fixed calibrated luminance ceiling, never live headroom. Returns the
    /// encoded-domain table scale (k^2.2 relation, see docs/brightness-notes.md).
    static func externalBoostFactor(brightness: Double, sliderMax: Double) -> Double {
        guard brightness > 100, sliderMax > 100 else { return 1.0 }
        let t = min(1.0, (brightness - 100) / (sliderMax - 100))
        return pow(pow(externalBoostCeilingLuminance, 1.0 / externalDisplayGamma), t)
    }
}
