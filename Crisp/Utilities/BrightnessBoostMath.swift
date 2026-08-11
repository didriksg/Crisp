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
    /// Headroom at or below 1.05 is noise, not a usable boost. Capped at
    /// 200%: the boost region gets the same track length as the native range,
    /// and the exponential factor mapping below spends it perceptually evenly
    /// however much real headroom the panel has.
    static func sliderMax(potentialHeadroom: Double) -> Double {
        guard potentialHeadroom > 1.05 else { return 100 }
        return (100 * min(potentialHeadroom, 2.0)).rounded()
    }

    /// Overlay multiplier for a brightness value on the extended scale.
    /// 0...100 is the hardware range (factor 1.0). 100...sliderMax maps
    /// EXPONENTIALLY onto 1.0...currentEDR (factor = headroom^t): luminance is
    /// perceived roughly logarithmically, so equal slider steps give equal
    /// brightness ratios, exposure-stop style. Calibrated on hardware: the
    /// panel renders the full reported headroom (about 4x here) clean, so the
    /// live currentEDR itself is the honest ceiling; macOS lowers it under
    /// ABL/thermals and the caller's headroom poll re-syncs, easing the
    /// factor down with it.
    /// Below hdrReadyThreshold the panel has not ramped EDR yet, so the full
    /// target would clip; apply a small pending nudge instead, which is
    /// itself what prompts macOS to ramp EDR. That nudge only makes sense
    /// while the display still advertises EDR potential: a display genuinely
    /// back in SDR (potentialHeadroom at or below hdrReadyThreshold) can
    /// never ramp, so the nudge would sit forever and wash the screen out.
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
    /// Gamma-table top for EXTERNAL HDR monitors at slider max. External boost
    /// does not use the EDR overlay: on third-party displays the OS-reported
    /// live headroom is not trustworthy (observed pinned at 1.2 on an AOC
    /// Q27G3XMN while a 2.87x gamma table delivered real brightness), and the
    /// overlay pipeline hard-clamps at that reported value, crushing near-white
    /// detail for almost no gain. Instead the boost region scales the display
    /// transfer table above 1.0 (BetterDisplay's method for these displays;
    /// tops > 1.0 are honored while the monitor is in HDR mode). The monitor
    /// tone-maps the result itself, so past its sustainable fullscreen
    /// luminance, light content flattens: the ceiling trades peak brightness
    /// against that washout.
    /// The ceiling is defined in LINEAR luminance (same units as the built-in's
    /// EDR factor: 4.0 = two exposure stops at slider max) and converted to the
    /// table's encoded domain below. The table applies BEFORE the panel's
    /// transfer function, so an encoded scale k multiplies mid-tone luminance
    /// by roughly k^2.2: a table top chosen directly (first attempt: 2.5,
    /// ~7.5x luminance; BetterDisplay's observed 2.87, ~10x) blasts mid-tones
    /// far past what the panel's fullscreen limit lets whites do, which is
    /// what reads as washed out.
    static let externalBoostCeilingLuminance = 4.0
    static let externalDisplayGamma = 2.2

    /// Overlay-factor analog for the external gamma path: exponential over the
    /// boost region like overlayFactor, but against the fixed calibrated
    /// luminance ceiling, never the OS-reported live headroom. Returns the
    /// encoded-domain table scale.
    static func externalBoostFactor(brightness: Double, sliderMax: Double) -> Double {
        guard brightness > 100, sliderMax > 100 else { return 1.0 }
        let t = min(1.0, (brightness - 100) / (sliderMax - 100))
        return pow(pow(externalBoostCeilingLuminance, 1.0 / externalDisplayGamma), t)
    }
}
