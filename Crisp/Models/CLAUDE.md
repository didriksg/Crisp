# Models — Data Model Layer

> Pure data structures, ObservableObject.

## Files

| File | Purpose |
|------|------|
| DisplayInfo.swift | State model for a single display (high risk) |
| DisplayMode.swift | Display mode value type (resolution + refresh rate + HiDPI) |

---

## DisplayInfo.swift — High Risk

Core display model, has multiple `@Published` properties. **All Views and Services depend on this class.**

### Change Protocol

1. Adding/removing a `@Published` property -> `grep -r "DisplayInfo" Crisp/ --include="*.swift"` to find all references
2. Update all reference sites in sync (compiling successfully != logically correct)
3. `loadDetails()` is an async method, called on newly appeared displays in `DisplayManager.refreshDisplays()`

### Key Property Notes

- `displayID: CGDirectDisplayID` : hardware identifier, may change after hot-plug (not usable as a persistent key)
- `isBuiltin` : determined via `CGDisplayIsBuiltin()`
- `bounds` : from `CGDisplayBounds()`, needs refreshing after hot-plug/arrangement changes
- `name` : from `NSScreen.localizedName` (more reliable than IOKit vendorID)
- The `rotation` property was removed in Phase 21 (deleted along with RotationService/RotationView)

---

## DisplayMode.swift

Value type for a single display mode (resolution + refresh rate + HiDPI flag).

- `currentMode(for:)` static method gets the current mode
- `availableModes(for:)` gets the list of available modes (including HiDPI variants)
- Changes affect ResolutionService and DisplayModeListView

### HiDPI Notes

- HiDPI mode is distinguished via the `kIOScalingModeKey` flag, not simply 2x resolution
- Virtual displays' HiDPI mode is injected dynamically by VirtualDisplayService, not derived from DisplayMode
