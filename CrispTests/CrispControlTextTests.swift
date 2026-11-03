import XCTest

/// What crispctl prints without --json (#227).
final class CrispControlTextTests: XCTestCase {
    private let builtin = CrispControlDisplay(
        id: 1, name: "Built-in Display", brightness: 62.254, maxBrightness: 160, isBuiltin: true,
        uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        resolution: .init(logicalWidth: 1352, logicalHeight: 878, pixelWidth: 2704, pixelHeight: 1756, refreshRate: 120, isHiDPI: true),
        brightnessBackend: .builtin, connected: true
    )
    private let held = CrispControlDisplay(
        id: 9, name: "M32UC", brightness: 0, maxBrightness: 100, isBuiltin: false,
        uuid: "DECC7CEF-5E36-4E9B-8F18-CE11AE5902AD",
        resolution: .init(logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 59.94, isHiDPI: false),
        brightnessBackend: .ddc, connected: false
    )

    func testEachCommandPrintsItsText() {
        let image = CrispControlImageAdjustment(
            displayID: 2, uuid: "U", name: "Q27G3XMN", contrast: 10, gamma: 0, gain: 0, temperature: -12.5,
            redGamma: 0, greenGamma: 0, blueGamma: 0, redGain: 0, greenGain: 0, blueGain: 0,
            quantization: 256, invert: true, paused: false
        )
        let preset = CrispControlPreset(id: "P1", name: "Desk", captures: ["resolution", "hdr"], displays: [], active: true)
        let virtual = CrispControlVirtualDisplay(id: "V1", name: "Headless", width: 1920, height: 1080, hiDPI: false, active: true)
        let cases: [(CrispControlRequest.Command, CrispControlResponse, String)] = [
            (.list, .success(displays: [builtin, held]), """
                ID  NAME              BRIGHTNESS   RESOLUTION            BACKEND  UUID
                1   Built-in Display  62% of 160%  1352x878 120Hz HiDPI  builtin  37D8832A-2D66-02CA-B9F7-8F30A301B230
                9   M32UC             -            disconnected          ddc      DECC7CEF-5E36-4E9B-8F18-CE11AE5902AD
                """),
            (.getBrightnessBoost, .success(brightnessBoost: .init(displayID: 1, eligible: true, enabled: true)), "on"),
            (.getBrightnessBoost, .success(brightnessBoost: .init(displayID: 1, eligible: false, enabled: false)), "off (not eligible)"),
            (.getHDR, .success(hdr: .init(displayID: 2, enabled: false)), "off"),
            (.toggleDisplay, .success(display: held), "M32UC disconnected"),
            (.listInputs, .success(inputs: .init(displayID: 2, uuid: "U", current: 15, inputs: [
                .init(value: 17, name: "HDMI 1"), .init(value: 15, name: "DisplayPort 1")
            ])), """
                   HDMI 1         17
                *  DisplayPort 1  15
                """),
            (.getImage, .success(image: image), """
                Q27G3XMN (2)
                contrast      10
                gamma         0
                gain          0
                temperature   -12.5
                red-gamma     0
                green-gamma   0
                blue-gamma    0
                red-gain      0
                green-gain    0
                blue-gain     0
                quantization  256
                invert        on
                paused        no
                """),
            (.listPresets, .success(presets: [preset]), """
                   NAME  CAPTURES        ID
                *  Desk  resolution,hdr  P1
                """),
            (.listPresets, .success(presets: []), "no presets"),
            (.applyPreset, .success(preset: preset, skippedDisplays: ["D1"]), "skipped D1: not connected"),
            (.listVirtualDisplays, .success(virtualDisplays: [virtual]), """
                NAME      RESOLUTION  STATE  ID
                Headless  1920x1080   on     V1
                """),
            (.listVirtualDisplays, .success(virtualDisplays: []), "no virtual displays"),
            (.setVirtualDisplay, .success(virtualDisplay: virtual), "Headless on"),
            (.setImage, .success(image: image), ""),
            (.setBrightness, .success(), "")
        ]
        for (command, response, text) in cases {
            XCTAssertEqual(CrispControlText.render(response, for: command), text, "\(command)")
        }
    }
}
