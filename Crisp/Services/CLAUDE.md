# Services — Business Logic Layer

> System framework interaction layer, no UI. All Services are `@MainActor` singletons (`static let shared`).

## Responsibilities

Interact directly with macOS system frameworks (IOKit, CoreGraphics, ScreenCaptureKit, ColorSync),
providing a high-level API for Views/ViewModels.

## Key Patterns

- **Singleton + @MainActor**: all Services are marked `@MainActor final class: ObservableObject, @unchecked Sendable`
- **DDC communication**: DDCService is the low-level dependency for all external display features; Apple Silicon uses IOAVService
- **Sole gamma table writer**: GammaService owns write access to CGSetDisplayTransfer*
  - BrightnessService's software brightness writes indirectly through GammaService
  - Do NOT let any other Service/View call CGSetDisplayTransferByFormula/Table directly
- **CGHelpers.runWithTimeout**: blocking CG calls (apply settings, enableMirror) must be wrapped with this

## File List

| File | Purpose |
|------|------|
| DDCService.swift | IOKit I2C / IOAVService DDC communication low-level layer |
| DisplayManager.swift | Display enumeration, refresh, cross-Service coordination |
| BrightnessService.swift | Software brightness (writes via GammaService) |
| GammaService.swift | Sole writer of the gamma table |
| AutoBrightnessService.swift | Syncs external display brightness to follow builtin screen brightness (CoreDisplay API) |
| ResolutionService.swift | Resolution/HiDPI mode switching |
| ArrangementService.swift | Display arrangement |
| MirrorService.swift | Mirror mode |
| HiDPIService.swift | HiDPI detection and management |
| VirtualDisplayService.swift | CGVirtualDisplay creation/destruction |
| ColorProfileService.swift | ColorSync ICC Profile |
| NotchOverlayManager.swift | Notch mask overlay |
| SettingsService.swift | UserDefaults persistence |
| UpdateService.swift | App update detection |
| LaunchService.swift | Launch at login |
| CGHelpers.swift | CG blocking call timeout wrapper |

## Cross-Service Rules

- **Sleep/wake reapply order**: BrightnessService -> GammaService (Brightness is the data provider for Gamma)
  - AppDelegate listens for `NSWorkspace.didWakeNotification` -> calls reapply
- **C callbacks**: use `Unmanaged.passRetained(self)` paired with `release()`; do NOT use passUnretained
- **VirtualDisplayService**: HiDPI configuration is purely runtime (do NOT persist autoCreate to UserDefaults);
  `CGVirtualDisplay(descriptor:)` init must be called on the main thread

## Testing Notes

- DDC/IOKit features must be manually tested on an actual external display
- After VirtualDisplayService creates a display, verify `CGVirtualDisplay` is non-nil (vendorID must be non-zero)
