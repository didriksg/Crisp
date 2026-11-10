import Foundation

/// How an external monitor's brightness is done, as the Brightness Control row shows it:
/// Hardware is the backlight over DDC, Software is the gamma table.
enum BrightnessControlRoute: Equatable {
    case hardware, software

    struct Row: Equatable {
        /// False for a monitor with no DDC to reach: it has no choice to offer.
        let visible: Bool
        let shown: BrightnessControlRoute
        /// False in HDR, where the monitor discards brightness writes.
        let hardwareSelectable: Bool
    }

    /// `choseSoftware` is the user's saved choice. `ddcAvailable` is nil before the first
    /// write settles it and false once three writes in a row failed. `ddcReachable` says
    /// the monitor has a DDC channel, or a write succeeded since it came online: it tells a
    /// monitor that lost DDC (shown, as Software) from one that never had it (hidden).
    static func row(choseSoftware: Bool, hdr: Bool, ddcAvailable: Bool?, ddcReachable: Bool) -> Row {
        Row(
            visible: choseSoftware || ddcAvailable == true || ddcReachable,
            shown: choseSoftware || hdr || ddcAvailable == false ? .software : .hardware,
            hardwareSelectable: !hdr
        )
    }
}
