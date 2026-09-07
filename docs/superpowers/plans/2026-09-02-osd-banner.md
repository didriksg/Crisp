# Crisp-drawn OSD banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS 26 and later, replace the legacy OSDUIHelper bezel Crisp shows on brightness and volume key presses with a Crisp-drawn Liquid Glass capsule under the menu bar of the target display, in the style of the system's own HUD (#76).

**Architecture:** `BrightnessHUDService.show(level:image:on:)` stays the single entry point the three key paths in BrightnessKeyService call. On macOS 26 it forwards to a new `OSDBannerService`, which keeps one borderless, click-through NSPanel per screen (keyed by display ID, parked at alpha 0, never ordered out) whose content is a capsule with a small SwiftUI view over it. The steps below build that capsule on an `NSGlassEffectView`, which is where the work started; as built it is not glass at all, because no glass material softens its backdrop as gently as the system HUD does. The capsule is a backdrop layer that blurs, tones, saturates and bends what is behind it, all in its own filter chain. The spec records the measurements that settled it. Below macOS 26 the existing XPC code runs unchanged. No settings, no new localized strings. Spec: `docs/superpowers/specs/2026-09-02-osd-banner-design.md`.

**Tech Stack:** Swift, AppKit (`NSPanel`, `NSGlassEffectView`, macOS 26 SDK, deployment target macOS 14 so everything new is gated with `@available(macOS 26.0, *)`), SwiftUI (`NSHostingView`, `ObservableObject`). Build modes: `make compile` (swiftc, `-swift-version 5`) locally, Xcode Swift 6 in CI. Lint: `SWIFTLINT_DISABLE_SOURCEKIT=1 swiftlint lint --strict`. Live verification only; the spec records no unit test (the only pure logic is two lines of frame arithmetic).

---

## File structure

- Create `Crisp/Views/OSDBannerView.swift`: the observable model (`OSDBannerModel`) and the SwiftUI banner (`OSDBannerView`). Picked up by the `Crisp/Views/*.swift` wildcard, no project edit.
- Create `Crisp/Services/OSDBannerService.swift`: `OSDBannerService` (per-screen panel registry, placement, show) and `OSDBannerPanel` (the NSPanel subclass with the fade timer). Picked up by the `Crisp/Services/*.swift` wildcard.
- Modify `Crisp/Services/BrightnessHUDService.swift:52-57`: route to the banner on macOS 26.

Conventions to respect: no em dashes anywhere, no hard-wrapped prose in docs or commits, `crisp.*` for any defaults key (none needed here), commit messages in the style of `git log` (imperative, one line, body only when needed), and the attribution trailer below on every commit:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016kcKMwzjxnj9MVvEndMKov
```

Never push and never post to GitHub from this plan: pushing and the PR need Didrik's explicit go-ahead (project rule).

---

### Task 1: Banner model and view

**Files:**
- Create: `Crisp/Views/OSDBannerView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// State behind one OSD banner: the display name, which glyph pair to show,
/// and the level as 0...1. Mutated by OSDBannerService on every key press;
/// the panel's hosting view redraws from it.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerModel: ObservableObject {
    @Published var title = ""
    @Published var image: OSDImage = .brightness
    @Published var level = 0.0
}

/// The banner OSDBannerService draws on macOS 26: the display name over a
/// level track with a symbol at each end, in the style of the system's own
/// brightness and volume capsule under the menu bar. Sizes and paddings are
/// tuned against a screenshot of the native capsule on the same screen.
@available(macOS 26.0, *)
struct OSDBannerView: View {
    /// Visible capsule size, measured from the native HUD on 26.5.1.
    static let size = NSSize(width: 280, height: 54)

    @ObservedObject var model: OSDBannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                track
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3))
                Capsule().fill(.primary).frame(width: geo.size.width * model.level)
            }
        }
        .frame(height: 6)
    }

    private var leadingSymbol: String {
        switch model.image {
        case .volume: return "speaker.fill"
        case .mute: return "speaker.slash.fill"
        default: return "sun.min.fill"
        }
    }

    /// Mute shows the slashed speaker alone with an empty track.
    private var trailingSymbol: String? {
        switch model.image {
        case .volume: return "speaker.wave.3.fill"
        case .mute: return nil
        default: return "sun.max.fill"
        }
    }
}
```

`OSDImage` is the existing `@objc enum` in `BrightnessHUDService.swift` (brightness, volume, mute, eject); `default` covers eject, which no call site sends. `Text(model.title)` takes a `String`, so the compiler extracts no localization key for it and the catalog check stays clean.

- [ ] **Step 2: Compile**

Run: `make compile`
Expected: ends with `Done. ./Crisp-bin built`. The file depends only on `OSDImage`, which already exists.

- [ ] **Step 3: Commit**

```bash
git add Crisp/Views/OSDBannerView.swift
git commit -m "Add the OSD banner model and view for macOS 26

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016kcKMwzjxnj9MVvEndMKov"
```

---

### Task 2: Banner service and panel

**Files:**
- Create: `Crisp/Services/OSDBannerService.swift`

- [ ] **Step 1: Write the file**

```swift
import AppKit
import SwiftUI

