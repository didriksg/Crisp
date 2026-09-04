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

[Website](https://crispmac.app/) · [Crisp vs BetterDisplay & Lunar](https://crispmac.app/crisp-vs-betterdisplay.html) · [Fix a blurry external monitor](https://crispmac.app/fix-blurry-external-monitor-macos.html) · [中文](https://crispmac.app/zh.html)

</div>

---

Crisp is a lightweight, native menu bar app for controlling external monitors on macOS, and a free, open-source alternative to BetterDisplay and Lunar. It adds what macOS leaves out: sharp HiDPI scaling on any monitor (no more blurry or tiny text), real brightness and volume control over DDC, presets, display arrangement, and virtual displays. Every feature is free, with no Pro tier and no license key.

Fully localized in English and Simplified Chinese (简体中文).

https://github.com/user-attachments/assets/90a62808-84d2-40d6-8563-0b282b9b4b6d

## Install

```sh
brew install --cask crisp
```

Or download [`Crisp.dmg`](https://github.com/didriksg/Crisp/releases/latest/download/Crisp.dmg) and drag Crisp to Applications. Every release is signed and notarized by Apple, so it opens with a normal double-click.

Installed from `didriksg/tap` earlier? `brew upgrade` moves you to the main cask by itself; `brew untap didriksg/tap` afterwards is optional cleanup.

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

BetterDisplay and Lunar are excellent, deeper tools. Crisp keeps the everyday essentials free: flexible HiDPI scaling, hardware brightness, presets, disconnecting displays, color adjustments, and auto-brightness sync. See the full side-by-side: [Crisp vs BetterDisplay, Lunar & MonitorControl](https://crispmac.app/crisp-vs-betterdisplay.html).

## Support

Crisp is and will stay completely free. Its main running cost is the $99/year Apple Developer Program, Apple's fee for signing and notarizing the app so it installs cleanly. If you've found Crisp useful, or it saved you a BetterDisplay or Lunar license, and you'd like to chip in toward keeping Crisp signed and notarized, there's:

- [GitHub Sponsors](https://github.com/sponsors/didriksg)
- [Ko-fi](https://ko-fi.com/didriksg)
- [爱发电 (Afdian)](https://ifdian.net/a/didriksg)

Completely optional, but you'll have my heartfelt thanks.

### Sponsors

Thank you to the people chipping in toward keeping Crisp signed and notarized:

- **Arnor Ingthorsson** ([@arnor-ingthorsson](https://github.com/arnor-ingthorsson))
- **Barry** ([@BarryBarrywu](https://github.com/BarryBarrywu))
- **[@kuldipmaharjan](https://github.com/kuldipmaharjan)**
- **Volodymyr Dombrovskyi** ([@rebelvg](https://github.com/rebelvg))

## Requirements

- macOS 14 (Sonoma) or later; on macOS 26 the panel uses the native Liquid Glass backdrop

## Permissions

- **Administrator password** (one time, per monitor): needed only when you turn on smooth scaling, which installs a display override file into `/Library/Displays/Contents/Resources/Overrides` that macOS protects. Regular HiDPI scaling and everything else are password-free.
- **Accessibility** (System Settings > Privacy & Security > Accessibility): needed only if you turn on Brightness Keys, which routes the keyboard brightness keys to other displays (follow the pointer, all connected, or a chosen subset). Without it, everything else still works; the keys just control the built-in display as usual.

## Managed Macs

To keep Keep Awake off on company Macs, push a configuration profile for the `com.crisp.app` domain with `crisp.disableKeepAwake` set to `true`. Crisp reads it at launch and leaves the row out of Tools. A managed value outranks the user's own preferences, so it cannot be switched back on with `defaults write`.

## Automation

Source builds include a minimal `crispctl` target:

```sh
xcodegen generate && xcodebuild -scheme crispctl -configuration Release
```

It supports seven control commands:

```sh
crispctl display list
crispctl brightness get <display>
crispctl brightness set <display> <percent>
crispctl brightness boost get <display>
crispctl brightness boost set <display> on|off
crispctl hdr get <display>
crispctl hdr set <display> on|off
crispctl help
```

`<display>` is a runtime id or a uuid from `display list`. Ids can change after an unplug or a wake; uuids do not, so scripts should prefer them. `crispctl help` prints the reference (commands, output format, exit codes); point an agent at it before it does anything else.

`display list` reports each display's uuid, current resolution, logical `brightness`, logical `maxBrightness`, and brightness backend. The backend is Crisp's current route (`builtin`, `ddc`, `software`, or `unknown` while external DDC availability is undetermined); HDR software dimming reports `software`. Output is one JSON object per call.

Crisp must already be running; crispctl never launches it. `brightness set` accepts 0...100 normally. Values above 100 require Extra Brightness to be enabled and currently eligible for that display, and must not exceed its live `maxBrightness`; invalid boosted values are refused rather than clamped. A set is a manual change like using the slider and clears the active preset. The reply means Crisp accepted the request, not that the panel was read back; it is not retried automatically.

For example, `brightness boost get` returns `{"ok":true,"brightnessBoost":{"displayID":7,"eligible":true,"enabled":false}}`. `eligible` is the running Extra Brightness service's current eligibility result; `enabled` is its persisted per-display toggle state, so the two can differ while capability has collapsed and cleanup or auto-disable is pending. `brightness boost set` uses that existing service: `on` is refused when currently ineligible or when enabling fails, while `off` remains available for a connected display regardless of current eligibility. Enabling an external display may wait while the service settles HDR mode. Success means the service returned `true`, not that hardware, EDR headroom, or luminance was independently verified. A transport timeout does not prove the change was not applied; do not retry automatically—run `brightness boost get` first.

Maintainer's Approved Review note from #102: `brightness boost set <display> off` takes about 0.5 seconds to collapse. An immediate read during the transition may briefly show `brightness` above the current `maxBrightness`; scripts should wait, read again, and must not automatically retry. The collapse finally lands at 100 rather than restoring the pre-boost brightness.

`hdr get` and `hdr set` support only eligible external displays—the same displays for which Crisp shows its explicit HDR toggle. Built-in displays are explicitly unsupported; use Extra Brightness when it is eligible. Unsupported external displays are also refused. `hdr get` reads the authoritative live state from Crisp's existing `BrightnessBoostService`, not a persisted or cached preference. For example, a successful read returns `{"ok":true,"hdr":{"displayID":7,"enabled":true}}`.

`hdr set` calls that service's existing `setHDRPreference` path once, including its boost teardown and request-token race handling, then performs bounded live read-back. HDR writes fail closed when a unique live system display UUID cannot be verified. A successful verified set returns the same `hdr` JSON shape as get. Unsupported preflight requests and service refusals are ordinary failures. Only an accepted request that cannot be verified, a target lost during the operation, or a lost/timed-out response has an uncertain outcome; the command is not retried automatically, and scripts must run `crispctl hdr get <display>` before deciding whether to retry. Exit codes are unchanged: 0 for success, 1 when Crisp is unreachable or the response is invalid, 2 for bad arguments, and 3 when Crisp refuses or cannot verify the request.

The current public Crisp 1.5.0 release, normal DMG, and Homebrew cask do not include `crispctl`.

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
