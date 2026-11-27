# Native Underscan Notes

Technical findings, architecture, Apple Silicon safety constraints, HiDPI compatibility,
and recovery details for Crisp's Native Underscan feature.

## 1. Selected Native Underscan Mechanism (Verified vs. Unverified)

### Verified Facts (Empirically Checked on macOS 27.2.1 arm64 / Apple Silicon)

- **`MonitorPanel.framework`** (`/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel`),
  which Crisp already loads in `DisplayPresetService`, loads cleanly via `dlopen` on both
  Apple Silicon (`arm64`) and Intel (`x86_64`).
- `MPDisplayMgr` and `MPDisplay` expose Objective-C methods whose parameter and return types
  are verified at runtime using `method_getNumberOfArguments`, `method_copyReturnType`, and
  `method_copyArgumentType` before any `IMP` is invoked:
  - `-[MPDisplayMgr displayWithID:]` (`@` return, `i` argument)
  - `-[MPDisplay supportsUnderscan]` (`B`/`c` return, 0 extra arguments)
  - `-[MPDisplay minUnderscan]` (`i` return, 0 extra arguments)
  - `-[MPDisplay maxUnderscan]` (`i` return, 0 extra arguments)
  - `-[MPDisplay underscan]` (`i` return, 0 extra arguments)
  - `-[MPDisplay setUnderscan:]` (`v` return, `i` argument)
- Verified value scale on a connected external HDMI display (`43FHD_LCD_TV`, Apple Silicon):
  - `minUnderscan = 7500` (75.00% visible desktop area)
  - `maxUnderscan = 10000` (100.00% full screen / no underscan)
  - Observed live hardware readback: `underscan = 9621` (96.21%) while simultaneously running
    in a HiDPI scaled mode (`1168 × 657` logical, `2336 × 1314` backing, 60 Hz).
- **`CGDisplayIOServicePort` / IOKit `IODisplaySetIntegerParameter("pscn")`**:
  - Verified on Apple Silicon (`arm64`) that `CGDisplayIOServicePort` returns `0` (no legacy
    `IODisplayConnect` node exists on Apple Silicon DCP display pipelines). Therefore IOKit
    `pscn` parameter APIs are not usable on Apple Silicon.
- **`SkyLight` (`SLSDisplaySetUnderscan`, `SLSDisplayGetUnderscan`, `SLSDisplayGetUnderscanParameters`)**:
  - Exported in the dyld shared cache (`SkyLight.framework`), but their C ABI signatures are
    not publicly documented and not self-describing at runtime. Crisp deliberately does **not**
    invoke C functions with unverified signatures; all native calls go exclusively through the
    runtime-verified `MonitorPanel.framework` Objective-C compatibility layer.
- **`IOMobileFramebufferSetCanvasSize`**:
  - Undocumented private kernel user-client API without verified public signatures or user-app
    entitlements; not used.

### Unverified / Hardware-Dependent Behavior

- On computer monitors (such as an ASUS ProArt 2560 × 1440 monitor) connected over DisplayPort,
  USB-C, or HDMI with PC (non-overscanned) EDID timings, macOS on Apple Silicon often reports
  `MPDisplay.supportsUnderscan == false`.
- **Force-enable Native Underscan (Experimental)** exposes the native `MPDisplay.setUnderscan:`
  control for such external monitors after explicit user confirmation. Whether the underlying
  display controller honors `setUnderscan:` on a non-TV timing depends on the specific Mac SoC,
  macOS version, cable/port protocol (HDMI vs. DisplayPort vs. USB-C), and monitor EDID.
- Physical verification on the target ASUS ProArt 2560 × 1440 monitor across HDMI, DisplayPort,
  and USB-C has not yet been performed in automated CI/headless checks and requires manual
  on-desk confirmation.

## 2. Apple Silicon Getter Safety & Value Provenance

