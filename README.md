# Crisp

A native macOS menu bar app for managing external displays: HiDPI resolutions, brightness, arrangement, color, and presets. A free, open-source alternative to BetterDisplay: all the core display management features, zero cost.

https://github.com/user-attachments/assets/90a62808-84d2-40d6-8563-0b282b9b4b6d

<p align="center"><img src="screenshot.png?v=3" width="406" alt="Crisp menu bar panel"></p>

## Features

- **HiDPI on any display**: enable Retina-style scaled resolutions on external monitors, including automatic HiDPI setup for 2K+ displays
- **Brightness everywhere**: hardware DDC control for external monitors with software (gamma) fallback, smooth fades, brightness-key routing to the display under the cursor, and true darkness below the hardware floor
- **Presets**: save named display configurations (resolution, brightness, arrangement) with custom icons and colors, apply with one click, update in place
- **Display arrangement**: drag-to-arrange canvas, main display switching
- **Screen effects**: Dark Mode (with the system's animated transition), Night Shift, True Tone
- **Color**: ICC profile switching, gamma/contrast/gain image adjustment
- **Virtual displays**: create HiDPI virtual screens
- **Extras**: combined brightness slider, auto brightness following the built-in display, notch hiding, launch at login


## Install

```sh
brew install --cask didriksg/tap/crisp
```

Or grab `Crisp.dmg` from the [latest release](https://github.com/didriksg/Crisp/releases) and drag Crisp to Applications. The app is unsigned; on first launch, right-click Crisp.app and choose Open.

## Requirements

- macOS 15 (Sequoia) or later; on macOS 26 the panel uses the native Liquid Glass backdrop

## Permissions

- **Accessibility** (System Settings > Privacy & Security > Accessibility): needed only for routing the keyboard brightness keys to the display under the cursor. Without it, everything else still works; the brightness keys just control the built-in display as usual.
- **Administrator password** (one time, per monitor): the first time you enable HiDPI for a display, Crisp installs a display override file into `/Library/Displays/Contents/Resources/Overrides`, which macOS protects. Every later toggle is password-free.

## Building

```sh
brew install xcodegen
xcodegen generate   # generates Crisp.xcodeproj from project.yml
open Crisp.xcodeproj
```

`./build.sh` produces a distributable DMG (unsigned; right-click, then Open to bypass Gatekeeper). No Xcode? See [docs/BUILDING.md](docs/BUILDING.md) for a Command Line Tools-only build.

## Origin

Crisp began as a fork of [FreeDisplay](https://github.com/huberdf/FreeDisplay) and has since been substantially rewritten: a custom panel architecture, native controls throughout, a reworked brightness pipeline, and a full redesign. Thanks to FreeDisplay for the foundation and the spirit: free display management for everyone.

## License

[MIT](LICENSE). Portions derived from FreeDisplay remain available under its MIT terms, reproduced in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
