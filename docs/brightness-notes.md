# Brightness field notes

Reasoning, timings and tuned values behind gamma, Extra Brightness (EDR), CoreBrightness and auto brightness; read before changing a threshold, duration or fallback order in those areas.

## Gamma and software brightness

`GammaAdjustment`'s sliders map to `CGSetDisplayTransferByTable` inputs: gamma exponent is `2^(-slider/100)` (0 to 1.0, +100 to 0.5/brighter, -100 to 2.0/darker), gain is `1 + slider/100` (0 to 1.0, +100 to 2.0, -100 to 0.0), contrast shifts the output range by `slider/250` (+-100% to +-0.4), and color temperature (Tanner Helland algorithm) normalizes to 6500 K at 0. Inversion swaps each channel's min and max.

`GammaService` builds the transfer table by hand instead of calling `CGSetDisplayTransferByFormula`: that API forces min/max into [0,1] with min<=max, which silently drops inversion (min>max), positive gain (max>1) and positive contrast. Sampling the curve into `CGSetDisplayTransferByTable` and clamping per entry (instead of clamping the endpoints up front) honors all three; clamping the endpoints would pin the max to 1.0 and no-op gain and contrast above 0.

`BrightnessService.setSoftwareBrightness` is the DDC-unavailable fallback: a linear ramp from 0 to a factor floored at 0.05 (so black never goes fully black), scaled past 1.0 above 100% (the external boost region, monitor in HDR mode) to push SDR content into the HDR wire range for the monitor to tone-map. Below `gammaBlendThreshold`, a gamma dim layers on top of the DDC write too, because DDC 0 on most monitors is "minimum backlight" and still visibly bright; gamma (with its own 5% floor) covers the rest of the way to dark.

A DisplayHDR monitor owns its luminance and silently discards DDC brightness writes while still acking them, leaving 15-100% of the slider dead with nothing to detect (see docs/ddc-notes.md). `BrightnessService.hdrDimmedDisplays` routes a flagged display's whole 0-100 range to software gamma instead; `BrightnessBoostService` maintains the flag (HDR toggle, boost's own auto-switch, and reconfiguration sync).

The DDC-write-failure latch to software gamma waits for three consecutive failures, not one: a single flaky write must not flip a display mid-drag (DDC and gamma dimming stack and then visibly "reset"), and the monitors that need the fallback drop about half their commands at random (docs/ddc-notes.md, AOC).

Gamma adjustments and the software brightness factor are both persisted under the display's stable UUID, not its `CGDirectDisplayID` (issue #32): macOS can reassign the ID across reboots and reconnects, and a raw-ID key would hand one physical display's saved state to whatever display inherits its old ID next.

`GammaService` also reapplies every active adjustment in direct response to ColorSync's distributed profile-change notifications, because the post-wake ICC restore is the prime suspect for the gamma table getting clobbered (issue #25); this is the event-driven complement to periodic wake passes elsewhere.

## Extra Brightness (EDR boost)

