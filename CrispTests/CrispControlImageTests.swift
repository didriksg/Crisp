import XCTest

/// crispctl's Image Adjustment commands: the typed form, the refusals, and the
/// mapping from crispctl's setting names to the saved adjustment's fields.
final class CrispControlImageTests: XCTestCase {
    private let online = CrispControlDisplay(id: 7, name: "Display", brightness: 50, isBuiltin: false, uuid: "AAA", connected: true)
    private let held = CrispControlDisplay(id: 9, name: "Held", brightness: 0, isBuiltin: false, uuid: "BBB", connected: false)

    func testParserReadsGetSetAndReset() {
        let cases: [([String], CrispControlRequest)] = [
            (["image", "get", "7"], .init(command: .getImage, selector: "7")),
            (["image", "reset", "AAA"], .init(command: .resetImage, selector: "AAA")),
            (["image", "set", "7", "temperature", "-40"], .init(command: .setImage, selector: "7", setting: .temperature, value: -40)),
            (["image", "set", "7", "red-gain", "12.5"], .init(command: .setImage, selector: "7", setting: .redGain, value: 12.5)),
            (["image", "set", "7", "invert", "on"], .init(command: .setImage, selector: "7", setting: .invert, value: 1)),
            (["image", "set", "7", "invert", "off"], .init(command: .setImage, selector: "7", setting: .invert, value: 0))
        ]
        for (arguments, request) in cases {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .request(request), "\(arguments)")
        }
        for arguments in [["image", "set", "7", "warmth", "10"], ["image", "set", "7", "invert", "1"],
                          ["image", "set", "7", "contrast", "high"], ["image", "set", "7", "contrast"]] {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments),
                           .failure("usage: crispctl image set <display> <setting> <value>"), "\(arguments)")
        }
    }

    func testParserRejectsNonFiniteImageValues() {
        for value in ["nan", "inf", "-inf", "1e999"] {
            let arguments = ["image", "set", "7", "contrast", value]
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments),
                           .failure("usage: crispctl image set <display> <setting> <value>"), value)
        }
    }

    func testSetIsRefusedOutOfRangeAndOnADisconnectedDisplay() throws {
        func set(_ selector: String, _ setting: CrispControlImageSetting, _ value: Double) throws -> CrispControlResult {
            let request = CrispControlRequest(command: .setImage, selector: selector, setting: setting, value: value)
            return CrispControlModel.handle(
                try JSONEncoder().encode(request), displays: [online, held],
                imageAdjustment: { id in id == 7 ? GammaAdjustment().controlValues(displayID: id, uuid: "AAA", name: "Display") : nil }
            )
        }
        XCTAssertEqual(try set("7", .contrast, 55).imageChange, .init(displayID: 7, setting: .contrast, value: 55))
        XCTAssertEqual(try set("7", .contrast, 101).response, .failure("contrast must be -100 to 100"))
        XCTAssertEqual(try set("7", .quantization, 1).response, .failure("quantization must be 2 to 256"))
        XCTAssertEqual(try set("7", .quantization, 16.5).response, .failure("quantization must be 2 to 256"))
        XCTAssertNil(try set("7", .contrast, 101).imageChange)
        XCTAssertEqual(try set("BBB", .contrast, 10).response, .failure("display is not connected"))
    }

    /// Each crispctl name must reach its own field, and read back under the same name.
    func testEverySettingMapsToItsOwnField() throws {
        var adjustment = GammaAdjustment()
        let settings = CrispControlImageSetting.allCases.filter { $0 != .invert && $0 != .quantization }
        for (index, setting) in settings.enumerated() {
            adjustment = adjustment.setting(setting, to: Double(index + 1))
        }
        adjustment = adjustment.setting(.quantization, to: 64).setting(.invert, to: 1)
        let values = adjustment.controlValues(displayID: 7, uuid: "AAA", name: "Display")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [String: Any])
        for (index, setting) in settings.enumerated() {
            let key = setting.rawValue.replacingOccurrences(of: "-g", with: "G")
            XCTAssertEqual(json[key] as? Double, Double(index + 1), setting.rawValue)
        }
        XCTAssertEqual(json["quantization"] as? Int, 64)
        XCTAssertEqual(json["invert"] as? Bool, true)
        XCTAssertEqual(json["uuid"] as? String, "AAA")
        XCTAssertEqual(json["name"] as? String, "Display")
    }
}
