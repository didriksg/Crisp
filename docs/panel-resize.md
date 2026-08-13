# Panel resize: the split-canvas architecture

Why Crisp's menu panel animates height the way it does. Every claim here was
established by instrumented experiment (os.log traces, spike apps, forensic
probes) on macOS 26, on 120Hz and 165Hz displays, August 2026. Do not
"simplify" this code without rereading the failure map below; each rule exists
because its absence produced a visible jump.

## The problem

Expanding or collapsing a section must animate the panel's height with the top
edge pinned under the status item, the content below the toggling section
riding the bottom edge, and zero visible jumps, at native look (shadow, Liquid
Glass, click-outside close). Apple's own Control Center does this perfectly;
every public API path we tried did not.

## Why the public paths fail

- **MenuBarExtra(.window)**: jumps on single unspammed clicks at any animation
  duration (tested 0.16s / 0.25s / 0.35s in an isolated spike). Also carries a
  WindowServer materialize animation that cannot be disabled.
- **NSAnimationContext window animator**: an unsynced timer. Dropped steps
  render as visible skips, worse at shorter durations.
- **NSHostingView.sizingOptions = .preferredContentSize**: resizes via
  setContentSize (origin fixed, so the panel grows upward) and fights any
  attempt to re-pin the top edge, producing shake.
- **Hand-driven per-frame SwiftUI layout**: SwiftUI animates renders, not
  layouts; driving layout per frame makes icons and text shimmer.
