# Views — SwiftUI View Layer

> Pure presentation and interaction. Do NOT write business logic in a View, do not call a Service directly.

## Structure

- **MenuBarView.swift** : main menu bar view, the container entry point for all features
- **DisplayDetailView.swift** : per-display expanded panel, a container for collapsible Sections
- Each Section corresponds to its own View file (BrightnessSliderView, ColorProfileView, etc.)

## File List

| File | Purpose |
|------|------|
| MenuBarView.swift | Main menu bar view + entry points for all Sections |
| DisplayDetailView.swift | Display expanded panel (12 Sections) |
| BrightnessSliderView.swift | Brightness/contrast slider |
| ResolutionSliderView.swift | Resolution slider |
| DisplayModeListView.swift | Resolution mode list (favorites pinned to top) |
| ArrangementView.swift | Display arrangement (distinguishes internal/external thumbnails) |
| ColorProfileView.swift | ICC Profile selection |
| SystemColorView.swift | System color configuration |
| ImageAdjustmentView.swift | Image adjustment (gamma/contrast) |
| VirtualDisplayView.swift | HiDPI virtual displays |
| NotchView.swift | Notch mask |
| MainDisplayView.swift | Main display settings |
| AutoBrightnessView.swift | Ambient-light auto brightness |

## Key Patterns

- `@EnvironmentObject var displayManager: DisplayManager` : injected globally
- `@ObservedObject` for shared singletons (do NOT wrap `.shared` with @StateObject)
- Row components needing hover/loading state -> extract as an independent `struct` (do NOT use a @ViewBuilder function)
- Component naming: reusable rows are `XxxRow` or `XxxRowView`
- Consistent hover effect: `.background(isHovered ? Color.primary.opacity(0.07) : .clear)`

## Change Checklist

- New Section -> edit DisplayDetailView.swift + check MenuBarView layout
- New tool entry -> edit MenuBarView.swift tools area
- New row component -> must be an independent struct, not a @ViewBuilder function