Brightness above 100% maps to an EDR overlay factor on the built-in (`EDROverlayManager`) or a display-transfer-table factor on externals (`BrightnessBoostMath.externalBoostCeiling`; externals don't get an EDR overlay), switching an external into HDR mode first if it isn't already.

The EDR overlay is a fullscreen, invisible, click-through window per display showing a uniform EDR color (value > 1.0) through a `CAMetalLayer` with a "multiply" compositing filter. WindowServer only honors that filter while the window keeps presenting: about a second after the last present it promotes the window to direct scanout and drops the filter, which would show the raw near-white EDR clear color. So the overlay renders continuously at 5 fps for as long as it exists, not just when the factor changes, and it sits at the shielding level (`CGShieldingWindowLevel`) so WindowServer's idle-promotion never gets a chance to matter; this is the same technique the open-source BrightIntosh uses.

Render calls are coalesced: drag events and the fast headroom poll can call `render()` at up to 120 Hz, the drawable pool holds 3, and capping outstanding presents at 2 keeps `nextDrawable()` always free without ever stacking unretired drawables (this fixed the original above-100% slider lag). If presents stop landing (display asleep mid-flight), the counter resets at most once a second so the keep-alive is never silenced forever.

Frame self-heal: an HDR flip's reconfiguration can move a screen while the one `didChangeScreenParameters` notification fires mid-transition, leaving the overlay parked over a NEIGHBORING display (seen as a multiplied strip on one monitor while boosting another). `render()` re-aligns the window's frame on every tick instead of trusting a single notification.

Timings: the overlay window, once created, stays alive even at factor 1.0 (identity), because closing and reopening the EDR surface exits and re-enters EDR mode and can visibly flash the display. The slider's max-brightness range animates over 0.2 s. The disable collapse (brightness and maxBrightness gliding back to 100 together) runs 0.35 s from one combined progress animator; an earlier two-phase version (fade brightness to 100, then collapse maxBrightness) made the slider thumb visibly drop then rise. Switching an external into HDR mode gets 2 s for WindowServer to resync before boost checks headroom. The EDR surface closes 2 s after everything is static, since closing mid-motion is what caused the flash.

The headroom poll runs at 500 ms normally, 16 ms for 3 s after a display first enters the boost region (macOS ramps EDR headroom over the next second or two, and 500 ms chunks read as laggy, steppy brightness right when the user pushes past 100). It auto-disables boost 1.5 s (wall clock) after `potentialHeadroom` drops at or below the ready threshold, to ride out transient dips during mode-change storms (HDR turned off, or a HiDPI switch dropping HDR advertisement).

A half-engaged HDR switch (preference recorded but the mode never actually applied) leaves the OS rendering HDR into an SDR link and washes the screen out; if an attempt that switched HDR on then finds no usable headroom, it rolls that mode switch back itself. A user-set HDR mode (one boost didn't switch on) is always left alone.

On reconfiguration, the HDR-capability cache and DDC channel pairing both flush, and `reapplyAll` runs once, 1 s after the notification (mirrors the panel's own debounce, since mid-reconfig geometry and headroom reads are garbage). Neither wake nor reconfig auto-disables a lost-headroom display inline, because those reads are unreliable single samples; the headroom poll owns auto-disable, with its own debounce.

`hdrSupportCache` exists because MPDisplay's HDR-capability read is a synchronous WindowServer round-trip (`SLSDisplaySupportsHDRMode`), and the HDR toggle view's body hits it on every render, up to 125x/s during a brightness glide; the cache clears only on screen reconfiguration, the only time capability or displayID assignment can change.

On quit, overlays are simply dropped (they die with the process). HDR mode is left exactly as the user set it: it is an explicit per-display toggle, and boost no longer silently reverts it on exit.

## BrightnessBoostMath

`BrightnessBoostMath` is the pure mapping layer behind Extra Brightness, kept free of AppKit so `scripts/check-boost-math.swift` can compile it standalone.

`sliderMax` treats `potentialHeadroom` at or below 1.05 as noise, not real EDR capability, and leaves the slider ceiling at 100 there. Above it, the ceiling is capped at 200% of the native range: this gives the boost region the same track length as 0-100%, so the exponential factor mapping below spends whatever real headroom the panel has perceptually evenly across that fixed length instead of a wildly different length per display.

`overlayFactor` maps the boost region (100...sliderMax) exponentially onto 1.0...currentEDR (factor = headroom^t) rather than linearly, because perceived luminance is roughly logarithmic: equal slider steps should give equal brightness ratios (exposure-stop style), not equal absolute nits. Calibrated on hardware: the built-in XDR panel renders its full reported headroom (about 4x) clean, so the live `currentEDR` is trusted as the honest ceiling, and the caller's headroom poll re-syncs it as macOS lowers it under ABL and thermals.

Below `hdrReadyThreshold` (1.05), the panel hasn't ramped EDR yet, so the full target factor would clip; `overlayFactor` returns `pendingHDRBrightnessFactor` (1.12) instead, a small nudge above 1.0 that is itself what prompts macOS to start ramping EDR headroom. That nudge only makes sense while the display still advertises EDR potential, so it is gated on `potentialHeadroom`, not `currentEDR`: a display genuinely back in SDR (`potentialHeadroom` at or below `hdrReadyThreshold` too) returns 1.0 instead of a nudge that can never ramp and would sit there washing the screen out.

External HDR boost does not use the EDR overlay at all: it scales the display transfer table instead (BetterDisplay's method for these displays), because on third-party monitors the OS-reported live headroom is not trustworthy. Measured on an external HDR monitor: `potentialHeadroom` read a pinned 1.2 while a 2.87x gamma table scale was delivering real, visible extra brightness. Trusting the reported headroom would have hard-clamped the overlay factor at 1.2, crushing near-white detail for almost no gain; the display transfer table has no such ceiling, and values above 1.0 are honored while the monitor is in HDR mode.

`externalBoostCeilingLuminance` (4.0) is defined in LINEAR luminance, the same units as the built-in's EDR factor (4.0 = two exposure stops at slider max), so the two paths are calibrated on a comparable scale. But the transfer table applies BEFORE the panel's own transfer function, in the table's ENCODED domain, not linear luminance: an encoded scale k multiplies mid-tone luminance by roughly k^2.2 (`externalDisplayGamma`), not by k. `externalBoostFactor` converts the linear ceiling to the encoded domain (raising it to 1/2.2) before applying the exponential ramp. Choosing a table top directly in the encoded domain overshoots badly: 2.5 there is about 7.5x luminance, and an observed 2.87 is about 10x, both far past what the panel's fullscreen brightness limit lets whites actually do, which is what reads as washed out.

## CoreBrightness (Night Shift, True Tone, Dark Mode)

Implemented via CoreBrightness's private `CBBlueLightClient` (Night Shift) and `CBTrueToneClient` (True Tone), plus SkyLight's `SLSGetAppearanceTheme`/`SLSSetAppearanceTheme` (Dark Mode), all loaded at runtime with dlopen + NSClassFromString/dlsym per project convention, since the private frameworks aren't linked.

Published state stays live while the panel is closed, so it opens already correct: Dark Mode changes arrive via the distributed `AppleInterfaceThemeChangedNotification` (posted by Control Center and System Settings), Night Shift and True Tone via a CoreBrightness status-change block registered on each client. `refresh()` itself runs its XPC reads off the main thread. True Tone's `available` flag is re-checked on every refresh because it flips with the lid: `CBTrueToneClient` reports `available == false` in clamshell, and Crisp may have launched lid-closed.

`setDarkMode`'s crossfade goes through AppKit's private `NSGlobalPreferenceTransition`, the same path System Settings and Control Center use (a plain SLS notify, or System Events, flips instantly with no fade). Acquiring the transition BLOCKS in the window server while it snapshots every display, so the whole dance runs off the main thread; the toggle control itself still renders instantly, like the native control. A 120 ms delay before acquiring the transition lets the flipped, re-tinted control reach the screen first, since the transition's snapshot must capture it already released (the control flips instantly, so one frame-commit beat is enough). `refresh()` never overwrites an optimistic Dark Mode toggle for 3 s after `setDarkMode`, because the async theme change may still be in flight and a stale read would snap the button back for a beat, which the native control never does.

`reassertTrueTone` exists for issue #131: after a full wake, macOS computes True Tone against the built-in panel while an external is still training its link, and the external keeps the wrong tint until True Tone is toggled off and back on. The two calls need roughly a 0.3 s beat between them or CoreBrightness folds them into a no-op. State is read live, never from the published value, so a stale read can't switch True Tone on for someone who has it off.

## Auto brightness

`AutoBrightnessService` reads the built-in display's brightness (which macOS auto-adjusts from ambient light) and syncs it to external displays, avoiding the need for Intel-only LMU hardware access.

Reading the built-in level tries three APIs in order. `DisplayServicesGetBrightness` is the only one that tracks the real live brightness on current macOS: trust its success code and accept 0 as a genuinely dark panel; do not fall through to the next API on a dark-but-successful read. `CoreDisplay_Display_GetUserBrightness` is pinned at 1.0 on macOS 26 (probe: slider changes moved DisplayServices 0.97 to 0.72 while CoreDisplay stayed 1.0), so treat it as stale there; it may still work on older systems. `IODisplayGetFloatParameter` over IOKit service matching is the last resort. Falling through to a stale API on a dark-but-successful DisplayServices read used to report a bogus 100% and flip externals up when the built-in bottomed out; reporting unavailable instead lets externals hold.

Relative mode (default) keeps each external at a fixed percentage offset from the built-in and rides its changes. Absolute mode mirrors the built-in's slider percentage directly; it is the pre-relative-mode behavior, preserved for upgraded installs that had Auto Brightness on before `relativeMode` existed, so they are not silently switched to relative offsets. Toggling relative mode on, or enabling auto brightness, re-pins every display's offset from its current level so nothing snaps.

Absolute mode actually derives DDC percent from estimated nits, not equal slider percentages, because the built-in's brightness curve is highly nonlinear; it uses the same built-in/external nits calibration as Combined Brightness. Relative mode adds a captured offset to the built-in's slider percentage, clamped to the display's own ceiling rather than a literal 100, since Extra Brightness can place the target above 100 and clamping at 100 would silently drag a boosted display back down on every built-in change.

Timings: the built-in is polled every 2 s as a fallback heartbeat, backed by a live push the instant DisplayServices reports a change so externals don't trail the poll. An apply only fires when the built-in moved more than 2%, or is forced by a relative/absolute mode toggle. A manual external adjustment holds for 30 s in absolute mode before auto-sync can override it again; relative mode instead absorbs the adjustment into the offset immediately. Each external glides to its new target over 0.4 s, matched to the DDC write pacing floor; a longer duration tuned for an earlier 2s-only poll made externals visibly trail the built-in.

Manual-adjustment notifications are posted synchronously (on the calling thread, not queued to main) so the offset or rebaseline flag lands before the next scheduled apply reads it; without that ordering, the 30 s absolute-mode cooldown was only masking the underlying race.
