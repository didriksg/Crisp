// swiftc -parse-as-library Crisp/Models/BrightnessDisplayRouting.swift \
//   scripts/check-brightness-routing.swift -o /tmp/crisp-routing-checks && /tmp/crisp-routing-checks
import Foundation

@main
struct BrightnessRoutingChecks {
    static func main() {
        typealias Route = BrightnessDisplayRouting.Route
        let builtin = Route(physicalID: 1, mirrorSourceID: nil)
        let dell = Route(physicalID: 3, mirrorSourceID: 73)
        let other = Route(physicalID: 4, mirrorSourceID: 74)
        let cases: [(String, UInt32, [Route], UInt32?)] = [
            ("mirror source targets Dell", 73, [builtin, dell], 3),
            ("native external", 3, [builtin, dell], 3),
            ("built-in passthrough", 1, [builtin, dell], 1),
            ("disconnected panel", 73, [builtin], nil),
            ("inactive mirror", 73, [builtin, Route(physicalID: 3, mirrorSourceID: nil)], nil),
            ("second mirror", 74, [builtin, dell, other], 4),
            ("ambiguous mirror", 73, [builtin, dell, Route(physicalID: 4, mirrorSourceID: 73)], nil),
            ("direct match wins", 1, [builtin, Route(physicalID: 3, mirrorSourceID: 1)], 1)
        ]
        for (name, screen, routes, expected) in cases {
            let actual = BrightnessDisplayRouting.physicalID(for: screen, routes: routes)
            guard actual == expected else {
                print("FAIL: \(name): got \(String(describing: actual)); expected \(String(describing: expected))")
                exit(1)
            }
        }
        print("PASS: all \(cases.count) brightness routing cases")
    }
}