/// Draws Crisp's own on-screen display on macOS 26, in the style of the
/// system's brightness and volume capsule under the menu bar. OSDUIHelper,
/// which BrightnessHUDService still calls on macOS 14 and 15, draws the
/// pre-Tahoe bottom-centre bezel on 26, and the system's own capsule
/// (Control Center's SystemBanner) has no third-party entry point (#76).
///
/// One panel per screen, created on first use and never ordered out: taking
/// a Liquid Glass surface off screen replays its materialize bloom on the
/// next order-in (see the menu panel notes in AppDelegate), so hidden means
/// alpha 0. Screens that vanish get their panel closed on the next show.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerService {
    static let shared = OSDBannerService()
    private init() {}

    /// Measured from the native capsule on 26.5.1: 20 pt in from the right
    /// screen edge, 12 pt below the menu bar. The 280 x 54 size lives on the view.
    static let trailingInset: CGFloat = 20
    static let topInset: CGFloat = 12
    /// The window level OSDUIHelper and Control Center draw their capsule at.
    static let windowLevel = NSWindow.Level(rawValue: 2005)
    /// Same hold as the msecUntilFade BrightnessHUDService passes the helper.
    static let visibleDuration: TimeInterval = 1.5
    static let fadeDuration: TimeInterval = 0.3

    private var panels: [CGDirectDisplayID: OSDBannerPanel] = [:]

    /// Shows (or refreshes) the banner on `screen`. `level` is 0...100 as the
    /// key paths pass it: for brightness a percentage of the display's extended
    /// maximum, for volume the DDC volume itself.
    func show(level: Double, image: OSDImage, on screen: NSScreen) {
        guard let displayID = Self.displayID(of: screen) else { return }
        prunePanels()
        let panel: OSDBannerPanel
        if let existing = panels[displayID] {
            panel = existing
        } else {
            panel = makePanel()
            panels[displayID] = panel
        }
        // Recomputed every time: a resolution change moves the top-right corner.
        panel.setFrame(Self.frame(on: screen), display: false)
        panel.model.title = screen.localizedName
        panel.model.image = image
        panel.model.level = max(0, min(1, level / 100))
        panel.reveal()
    }

    /// Top-right of the screen, under the menu bar (visibleFrame excludes it),
    /// or under the screen edge when the menu bar is hidden.
    static func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.maxX - trailingInset - OSDBannerView.size.width,
               y: screen.visibleFrame.maxY - topInset - OSDBannerView.size.height,
               width: OSDBannerView.size.width, height: OSDBannerView.size.height)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func prunePanels() {
        let live = Set(NSScreen.screens.compactMap(Self.displayID(of:)))
        for (id, panel) in panels where !live.contains(id) {
            panel.close()
            panels[id] = nil
        }
    }

    private func makePanel() -> OSDBannerPanel {
        let p = OSDBannerPanel(
            contentRect: NSRect(origin: .zero, size: OSDBannerView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Set the level explicitly and never isFloatingPanel: that setter
        // silently resets the level to floating (3), under the menu bar.
        p.level = Self.windowLevel
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        // The glass edge carries the shape; the WindowServer shadow is tried
        // live against the native capsule and kept only if it matches.
        p.hasShadow = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.alphaValue = 0

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: OSDBannerView.size))
        glass.cornerRadius = OSDBannerView.size.height / 2
        let hosting = NSHostingView(rootView: OSDBannerView(model: p.model))
        // The glass pins its content view to its own edges with constraints.
        glass.contentView = hosting
        p.contentView = glass
        return p
    }
}