- **Animating the window frame itself, at any cadence**: the WindowServer
  recomputes a transparent window's shadow from its alpha shape on EVERY
  setFrame. Measured at 5-9ms per frame against a 6.06ms budget at 165Hz;
  paints alternate 1- and 2-vsync gaps, which reads as shaking, and CA demotes
  the display link to 60Hz under the overrun (16.7ms gaps, 75pt painted steps,
  the classic jump). Declaring the window shape server-side via
  NSVisualEffectView.maskImage (the mechanism Firefox's vibrant menus use) was
  tried and produced backdrop re-snapshot flashes during resize on macOS 26.
- Control Center is immune because its animations run out of process. An
  in-process app's window resizes fight both the app's own main runloop and
  the WindowServer's per-frame shape work; that combination is the root cause
  of everything below.

## The architecture

Three independent pieces: a static window, a layer-animated shell, and block
heights measured once.

**Static window.** The NSPanel never resizes while an animation is in flight.
It is a transparent container larger than the visible panel (40pt side
margins, 48pt bottom margin, hosting the shadow), grown once to flight size at
animate start and tightened once at settle, both while the panel is visually
at rest, where a slow WindowServer transaction cannot paint a jump. The
window's own shadow is off; clicks landing in the transparent margins are
outside-clicks (PanelRootView closes the panel, matching native menus
consuming the dismissing click), and all outside-click and resign-key tests
use the visible shell's screen rect, not the window frame.

**Shell (the visible panel).** A rounded-clip container inside the window,
holding the glass backdrop, the block viewport, and the footer. The spring
animates the shell's frame per tick; the shadow is a sibling view whose
CALayer draws the menu shadow via an explicit rounded-rect shadowPath, resized
in the same Core Animation transaction, so shell, content, and shadow move
atomically and entirely GPU-composited. Per-tick cost measured at 0.0-1.6ms
(versus 3.5-5.3ms when the window frame animated), which fits any refresh
rate's vsync budget with no frame-rate pinning.

**Canvas (SwiftUI, static).** Every block (section headers, section row
groups, footer) is its own NSHostingView, rendered ONCE at full size. SwiftUI
never animates geometry; nothing re-renders during a resize. Blocks are
stacked by explicit integral frames each tick (cumulative rounding so sums
stay exact); a block's clip height animates between 0 and its content height.
Nested reveals INSIDE a block (Support, Brightness Keys, resolution lists)
keep the SwiftUI curtain at the matched 0.18s duration; the block reports its
height per frame and the spring retargets with velocity carry.

**FrameSpring (the driver).** A critically damped spring, closed form
`x(t) = T + (d0 + (v0 + w*d0) t) e^(-w t)` with `w = 2*pi/duration` (0.18s),
stepped by a CADisplayLink and applied as the shared progress scalar for every
changing clip. Retargets carry velocity, so mid-flight direction changes are
C1-continuous.

## The failure map

Every rule, with the observation that forced it:

1. **Never anchor animation to wall time at start.** The first display-link
   tick after a click arrived 74.2ms late (runloop busy processing the click);
   a wall-time spring then teleported 82pt in the first painted frame.
2. **Never create the display link on demand.** A freshly created link's first
   callback arrived 65.9ms late, rendering as freeze-then-24pt-step even with
   gap clamping. The link is created once at panel warm-up; idle ticks are
   no-ops. It IS recreated when the panel opens on a different screen (a link
   latched to a 120Hz screen feeds a 165Hz screen unevenly). While the panel
   is hidden the link is PAUSED (not invalidated): the object survives, and
   unpausing at showPanel (in-flight animations only start on a later user
   toggle) gives it the same warm-up window the recreate-at-open path relies
   on, without paying vsync wakeups all day for a closed panel.
3. **Advance the spring by wall time clamped to a 21ms catch-up window.**
   Frame-paced time (one refresh period per tick) ran at HALF speed through
   sustained lower-rate stretches and snapped to full speed on recovery, which
   read as a jump; unclamped wall time teleports after a stall. The clamp is
   temporally correct on single misses and cannot teleport.
4. **Set only integral frames.** AppKit re-rounds fractional frames
   asynchronously (we set 280.3, the frame read back 281.0), so sub-point sets
   fight the rounder near the settle tail. The spring computes continuously
   and rounds at apply; anchors round once at animate.
5. **Measure block heights only after a forced layout pass.**
   `NSHostingView.fittingSize` straight after init is nondeterministic; one
   launch measured section A's rows at section B's height, creating a 56pt
   debt collected as a visible jump two toggles later. `layoutSubtreeIfNeeded`
   before `fittingSize`, and re-measure on every panel open.
6. **Pre-paint every block during warm-up.** Rows that have never been drawn
   paint their first reveal a frame late (a flash of empty glass). The
   invisible warm-up grows the window, opens all sections off screen, forces
   one display pass, then closes them.
7. **Capture animation targets at animate start.** Per-tick math must never
   read live block targets: a mid-flight toggle flips them synchronously, and
   interpolating toward a new target with the old progress teleports the block
   in one frame (video-confirmed insta-close). Mid-flight changes re-anchor
   through a new animate with velocity carry.
8. **Never disable postsFrameChangedNotifications on block ancestors.**
   NSHostingView listens for ancestor frame changes to keep its
   window-coordinate mapping fresh; without them, hit zones go stale after
   blocks move (click dead zones near the panel edges).
9. **Set safeAreaRegions = [] on every block host.** Blocks abutting the
   window's top/bottom edge otherwise get a phantom safe-area inset: content
   shifts inside the host while the AppKit frame stays put, so clicks land
   ~12pt off and the inset flips with window height (spurious height reports,
   visible as jumps).
10. **Keep per-frame work out of the WindowServer entirely.** Both window
    shadow recompute (5-9ms) and window setFrame (2-5ms even shadowless,
    display: false) are WindowServer transactions; any of them per tick
    eventually misses vsync, and an uneven step cadence is what the eye reads
    as shaking. Window geometry changes happen only at rest; flight frames
    are pure Core Animation.

## Validation

Spike app (`Spike2`, scratchpad, not in repo) validated the block machinery:
135 animations / 3032 ticks of adversarial spamming with zero painted steps
off-curve. The static-window migration was validated in Crisp itself under
forensic logging: spam sessions with rapid mid-flight reversals produced zero
missed ticks and no off-curve steps, and hand-testing on a 165Hz display could
no longer provoke a jump. The MenuBarExtra control spike (`Spike`) documents
that the standard path jumps on this hardware, closing the question of
migrating onto MenuBarExtra.
