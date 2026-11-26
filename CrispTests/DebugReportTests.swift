import XCTest

/// Headless tests for the Copy Debug Info text. `DebugReport` compiles directly into this
/// test target, so no `@testable import Crisp` is needed.
final class DebugReportTests: XCTestCase {

    func testListsVersionsDisplaysAndLog() {
        let text = DebugReport.text(
            crisp: "1.7.1", macOS: "Version 27.0.1 (Build 26A434)", mac: "Mac16,1, Apple M4 Pro",
            displays: [
                .init(name: "Built-in Retina Display", isBuiltin: true, isMain: true,
                      vendor: 0x610, model: 0xa057, mode: "1352 × 878 HiDPI, 120 Hz"),
                .init(name: "Q27G3XMN", isBuiltin: false, isMain: false,
                      vendor: 0x5e3, model: 0x2702, mode: nil)
            ],
            log: ["12:00:01.000 [501] display: added 2"], allRuns: true)
        XCTAssertEqual(text, """
            Crisp 1.7.1
            macOS Version 27.0.1 (Build 26A434)
            Mac Mac16,1, Apple M4 Pro

            Displays:
            - Built-in Retina Display (built-in, main), vendor 0x610, model 0xa057, 1352 × 878 HiDPI, 120 Hz
            - Q27G3XMN (external), vendor 0x5e3, model 0x2702

            Log, last 30 minutes:
            12:00:01.000 [501] display: added 2
            """)
    }

    /// An empty log says so, so a reader can tell "nothing logged" from a cut-off paste,
    /// and a log of this run alone says so too.
    func testEmptyLogFromThisRunSaysSo() {
        let text = DebugReport.text(crisp: "1", macOS: "2", mac: "3", displays: [], log: [], allRuns: false)
        XCTAssertTrue(text.hasSuffix("Log, last 30 minutes of this run of Crisp:\n(no lines)"))
    }

    /// The template promises no UUID; the same display keeps its number across lines.
    func testLogUUIDsAreNumbered() {
        let first = "37D8832A-2D66-02CA-B9F7-8F30A301B230", second = "decc7cef-5e36-4e9b-8f18-ce11ae5902ad"
        let text = DebugReport.text(crisp: "1", macOS: "2", mac: "3", displays: [], log: [
            "disconnect requested: \(first) id 2",
            "reconnect requested: \(second) id 3, after \(first.lowercased())"
        ], allRuns: true)
        XCTAssertTrue(text.hasSuffix("""
            disconnect requested: uuid-1 id 2
            reconnect requested: uuid-2 id 3, after uuid-1
            """))
    }
}
