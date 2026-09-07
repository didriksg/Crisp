# Design doctrine

Why Crisp looks and behaves the way it does, grounded in what Apple actually
documents. This is our core design reference: when a UI decision is unclear,
check it against the frame and element rules below before inventing something.

## What Crisp is

Crisp is a **trailing-side menu bar extra**: a status item on the right of the
menu bar (near the notch), not an app menu on the left and not a Dock app. It
runs as `LSUIElement` and its click opens a custom `NSPanel` styled as a
Control Center-class glass panel: brightness sliders, resolution and refresh
lists, presets, color, arrangement, virtual displays.

It is deliberately "too complex for a menu." That single fact decides most of
the design, because Apple documents a different pattern for that case than for a
simple menu bar dropdown.

## What Apple documents (the grounding)

Everything here is directly from Apple, and it covers more than we first
assumed. Sources are linked so the reasoning can be re-checked.

1. **The shape is sanctioned.** SwiftUI's
   [MenuBarExtra](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)
   `.window` style is described as: "For more complex or data rich menu bar
   extras, you can use the `window` style, which displays a popover-like window
   from the menu bar icon that contains standard controls. You define the layout
   and contents of those controls." That is Crisp's exact shape. We use a custom
   `NSPanel` instead of the SwiftUI scene (for positioning and glass control),
   but the design intent is the documented one.

2. **Menu vs popover.** The HIG menu bar extras guidance: a menu bar extra shows
   an icon, and uses a menu when the content is simple, a popover/window when it
   is too rich for a menu. Crisp is the rich case, so a panel is correct rather
   than an `NSMenu`.

3. **Menus.** The [Menus HIG](https://developer.apple.com/design/human-interface-guidelines/menus)
   gives the rules we reuse inside the panel: a **checkmark shows an attribute
   currently in effect**; use **icons sparingly, and all-or-none** within a
   group; prefer a **submenu or disclosure over indentation** for depth.

4. **Panels.** The [Panels HIG](https://developer.apple.com/design/human-interface-guidelines/panels)
   is the closest element-level guidance for what goes *inside* the panel:
   - "Use a panel to give people quick access to important controls or
     information related to the content they're working with."
   - "**Prefer simple adjustment controls in a panel.** Avoid including controls
     that require typing text or selecting items... Instead, consider using
     controls like **sliders and steppers**."
   - Prefer a standard panel over a HUD when you have real controls, because most
     system controls do not match a HUD's dark translucent look.

5. **Materials / Liquid Glass.** The Materials guidance: glass belongs on the
   **functional layer** (navigation, chrome), and the **content layer uses
   standard system materials**, not stacked glass. So the panel backdrop is
   glass; the content on it is not.

6. **Control Center controls.** The [Controls HIG](https://developer.apple.com/design/human-interface-guidelines/controls/)
   (macOS-supported) documents the only third-party Control Center surface: a
   single control tile (symbol + title + value) added via WidgetKit. It is *not*
   a spec for a custom multi-control panel.

## The gap (stated honestly)

Apple documents the **shape** (MenuBarExtra `.window`: a data-rich popover with
your layout and standard controls) and the **elements** (Panels: prefer sliders;
Menus: checkmarks and icon discipline; Materials: glass on the functional layer
only). Apple does **not** publish a spec for the Control Center-style
multi-module glass panel itself. That surface is private system UI. The
documented third-party analogs are the MenuBarExtra `.window` popover and the
single Control Center control tile.

So Crisp sits on the documented shape and dresses it to feel like Control
Center. That is legitimate emulation of system UI, and the point of this doc is
to keep the emulation honest: every element inside the panel should trace to a
documented rule (Menus, Panels, Materials), even though the overall Control
Center look does not have its own third-party spec.

## Element doctrine

What we do, and the rule it traces to.

- **Glass only on the backdrop.** The panel uses `NSGlassEffectView` (regular).
  Content sits on standard materials. The expanded display-detail region is a
  full-width shaded band (`Color.primary.opacity`), not a floating rounded card.
  *Materials HIG: content layer uses standard materials, no glass-on-glass.*
  The OSD banner on macOS 26 (OSDBannerService) is the one surface outside the panel that samples what is behind it, and it is not glass: no glass material can hold the system HUD's backdrop, which is softened far less than any of them soften it, so the banner blurs its own backdrop under a flat grey. The panel keeps the only glass in the app.

- **Selection is a one-click checkmark list.** Resolution, refresh rate, preset,
  and color profile are flat checkmark lists (leading checkmark column), not
  nested `.menu` pickers that cost two clicks. *Menus HIG: checkmark shows the
  attribute in effect; disclosure over indentation.* These are genuine discrete
  selections with no slider analog, which is why they are lists and not the
  sliders the Panels HIG prefers.

- **Adjustment is a slider.** Brightness and image adjustment use sliders. *This
  is the direct match to the Panels HIG "prefer sliders and steppers."*

- **Icons are uniform chips.** Section rows use 26pt circular icon chips
  consistently, satisfying the all-or-none rule rather than icons on some rows
  and not others. *Menus HIG: icons sparingly, all-or-none.*

- **Depth expands in place.** `ExpandableRow` with a chevron expands sections
  inline instead of pushing a second navigation level. *Menus HIG: disclosure
  over indentation/depth.*

- **Empty states are centered.** "No virtual displays yet" is centered, the
  native empty-state idiom, not an orphaned indented row.

- **Single editor at a time.** Preset editing is an accordion: opening one edit
  form closes any other. Matches how native inline editors behave.

## The deliberate exception

Preset names use a **text field**. This is the one element that runs against the
Panels HIG ("avoid controls that require typing text"). It stays because naming
genuinely needs free text and there is no adjustment-control equivalent for a
name. It is kept minimal (a single inline field), and it is a conscious
tradeoff, not an oversight. If a rename ever felt heavy, the honest move is to
make it rarer (rename on demand) rather than to pretend a slider could name a
preset.

## Open items

- The preset-name text field is the standing exception to the Panels HIG.
- The Refresh Rate section icon (`speedometer`) is the weakest glyph; a better
  symbol would tighten the icon set.
- ~~If SwiftUI's `MenuBarExtra` `.window` ever matches our custom panel on
  positioning and glass, migrating onto it would put Crisp on the exact
  documented path instead of emulating it with a custom `NSPanel`.~~
  Resolved August 2026: an isolated spike showed `MenuBarExtra` `.window`
  jumps during animated resize on macOS 26 at any duration, on top of its
  non-disableable materialize animation. The custom panel stays; its resize
  machinery is documented in `panel-resize.md`.
