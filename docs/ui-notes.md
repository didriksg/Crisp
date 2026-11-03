# UI implementation notes

Measured detail behind tuned values in the Views layer, pointed to from short in-code comments so the code stays readable while the reasoning stays available to whoever changes the value.

## ArrangementView: verticalPullFloor bias

snapToDominantSide stacks displays vertically only when the drag is clearly more vertical than horizontal, using a 1.8 ratio bias between dy and dx, and only when the vertical pull is real, requiring the center offset to exceed half the shorter display's height (verticalPullFloor). Without that absolute floor a horizontal drag would briefly stack at the crossover point where dx is near zero, so any dy beats the ratio test alone. Native's Arrange Displays sheet only stacks once you distinctly pull one display up or down, which this floor matches.

## BrightnessSliderView: click-glide fade

A click on the brightness slider glides to the target over 200ms instead of jumping, matching how brightness keys and presets fade DDC externals. The coalescing writer paces the I2C bus at roughly 20 writes per second and drops steps it cannot take, so a 200ms fade costs only a handful of actual DDC writes. The slider thumb (and the combined slider's handle) is held at the target value while the fade catches up, released once display.brightness settles within 0.75 of it.

## BrightnessSliderView: control size by OS

Control Center's brightness slider grew on macOS 27: measured on its display panel the track is 6pt and the knob 16pt, against the 4pt track and 14pt knob that SwiftUI's .small control size draws. .regular matches the macOS 27 size, so the brightness sliders switch to .regular on macOS 27 or later and keep .small on macOS 26 and earlier.

## Color.secondaryReadable

The system .secondary color measures roughly 3.9:1 contrast on the light popover background, below the 4.5:1 WCAG AA minimum required at caption sizes. Dark mode measures roughly 5.8:1, comfortably within range, so secondaryReadable keeps the system color in dark mode and only overrides light mode, substituting NSColor(white: 0.40), which measures roughly 5.4:1 on the panel's 245-251 light material.

## DisplayModeController: mode relay

The mode relay in DisplayModeController's init subscribes only to display.$currentDisplayMode and display.$availableModes, not the whole DisplayInfo, because DisplayInfo's brightness publishes at roughly 125Hz during a click-glide, and re-rendering six hosting views per step, each regrouping a high-refresh monitor's roughly 100-mode list, was the source of the glide's jank.

## DisplayModeListView: beyond-cap resolutions

WindowServer refuses scaled backings above a per-display cap. On 5K2K ultrawides the sizes between the enumerable HiDPI ladder's top (looks-like roughly 3360 wide) and native exist only as 1x modes, for example 4608x1296, 4096x1152 and 3840x1080 on a U4924DW. These are what System Settings offers there, so resolutionGroups keeps native-aspect 1x sizes wider than every HiDPI mode instead of dropping them as clutter.

## DisplayModeListView: beyond-cap synthetic stops

WindowServer's per-display cap (#65) means the sizes between the enumerable ladder's top (looks-like roughly 3360 wide) and native have no real HiDPI mode at all. smoothModes mints synthetic slider stops for them on the same 16px grid, using NEGATIVE ids so they can never collide with a real ioDisplayModeID or reach the CG apply path: switchTo routes a negative id to MirroredModeService instead, which renders the size on a hidden virtual display that the panel hardware-mirrors and downscales on scanout. This is gated on the dense smooth-scaling ladder being live; MirroredModeService.beyondCapStops decides which panels get stops at all, empty on uncapped panels so the slider is unchanged there.

## DisplayModeListView: smoothModesPresent threshold

smoothModesPresent counts twinless hits on the injected grid rather than a share of the injected sizes, because WindowServer silently refuses scaled backings above a per-display cap: on a 5K2K ultrawide only about a third of the injected ladder ever materializes (up to looks-like roughly 3360 wide). Stock HiDPI sizes always carry a 1x twin while the injected in-between steps never do, so a handful (8 or more) of twinless grid hits means the ladder, or as much of it as the hardware allows, is live.

## PanelBlocks: BlockHost top-glue

BlockHost's AppKit host is a canvas fixed at the block's final height, but a nested curtain (Support, Brightness Keys, resolution lists) renders shorter mid-reveal; without the .top alignment fill, NSHostingView centers that shorter content vertically, so the block's top row visibly drops then floats back up as the curtain expands (observed as "inner menu top drifts" on open). Pinning the content to .top instead spills the excess height off the bottom, where the block's own clip hides it, so the top edge never moves. Do not add .fixedSize to this view: it collapses the frame back to the content's natural size and defeats the top-pin fill.

## SavePresetView: icon grid width

The icon row uses a plain HStack rather than a LazyVGrid because lazy containers reposition their items mid-flight during the panel's animated resizes. It is sized to fit within the panel's 242pt inner width: 8 icon buttons at 26pt plus 7 gaps at 3pt sum to 229pt, comfortably under that limit, so expanding the picker never forces the fixed 308pt panel wider.

## AppDelegate: expanded interface session (macOS 27)

On macOS 27 the menu bar draws status items out of process, and Crisp's item opens its panel through `NSStatusItem.expandedInterfaceDelegate` (#236). Before that, a clear panel one level above the menu bar sat over the icon to take its presses, so the system never lit its own wider press pill. That panel broke the menu bar's overflow control: when the icon is hidden in the overflow, macOS parks the item's window in the bar under the « control after a collapse (items that never fitted park at y −33 instead), and the clear panel followed the window there and took the «'s clicks. No in-process property tells an item that it is hidden: its window keeps `isVisible`, a visible occlusion state, alpha 1 and a screen in both places (measured 2026-10-24 on macOS 27.0.1). With the session the system lights the item itself and tracks it like a menu. Measured with a probe item and on Crisp: `statusItem(_:didBegin:)` arrives on the press, not the release; Escape ends the session; another app coming to the front does not; a click outside does not either, so the panel's own close calls `cancel()`; and a second click on the item reaches the app neither as an event nor as a callback, so the global click monitor closes the panel when the click lands on the item during a session (other apps adopting the API do the same). A right click never starts a session, also with the button's `sendAction(on:)` mask widened or an accessibility press, and Crisp's own drawn light cannot match the system's: the system draws 2 pt past the item window on each side, which a layer inside the window cannot reach. The private `-[NSSceneStatusItem _requestExpandedInterfaceSession]` asks the menu bar for the same session a left click starts, so a right click and the button's own action (an accessibility press) go through it and get the system's light; without it they open the panel the old way. The code is behind `#if compiler(>=6.4)` because CI builds on the macOS 26 SDK, which has no such API, so only a local build with Xcode 27 compiles that path.
