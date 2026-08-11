<div align="center">

<img src="docs/icon.png" width="128" alt="Crisp icon">

# Crisp

**Every display control macOS hides, in one menu bar panel.**

Free, open-source external monitor control for macOS.<br>
Sharp HiDPI scaling, DDC brightness, presets and virtual displays.

[<img src="docs/download-macos.png" alt="Download Crisp for macOS" width="180">](https://github.com/didriksg/Crisp/releases/latest/download/Crisp.dmg)

[![Downloads](https://img.shields.io/github/downloads/didriksg/Crisp/total?label=downloads&color=2f81f7)](https://github.com/didriksg/Crisp/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![License](https://img.shields.io/github/license/didriksg/Crisp?color=3fb950)](LICENSE)

[Website](https://didriksg.github.io/Crisp/) · [Crisp vs BetterDisplay & Lunar](https://didriksg.github.io/Crisp/crisp-vs-betterdisplay.html) · [Fix a blurry external monitor](https://didriksg.github.io/Crisp/fix-blurry-external-monitor-macos.html) · [中文](https://didriksg.github.io/Crisp/zh.html)

</div>

---

Crisp is a lightweight, native menu bar app for controlling external monitors on macOS, and a free, open-source alternative to BetterDisplay and Lunar. It adds what macOS leaves out: sharp HiDPI scaling on any monitor (no more blurry or tiny text), real brightness and volume control over DDC, presets, display arrangement, and virtual displays. Every feature is free, with no Pro tier and no license key.

Fully localized in English and Simplified Chinese (简体中文).

https://github.com/user-attachments/assets/90a62808-84d2-40d6-8563-0b282b9b4b6d

## Install

```sh
brew install --cask didriksg/tap/crisp
```

Or download [`Crisp.dmg`](https://github.com/didriksg/Crisp/releases/latest/download/Crisp.dmg) and drag Crisp to Applications. Every release is signed and notarized by Apple, so it opens with a normal double-click.

## Features

- **Sharp, Retina-quality scaling on any display**: HiDPI scaled resolutions that make external monitors crisp instead of blurry or undersized, set up automatically for 1440p and larger displays, and always at the panel's full refresh rate (no more 1080p stuck at 50Hz on a 144Hz monitor)
- **Smooth scaling**: fine-tune how large everything looks in small steps, well beyond the handful of scaled sizes macOS offers; the flexible scaling people install BetterDisplay for
- **Brightness everywhere**: controls the real backlight of external monitors (DDC), dims via software on monitors that don't support that, and can keep dimming below the hardware minimum. Smooth fades, and brightness keys that follow the pointer, target all displays, or a chosen subset
- **Extra Brightness**: push XDR MacBook panels and HDR monitors past 100% by unlocking their HDR brightness reserve, up to the panel's full headroom (the feature BetterDisplay sells as brightness upscaling). One toggle per display, then the normal slider and brightness keys simply reach further. Sustained maximum brightness increases power draw, and real HDR video can look overblown while boosted
- **Volume**: control the built-in speaker volume of external monitors over DDC, with a slider per display and the keyboard volume/mute keys mapped to the monitor when it's your audio output. Shows only for monitors that support it, and can be hidden entirely from Settings
- **Presets**: save named display configurations (resolution, brightness, arrangement) with custom icons and colors, apply with one click, update in place. Image adjustment (gamma, color temperature, contrast) is per-display and not stored in presets
- **Display arrangement**: drag-to-arrange canvas, main display switching
- **Disconnect displays**: turn physical displays off and back on from the menu, remembered across sleep/wake (Apple Silicon)
- **System toggles**: Dark Mode, Night Shift, and True Tone, one click from the menu bar
- **Color**: ICC profile switching, XDR reference presets, HDR on/off per display, and image adjustment (gamma, contrast, gain, invert colors)
- **Virtual displays**: create HiDPI virtual screens
- **Extras**: combined brightness slider, auto brightness following the built-in display, a toggle for macOS's own ambient auto-brightness, keep awake, notch hiding, launch at login

## How does it compare?

BetterDisplay and Lunar are excellent, deeper tools. Crisp keeps the everyday essentials free: flexible HiDPI scaling, hardware brightness, presets, disconnecting displays, color adjustments, and auto-brightness sync. See the full side-by-side: [Crisp vs BetterDisplay, Lunar & MonitorControl](https://didriksg.github.io/Crisp/crisp-vs-betterdisplay.html).

## Support

Crisp is and will stay completely free. Its main running cost is the $99/year Apple Developer Program, Apple's fee for signing and notarizing the app so it installs cleanly. If you've found Crisp useful, or it saved you a BetterDisplay or Lunar license, and you'd like to chip in toward keeping Crisp signed and notarized, there's:

- [GitHub Sponsors](https://github.com/sponsors/didriksg)
- [Ko-fi](https://ko-fi.com/didriksg)
- [爱发电 (Afdian)](https://ifdian.net/a/didriksg)

Completely optional, but you'll have my heartfelt thanks.

### Sponsors

Thank you to the people chipping in toward keeping Crisp signed and notarized:

- **Barry** ([@BarryBarrywu](https://github.com/BarryBarrywu))

## Requirements

- macOS 14 (Sonoma) or later; on macOS 26 the panel uses the native Liquid Glass backdrop

## Permissions

- **Administrator password** (one time, per monitor): needed only when you turn on smooth scaling, which installs a display override file into `/Library/Displays/Contents/Resources/Overrides` that macOS protects. Regular HiDPI scaling and everything else are password-free.
- **Accessibility** (System Settings > Privacy & Security > Accessibility): needed only if you turn on Brightness Keys, which routes the keyboard brightness keys to other displays (follow the pointer, all connected, or a chosen subset). Without it, everything else still works; the keys just control the built-in display as usual.

## Building

```sh
brew install xcodegen
xcodegen generate   # generates Crisp.xcodeproj from project.yml
open Crisp.xcodeproj
```

For a distributable DMG (Command Line Tools only, no full Xcode) and the fast edit-compile-run dev loop, see [docs/BUILDING.md](docs/BUILDING.md).

## Contributing

Issues and pull requests are welcome. Found a bug, want a feature, or have a display Crisp doesn't handle well? [Open an issue](https://github.com/didriksg/Crisp/issues) or start a [discussion](https://github.com/didriksg/Crisp/discussions). PRs are just as welcome, whether it's a fix, a feature, or a new translation.

## Origin

Crisp began as a fork of [FreeDisplay](https://github.com/huberdf/FreeDisplay) and has since been substantially rewritten: a custom panel architecture, native controls throughout, a reworked brightness pipeline, and a full redesign. Thanks to FreeDisplay for the foundation and the spirit: free display management for everyone.

## License

[MIT](LICENSE). Portions derived from FreeDisplay remain available under its MIT terms, reproduced in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