/// One banner window. Holds its model and the hide timer; OSDBannerService
/// owns placement and content.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerPanel: NSPanel {
    let model = OSDBannerModel()
    private var hideWork: DispatchWorkItem?
    private var hasShownOnce = false

    /// Brings the banner to alpha 1 and restarts the hide timer. Key repeat
    /// lands here many times a second: no allocation beyond the work item.
    func reveal() {
        hideWork?.cancel()
        // First show only: a short fade masks the glass materialize bloom, the
        // way the menu panel's first open does. Later shows are instant and
        // replace any in-flight fade-out.
        let duration: TimeInterval = hasShownOnce ? 0 : 0.12
        hasShownOnce = true
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OSDBannerService.visibleDuration, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = OSDBannerService.fadeDuration
            animator().alphaValue = 0
        }
    }
}
```

Notes for the implementer: `OSDBannerPanel` defines no initializer on purpose (a custom designated init on an NSWindow subclass drags in `init?(coder:)`); the service configures it. The `DispatchWorkItem` + `asyncAfter` timer is the same pattern as `repositionWorkItem` in AppDelegate, which is known to pass the Xcode Swift 6 build. `NSGlassEffectView`, its `contentView` and `cornerRadius` are in the macOS 26 SDK headers on this Mac (checked 2026-09-02).

- [ ] **Step 2: Compile**

Run: `make compile`
Expected: ends with `Done. ./Crisp-bin built`. If the compiler rejects `@available` placement or the `where` clause in `prunePanels`, fix in place; no other file changes yet.

- [ ] **Step 3: Lint**

Run: `SWIFTLINT_DISABLE_SOURCEKIT=1 swiftlint lint --strict Crisp/Services/OSDBannerService.swift Crisp/Views/OSDBannerView.swift`
Expected: `Done linting! Found 0 violations`.

- [ ] **Step 4: Commit**

```bash
git add Crisp/Services/OSDBannerService.swift
git commit -m "Add OSDBannerService: one glass banner panel per screen on macOS 26

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016kcKMwzjxnj9MVvEndMKov"
```

---

### Task 3: Route macOS 26 to the banner

**Files:**
- Modify: `Crisp/Services/BrightnessHUDService.swift:50-57`

- [ ] **Step 1: Edit `show(level:image:on:)`**

Replace the top of the method so it reads:

```swift
    /// Shows the native macOS OSD with the given glyph (brightness, volume,
    /// mute) and a 0–100 level bar on the specified display.
    func show(level: Double, image: OSDImage, on screen: NSScreen) {
        // macOS 26 draws the pre-Tahoe bottom-centre bezel for OSDUIHelper
        // callers while its own HUD is a capsule under the menu bar, so Crisp
        // draws that capsule itself there (#76). 14 and 15 keep the helper.
        if #available(macOS 26.0, *) {
            OSDBannerService.shared.show(level: level, image: image, on: screen)
            return
        }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return
        }
