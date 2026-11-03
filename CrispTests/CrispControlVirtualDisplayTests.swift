import XCTest

/// The crispctl virtual commands: the menu's list and its Activate/Deactivate switch.
final class CrispControlVirtualDisplayTests: XCTestCase {
    private func virtual(_ id: String, _ name: String, active: Bool) -> CrispControlVirtualDisplay {
        CrispControlVirtualDisplay(id: id, name: name, width: 1920, height: 1080, hiDPI: false, active: active)
    }

    private func set(_ selector: String, _ enabled: Bool, in virtuals: [CrispControlVirtualDisplay]) -> CrispControlResult {
        CrispControlModel.handle(
            Data(#"{"command":"setVirtualDisplay","selector":"\#(selector)","enabled":\#(enabled)}"#.utf8),
            displays: [], virtualDisplays: virtuals
        )
    }

    /// Scripts parse this reply, so its field names are the contract.
    func testListRepliesWithEveryVirtualDisplayUnderStableKeys() throws {
        let list = CrispControlModel.handle(
            Data(#"{"command":"listVirtualDisplays"}"#.utf8), displays: [], virtualDisplays: [virtual("V1", "Headless", active: true)]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: CrispControlModel.encode(list.response)) as? [String: Any])
        let listed = try XCTUnwrap((json["virtualDisplays"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(listed.keys), ["id", "name", "width", "height", "hiDPI", "active"])
    }

    func testOnAndOffChangeOnlyADisplayInTheOtherState() {
        let virtuals = [virtual("V1", "Headless", active: false), virtual("V2", "Desk", active: true)]
        XCTAssertEqual(set("headless", true, in: virtuals).virtualDisplayChange, .init(id: "V1", enabled: true))
        XCTAssertEqual(set("V2", false, in: virtuals).virtualDisplayChange, .init(id: "V2", enabled: false))
        // Already in the asked state: succeeds with the display and changes nothing.
        let already = set("Desk", true, in: virtuals)
        XCTAssertNil(already.virtualDisplayChange)
        XCTAssertEqual(already.response, .success(virtualDisplay: virtuals[1]))
        XCTAssertNil(set("V1", false, in: virtuals).virtualDisplayChange)
    }

    func testSelectorsResolveLikePresets() {
        let shared = [virtual("V1", "TV", active: false), virtual("V2", "tv", active: false)]
        XCTAssertEqual(set("TV", true, in: shared).response, .failure("2 virtual displays are named 'TV'; use an id: V1, V2"))
        XCTAssertEqual(set("Nope", true, in: shared).response, .failure("no virtual display named 'Nope'; virtual displays: TV, tv"))
        XCTAssertEqual(set("Nope", true, in: []).response, .failure("no virtual display named 'Nope'; virtual displays: none saved"))
        let missing = CrispControlModel.handle(Data(#"{"command":"setVirtualDisplay","selector":"V1"}"#.utf8), displays: [])
        XCTAssertEqual(missing.response, .failure("virtual display and on|off are required"))
    }
}
