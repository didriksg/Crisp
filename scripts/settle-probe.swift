// Settle-window probe: does the display come back before or after
// restoreIfNoActiveDisplay's 2 s settle check, and by how much.
//
// Run: swift scripts/settle-probe.swift     (Ctrl-C to stop)
//
// phantom-probe.swift samples every 200 ms, which is the right resolution for a
// phantom that lives for 12-104 s. It cannot resolve this one: the margin between
// the display returning and the settle check firing is tens of milliseconds. This
// samples every 20 ms and reports the zero-window directly.
//
// ACTIVE is physicalActiveDisplayCount's own arithmetic: CGGetActiveDisplayList
// filtered by the 16-bit EDID shape check from #106. (The VirtualDisplayService
// exclusion is not reproducible outside the app; with no Crisp virtual display on
// the desk the two agree.) ONLINE is phantom-probe's form -- CGGetOnlineDisplayList
// filtered by CGDisplayIsActive -- kept so the two can be cross-checked the way
// they were on #112.
//
// On every 1+ -> 0 transition the probe opens a window and on the way back out
// prints how long the desk was actually empty. The nominal 2.000 s in the verdict is
// the optimistic end: Crisp's check is Task.sleep(2s) plus scheduling, which on a
// wake was measured landing 418-1254 ms late, so a window "over" 2.000 s can still
// stand down. Read it with the app's own `restore settled` / `no active display`
// line, which is what the check actually decided.
//
// It prints on any change to the per-display detail too, not just the counts. A
// display can enter CGGetActiveDisplayList before its EDID is populated, and #106's
// shape filter reads vendor/model 0 as "no panel" -- so that window leaves the count
// at 0 and is invisible to a counts-only probe. Lines showing a real display id
// marked `nopanel` are that state.
import CoreGraphics
import Foundation

let fmt = DateFormatter()
fmt.dateFormat = "HH:mm:ss.SSS"

/// physicalActiveDisplayCount's arithmetic, minus the VirtualDisplayService
/// exclusion, which cannot be reached from outside the app.
func activeCount() -> (n: Int, detail: String) {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return (0, "") }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return (0, "") }
    var n = 0
    var parts: [String] = []
    for id in ids.prefix(Int(count)) {
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
        let hasNoPanel = vendor == 0 || model == 0 || vendor > 0xFFFF || model > 0xFFFF
        if !hasNoPanel { n += 1 }
        parts.append("\(id)[\(String(vendor, radix: 16))/\(String(model, radix: 16))\(hasNoPanel ? " nopanel" : "")]")
    }
    return (n, parts.joined(separator: " "))
}

/// phantom-probe's COUNTED, for the cross-check.
func onlineCount() -> Int {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    var counted = 0
    for id in ids.prefix(Int(n)) where CGDisplayIsActive(id) == 1 {
        let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id)
        if v != 0 && m != 0 && v <= 0xFFFF && m <= 0xFFFF { counted += 1 }
    }
    return counted
}

let settleWindow: TimeInterval = 2.0
let sample: TimeInterval = 0.02
let heartbeat: TimeInterval = 2.0

var lastActive = -1
var lastOnline = -1
var lastDetail = ""
var darkSince: Date?
var lastBeat = Date.distantPast

setvbuf(stdout, nil, _IOLBF, 0)
print("settle-probe: sampling every \(Int(sample * 1000)) ms, settle window \(settleWindow) s")
print("ACTIVE = physicalActiveDisplayCount (CGGetActiveDisplayList + #106 shape filter)")
print("ONLINE = phantom-probe COUNTED (CGGetOnlineDisplayList + CGDisplayIsActive)")

while true {
    let now = Date()
    let (a, detail) = activeCount()
    let o = onlineCount()

    // Print on any change to the per-display detail, not just the counts. A display
    // that has entered the active list but whose EDID is not populated yet reads as
    // "nopanel" to #106's shape filter and leaves ACTIVE unchanged at 0, so keying
    // the print on the counts alone hides exactly the window this probe is for.
    if a != lastActive || o != lastOnline || detail != lastDetail {
        print("\(fmt.string(from: now))  * ACTIVE=\(a) ONLINE=\(o) | \(detail)")
        if a == 0, lastActive > 0 {
            darkSince = now
            let deadline = now.addingTimeInterval(settleWindow)
            print("\(fmt.string(from: now))    -> desk empty; a settle check started now would fire at \(fmt.string(from: deadline))")
        }
        if a > 0, let since = darkSince {
            let dark = now.timeIntervalSince(since)
            let margin = settleWindow - dark
            // Crisp's check is Task.sleep(2s) + scheduling, and on a wake that
            // overran by 418-1254 ms in run 5, so a nominal 2.000 s deadline is the
            // optimistic end of the range, not the real one. Report against both.
            let verdict = margin >= 0
                ? String(format: "under the nominal 2.000 s by %.0f ms", margin * 1000)
                : String(format: "OVER the nominal 2.000 s by %.0f ms (still safe if the check overran by more)", -margin * 1000)
            print(String(format: "\(fmt.string(from: now))    -> back after %.3f s -- \(verdict)", dark))
            darkSince = nil
        }
        lastActive = a
        lastOnline = o
        lastDetail = detail
        lastBeat = now
    } else if now.timeIntervalSince(lastBeat) >= heartbeat {
        // A gap in the dots means the sampler was frozen (deep sleep), not that
        // nothing happened -- the lesson from run 1 on #92.
        print("\(fmt.string(from: now))  . ACTIVE=\(a) ONLINE=\(o)")
        lastBeat = now
    }
    Thread.sleep(forTimeInterval: sample)
}