```

Everything after the `guard` stays as it is. Also update the class doc comment two lines above `@MainActor` so it no longer claims the helper output is what macOS uses natively on every version:

```swift
/// Shows the brightness / volume OSD for a display: Crisp's own banner on
/// macOS 26 (OSDBannerService), the native OSDUIHelper bezel before that.
///
/// The XPC path is what MonitorControl and BetterDisplay used for the same purpose.
```

- [ ] **Step 2: Compile and lint**

Run: `make compile && SWIFTLINT_DISABLE_SOURCEKIT=1 swiftlint lint --strict`
Expected: `Done. ./Crisp-bin built` and `Found 0 violations`.

- [ ] **Step 3: Commit**

```bash
git add Crisp/Services/BrightnessHUDService.swift
git commit -m "Show Crisp's own OSD banner instead of the OSDUIHelper bezel on macOS 26 (#76)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016kcKMwzjxnj9MVvEndMKov"
```

---

### Task 4: Live verification and tuning on the Dell

**Files:**
- Scratch only: `$SCRATCH/brightness-key.swift` (never committed)
- Possibly modify: the size, inset and font constants in the two new files

Preconditions: `/Applications/Crisp.app` exists, Brightness Keys is on in Crisp's panel (Accessibility granted), the Dell U4919DW is the only screen (lid closed). If the key tap fails with the dev signature, use the release identity as CLAUDE.md documents: `CRISP_SIGN_ID="Developer ID Application: Didrik Salve Galteland (HQHWD6JXX7)" make dev`.

Layout budget (from the Task 1 review): the content fits the 54 pt frame with about 3 pt of vertical slack after the padding and spacing fix. Any font or padding increase must keep `NSHostingView(rootView:).fittingSize.height` at or below 54, or the panel clips the bottom of the track.

Checks from the Task 2 review, do them during Steps 2 to 4: the banner window must report layer 2005 in `CGWindowListCopyWindowInfo` next to Control Center's own; measure the visible native capsule's right inset directly (its window overhangs the screen edge, so the inset may be nearer 17 pt than 20); confirm the banner shows over a full-screen app on the target display and behaves when a key is pressed with Mission Control up; with the Dock on the right the banner overlaps it at 2005, check the native HUD does the same; with the menu bar set to auto-hide the banner must land 12 pt below the screen edge without being repositioned.

- [ ] **Step 1: Deploy the dev build**

Run: `make dev`
Expected: compile, swap, re-sign, relaunch; Crisp's status item is back in the menu bar.

- [ ] **Step 2: Write the key probe**

Crisp's tap is a session tap, so a media key posted to the HID tap reaches it. `$SCRATCH` is the session scratchpad directory from the system prompt.

```swift
// brightness-key.swift: post one brightness-down (3) or -up (2) key, then screenshot.
import AppKit
let key = Int(CommandLine.arguments[1]) ?? 3
let out = CommandLine.arguments[2]
func post(down: Bool) {
    let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
    NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                       windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)!
        .cgEvent!.post(tap: .cghidEventTap)
}
post(down: true); post(down: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
let t = Process(); t.launchPath = "/usr/sbin/screencapture"; t.arguments = ["-x", "-D", "1", out]
t.launch(); t.waitUntilExit()
```

Run: `cd $SCRATCH && swiftc -O -o brightness-key brightness-key.swift && ./brightness-key 3 $SCRATCH/banner-1.png && sips -c 140 520 --cropOffset 0 4600 $SCRATCH/banner-1.png --out $SCRATCH/banner-1-crop.png`
Expected: the crop shows a glass capsule under the menu bar at the top right of the Dell with "Dell U4919DW", sun symbols and a partly filled track. Look at it with the Read tool.

- [ ] **Step 3: Check the fade and repeat**

Run: `./brightness-key 2 $SCRATCH/banner-2.png` then, after three seconds, `screencapture -x -D 1 $SCRATCH/banner-gone.png`.
Expected: banner-2 shows the track one step fuller than banner-1; banner-gone shows no banner. Then hold the real F1 key on the keyboard for a second while watching the Dell: the banner stays up and the track walks down without flicker.

- [ ] **Step 4: Compare with the native capsule**

Run the mute probe from the brainstorming session (`$SCRATCH/mute-probe`, or press the real mute key twice) and crop the same region: `sips -c 140 520 --cropOffset 0 4600 native.png --out native-crop.png`. Put the two crops side by side and compare size, vertical offset, label size, track thickness and edge treatment. Do this in both appearances (System Settings > Appearance, light and dark) and over a bright and a dark wallpaper, since the glass tints from the wallpaper while the labels follow the appearance. Two tuning items the review flagged: the track background at `.secondary.opacity(0.3)` may nearly vanish on glass, and a level of 0 draws no fill at all where the native HUD keeps a small nub. Adjust `size`, the font sizes and the paddings in `OSDBannerView`, and `trailingInset` and `topInset` in `OSDBannerService`, until the Crisp banner reads as the same family. Try `p.hasShadow = true` once: keep it only if the native capsule shows a comparable shadow. Rebuild with `make dev` and re-run Step 2 after each change.

- [ ] **Step 5: Volume and mute variants**

The Dell is not an audio output on this Mac, so the volume path cannot be driven by a key. Add a temporary line at the top of `OSDBannerService.show` for one build only:

```swift
        let image: OSDImage = level > 50 ? .volume : .mute  // TEMP: volume look check, remove
```

Run `make dev`, then `./brightness-key 2` and `./brightness-key 3` with the brightness above and below 50 percent, and crop as in Step 2.
Expected: speaker symbols with a filled track above 50, the slashed speaker with an empty track below. Press once above 50 and once below in a row: the track must keep the same length between the volume and the mute banner. Then delete the temporary line, `make dev` again, and confirm with one more `./brightness-key 3` that the sun symbols are back.

- [ ] **Step 6: All-displays mode with the lid open (Didrik)**

This needs the built-in panel online. Ask Didrik to open the lid, set Brightness Keys to the all-displays mode in Crisp's panel, and press F1 once. Expected: a banner on the built-in and on the Dell at the same time, each with its own name. Then `screencapture -x -D 1 a.png -D 2 b.png` is not needed; a photo or his word is fine. Record the result in the CLAUDE.md pending entry.

- [ ] **Step 7: Commit the tuning**

If any constant changed:

```bash
git add Crisp/Services/OSDBannerService.swift Crisp/Views/OSDBannerView.swift
git commit -m "Tune the OSD banner geometry against the native capsule

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016kcKMwzjxnj9MVvEndMKov"
```

---

### Task 5: Full local check and handoff

**Files:**
- Modify (local only, never committed): `~/code/Crisp/CLAUDE.md` pending entry for #76

- [ ] **Step 1: Run everything CI enforces that runs without Xcode**

Run: `make compile && SWIFTLINT_DISABLE_SOURCEKIT=1 swiftlint lint --strict && git diff --check`
Expected: build done, 0 violations, no whitespace errors. `make test` needs full Xcode and runs in CI on the PR; note that in the handoff.

- [ ] **Step 2: Confirm no new localization keys**

Run: `git diff main --stat -- Crisp/Resources/Localizable.xcstrings`
Expected: empty. The banner shows only the display name.

- [ ] **Step 3: Note the second glass surface in docs/DESIGN.md**

The element doctrine there says glass lives on the panel backdrop only. Add one sentence next to that rule: the OSD banner on macOS 26 is the second glass surface, an `NSGlassEffectView` capsule whose SwiftUI content sits directly on the glass, so the no-stacked-glass rule still holds. Commit it with the trailer:

```bash
git add docs/DESIGN.md
git commit -m "Note the OSD banner as the second glass surface in the design doctrine

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016kcKMwzjxnj9MVvEndMKov"
```

- [ ] **Step 4: Update the local CLAUDE.md pending entry**

Edit the `#76` bullet under "Pending: follow-ups" in `~/code/Crisp/CLAUDE.md` (the worktree file is a symlink; edit the source path) to say: implemented on `brightness-osd-overlay` as a Crisp-drawn glass capsule on macOS 26 (OSDBannerService, OSDBannerView), verified live on the Dell with screenshots, lid-open all-displays check done or pending, PR not yet opened. Keep the note that release notes and the #76 reply come after the merge.

- [ ] **Step 5: Stop and hand off**

Do not push. Report to Didrik: the commits on the branch, the before/after crops, what was verified and what was not (make test, lid-open check if he has not done it), and ask for the go-ahead to push and open the PR. The PR description and the later #76 reply are drafted with the `public-writing` skill only after that go-ahead.

### Task 6 (added after the live comparison): play the system HUD's entry and exit

Didrik's screen recordings showed the native capsule growing in with a fade while ours landed at full opacity in one frame, and a second look on a shared white backdrop showed six more differences (size and position, tone, label weight, insets, a dim track fill, missing ticks) plus the reveal anchoring: native settles down from above, ours grew from its centre. Everything measured is in the As built paragraph of the spec. `OSDBannerPanel.reveal(at:)` owns the frame, guards the entry with a deadline (a press inside the entry lets it finish), the scrim sits beside the hosting view and tints in on its own layer animation, and the SwiftUI content fills the hosting view so it follows the window through the grow. A third pass measured the drop curves of both capsules on the same white window frame by frame: the native entry runs about a frame longer than the first fit with a longer tail (fade 0.25 s, grow 0.35 s, tint 0.45 s), and its exit is not an ease-out at all but an exponential-like decay over 0.45 s that shrinks a little further than the entry grew from, so the exit has its own inset and a fitted bezier.

- [x] Constants on `OSDBannerService`, animation in `OSDBannerPanel`, scrim beside the hosting view, `hosting.sizingOptions = []`, flexible frame on `OSDBannerView`
- [x] Verified live on the Dell: single press and two presses 0.2 s apart, curves measured from screen recordings against the native ones, frame sheets compared by eye
- [x] Third pass: native and Crisp recorded on the same white window, entry and exit within one to two frames at every sample, ticks and track geometry confirmed at rest
- [x] Fourth pass: the bevel rim, fitted from native over black, grey and white and verified at rest and through the entry
- [x] Fifth pass: one fade for the whole capsule, 0.5 s on a fitted bezier, so the glass blur arrives on the native schedule (measured as local contrast over a grid backdrop)
- [x] Sixth pass: the glass itself. The public clear style is not the HUD's; the private variant 11 is (refraction on, no blur, no face), taken behind a macOS 26 guard and a responds-to check, with the scrim refitted to a flat grey
- [x] Seventh pass: that variant draws its own edge, a lens band and a dark ring down three sides, which reads as a grey outline. Oversize the sheet 40 pt and mask it back to the capsule, corner radius 26 continuous (fitted to the native corner), scrim refitted to the native tone line, bevel made additive, exit refitted (the masked build's tone is linear in the window alpha, the old one's was not)
- [x] Dark mode checked: the banner and the native capsule both ignore the system appearance
- [x] Commit