BetterDisplay community reports (e.g. discussion #2489) document that querying undocumented
underscan getters on Apple Silicon when underscan is force-enabled on an unsupported display
can trigger instability or crashes.

`MonitorPanelUnderscanBackend` enforces strict separation:

1. If `supportsUnderscan == false`, Crisp **never** invokes `minUnderscan`, `maxUnderscan`, or
   `underscan`. It uses defensive bounds (`7500...10000`, i.e. 75%–100%) and leaves
   `hardwareConfirmedPercentage == nil`.
2. Even when `supportsUnderscan == true`, hardware bounds are sanity-checked (`5000 <= min < max <= 10000`)
   before calling `underscan`, and readback values outside that range are discarded as unconfirmed.
3. The UI and model always distinguish three values:
   - **Requested**: the percentage selected by the user or restored from settings.
   - **Last Submitted**: the last percentage successfully dispatched to `MPDisplay.setUnderscan:`.
   - **Hardware-Confirmed**: populated **only** when safe readback succeeds; never fabricated.

## 3. Virtual Display Streaming Fallback Analysis

Streaming a virtual display into a scaled borderless window can simulate underscan on hardware
where Apple Silicon DCP refuses native underscan, but it requires Screen Recording permission
(`ScreenCaptureKit`), adds continuous GPU compositing overhead, and alters pointer/window
semantics. Because native `MonitorPanel` underscan requires zero extra permissions and works
natively on supported pipelines, Crisp does not enable or bundle a Screen Recording streaming
fallback.

## 4. Architecture & Persistence

- **`Crisp/Models/DisplayUnderscanIdentity.swift`**: Builds stable per-display keys from
  CoreGraphics display UUID, EDID vendor/model/serial fallback, and IORegistry physical channel
  location (`kIODisplayLocationKey`) when identical unserialized monitor models are attached so
  two identical displays never collide.
- **`Crisp/Models/UnderscanModels.swift`**: Value validation (`75%–100%`), basis-point scaling
  (`7500–10000`), capability/status enums, per-display `DisplayUnderscanSettings`, structured
  errors, and the mockable `UnderscanBackend` protocol.
- **`Crisp/Models/UnderscanStore.swift`**: `UserDefaults`-backed JSON persistence (`crisp.underscan.v1.displays`)
  plus safe migration of legacy `CGDirectDisplayID`-keyed entries for live displays only.
- **`Crisp/Models/UnderscanCoordinator.swift`**: `@MainActor` state machine handling slider
  throttling, per-display generation serialization, self-apply reconfiguration loop suppression,
  event-driven restoration (startup, sleep/wake, disconnect/reconnect, resolution/refresh/config
  changes), debouncing, bounded retries, automatic suspension after 3 consecutive failed restore
  cycles, experimental risk confirmation, and best-effort rollback countdown.
- **`Crisp/Services/MonitorPanelUnderscanBackend.swift`**: Runtime `dlopen` + Objective-C type
  encoding verifier running on a dedicated private serial queue so IPC never blocks the main
  thread or re-enters SwiftUI layout.
- **`Crisp/Services/UnderscanService.swift`**: App-wide singleton wiring Crisp's `DisplayManager`
  and `AppDelegate` lifecycle events into `UnderscanCoordinator`.
- **`Crisp/Views/UnderscanView.swift`**: Menu bar panel `UnderscanHeadBlock` / `UnderscanBodyBlock`
  under each external display's Picture group, plus per-display `AdvancedUnderscanSection`
  (Advanced Settings > Displays) and global `AdvancedUnderscanRecoverySection` (Advanced Settings > General).

## 5. HiDPI Compatibility

Native underscan adjusts scanout scaling without calling `CGConfigureDisplayWithDisplayMode` or
modifying display modes, refresh rates, color profiles, HDR, rotation, arrangement, brightness,
DDC, or mirroring. When the user switches logical HiDPI modes (e.g. `2560 × 1440`, `2048 × 1152 HiDPI`,
`1920 × 1080 HiDPI`, `1706 × 960 HiDPI`, `1280 × 720 HiDPI`) or refresh rates, `DisplayManager`
notifies `UnderscanService` after `.setModeFlag` completes and, if `Restore After Resolution Changes`
is enabled, re-applies the saved underscan after display stabilization.

## 6. Security, Memory Safety & Performance

- Zero new permissions: no SIP changes, no Gatekeeper changes, no Accessibility, no Screen
  Recording, no Full Disk Access, no privileged helper daemons, no telemetry or network traffic.
- All Objective-C runtime method pointers are verified by argument count and type encoding before
  `unsafeBitCast`, and `method_copyReturnType` / `method_copyArgumentType` allocations are freed
  immediately.
- Zero continuous polling: restoration is strictly event-driven with debouncing and bounded
  retries; slider drag writes are throttled (90 ms) and finalized on release.

## 7. Isolated Development Build & Recovery

Build an isolated app bundle (`com.reconditum.crisp`) without touching `/Applications/Crisp.app`:

```sh
./scripts/build-dev-isolated.sh
./scripts/build-dev-isolated.sh --launch
```

### Recovery Actions

1. **In Crisp UI (Per-display)**: Click **Reset to 100%** or **Disable Underscan** in the menu
   bar panel or Advanced Settings > Displays > Underscan.
2. **In Crisp UI (Global)**: Open Advanced Settings > General > Underscan and click **Disable All**.
3. **CLI Reset (Isolated Dev Build)**:
   ```sh
   defaults delete com.reconditum.crisp crisp.underscan.v1.displays
   ./build/underscan-probe --set <displayID> 100
   ```
4. **Standalone Read-Only Inspector**:
   ```sh
   swiftc -O -swift-version 6 -target arm64-apple-macos14.0 scripts/underscan-probe.swift -o build/underscan-probe
   ./build/underscan-probe --inspect
   ```
