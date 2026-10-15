// swiftlint:disable line_length
/// The agent skill that `crispctl skill show` prints and `crispctl skill install` writes.
/// Compiled in, so every release carries the skill that matches its commands.
enum CrispControlSkill {
    static let text = #"""
    ---
    name: crispctl
    description: Control displays on a Mac that runs Crisp through its crispctl command line tool. Use when the user wants to read or set display brightness, switch Extra Brightness or HDR, list displays, disconnect and reconnect a display, switch a monitor's input, change Image Adjustment (contrast, color temperature, gamma), list and apply saved presets, configure and inspect Crisp-owned virtual displays, or explicitly switch to a virtual-only headless desktop from a script, a shortcut or an agent.
    ---

    # crispctl

    `crispctl` drives Crisp, a macOS menu bar app for external monitors, from the command line. It talks to the running app over a local socket, so Crisp must be running for the same user; crispctl never launches it.

    ## Find the tool

    This skill comes from `crispctl skill install claude` (or `codex`), which writes the copy that matches the installed crispctl; run it again after updating Crisp. Run `crispctl version`. If the shell cannot find it, use the copy inside the app: `/Applications/Crisp.app/Contents/MacOS/crispctl`. The Homebrew cask and the Command Line Tool switch in Crisp's Settings both link it into `/usr/local/bin`. If the reply is exit code 1 ("Crisp unreachable"), ask the user to open Crisp; do not start it yourself unless they ask.

    ## Start here

    1. Run `crispctl help` once. It is the reference for the installed version, and `crispctl <command> --help` gives the detail for one command. Trust it over this file where they differ.
    2. Run `crispctl display list --json` and pick displays by `uuid`. Runtime ids change after an unplug or a wake; uuids do not.

    ## The contract

    Always add `--json`. Without it crispctl prints text for people, which can change between releases. With it, every call prints one JSON object: `{"ok":true,...}` or `{"ok":false,"error":"..."}`. Exit codes: 0 ok, 1 Crisp unreachable, 2 bad arguments, 3 Crisp refused (this includes "display not found").

    `display list` gives each display's `id`, `uuid`, `name`, `isBuiltin`, `resolution`, `brightness`, `maxBrightness`, `brightnessBackend` and `connected`. The backend is how Crisp sets brightness right now: `builtin` (also Apple displays such as the Studio Display), `ddc` (the monitor's own backlight), `software` (dimming in the picture, also used for HDR), or `unknown` while Crisp has not yet settled whether DDC works.

    ## Commands and their rules

    `brightness get <display>` and `brightness set <display> <percent>`: 0 to 100. A value above 100 works only while Extra Brightness is on and eligible, up to the live `maxBrightness`; anything past it is refused, not clamped. A set counts as a manual change, like the slider, and clears the active preset. The reply means Crisp took the request, not that the panel was read back.

    `brightness boost get|set <display> [on|off]`: Extra Brightness (the HDR headroom on XDR MacBooks and HDR monitors). `get` returns `eligible` and `enabled`, which can differ for a moment while capability changes. `on` is refused when the display is not eligible; `off` always works on a connected display. Turning it on for an external can take a few seconds while HDR settles.

    `hdr get|set <display> [on|off]`: only for externals that show Crisp's HDR toggle; the built-in panel and externals without HDR modes are refused. `set` reads the state back and says so if it cannot tell.

    `display disconnect|connect|toggle <display>`: the menu's Disconnect Display and Reconnect. Apple Silicon only. A disconnect that would leave no active display is refused. A display that Crisp holds disconnected is gone from every macOS list, so `display list` shows it with `connected:false` and its last-known id: address it by uuid. Asking for the state a display is already in succeeds and changes nothing. The reply can take a few seconds.

    `display input list <display>` and `display input set <display> <input>`: input select over DDC, the menu's Input row. `list` gives `inputs` (each a `value` and a `name`, from what the monitor reports, else a standard list) and `current`, the input this Mac is on, or null when Crisp cannot read it. The first `list` for a monitor reads its capabilities and can take half a minute. `set` takes a name (`HDMI 1`, `hdmi1`, `dp2`, `usb-c`) or a number, decimal (`17`) or hex (`0x11`). The monitor then shows the other computer, and Crisp disconnects the display so macOS frees its space; the reply's `connected` says whether it did (not on the last active display). `display connect <display>` brings it back and switches the monitor to this Mac. A `set` is refused when Crisp cannot read the Mac's input and nobody chose it in the menu.

    `image get|set|reset <display>`: Image Adjustment, the software sliders in the menu. `set <display> <setting> <value>` changes one: `contrast`, `gamma`, `gain`, `temperature` (-100 to 100, 0 is neutral; `temperature` -100 is 2000 K warm, 100 is 12000 K cool), `red-gamma`, `green-gamma`, `blue-gamma`, `red-gain`, `green-gain`, `blue-gain` (-100 to 100), `quantization` (2 to 256, 256 is off) or `invert` (`on`/`off`). Out of range is refused, not clamped. It is the same as moving the slider, so it clears the active preset. `reset` is Reset All. Every reply names the display (`displayID`, `uuid`, `name`) and returns all values; `get` also returns `paused`, true while the user has paused the adjustments in the menu. The display must be connected.

    `preset list` and `preset apply <preset>`: the presets saved in Crisp. `list` gives each preset's `id`, `name`, `captures` (what applying it changes: `resolution`, `brightness`, `arrangement`, `imageAdjustment`, `hdr`, `connection`), `displays` (the uuids it has settings for) and `active`. `apply` takes an id or a name in any case; a name two presets share is refused, so use the id. It is the same as clicking the preset in the menu. The reply comes after the preset is applied, and `skippedDisplays` lists the preset's displays that were not connected. A preset with `connection` turns displays on and off first, as Disconnect and Reconnect do, and a display it turns off is not listed as skipped. An apply while another one runs is refused.

    `status` and `virtual list`: read saved virtual configurations and actual runtime state without changing screens. `status` also reports `running`. Each entry's `config.id` is the stable configuration UUID; `displayID` is only a runtime diagnostic, distinct from a physical display's uuid. `saved`, `enableRequested`, `creating`, `retained`, `online`, `active`, `ready`, `resolution`, and `lastError` are separate facts. Missing `online` means enumeration failed. `ready` means saved, active, owned, readable mode and no creation in flight; it does not prove capture/input permissions, an unlocked session or HDMI-disconnected operation.

    `virtual configure <config-id> <name> <width> <height> <hidpi> <auto-create>` saves only. Generate a config UUID once with `uuidgen` and reuse it. Both toggles take `on` or `off`, hiDPI then autoCreate. Width 320–8192 and height 200–8192 are integer pixels. `virtual ensure <config-id>` activates or reuses that saved screen; repeated ensure must not add another. A same-size third-party screen is not a restored config. `autoCreate` restores on the next Crisp start in a logged-in session; it does not enable launch at login or prevent sleep. Changing active geometry requires disable first.

    `virtual disable <config-id>` releases only that config's owned screen and keeps its saved settings. Configure autoCreate off as well to stop next-start restoration. Deletion stays in the GUI. In-flight creation, including an apply that outlived its timeout, blocks writes for the same config. If the worker never finishes, arrange a controlled App restart. On failure, inspect the returned `virtualDisplay` and read `virtual list`; do not retry automatically. A development or read request does not authorize screen creation/removal. Only make the virtual-screen changes the user requested. Hardware acceptance requires a real screenshot, harmless click/input and a second screenshot to read the result back; mock results and exit 0 do not pass it.

    `headless status` reads the current session, `physicalOnline` (omitted when unknown), `virtualReady` and `lastError`. `status` includes the same `headless` object. Reads never enter or recover a session.

    `headless start <physical-uuid> <config-id>` is an explicit exception for the last physical screen on Apple Silicon, only when the named Crisp virtual screen is already ready. Both selectors must be UUIDs. Use it only when the user authorized that physical screen to go dark. It returns `headless.session.id`, phase `awaitingConfirmation` and `confirmBy` (Unix seconds). Within 30 seconds, verify the intended virtual desktop with an actual screenshot, harmless click/input and screenshot read-back, then `headless confirm <session-id>`. If verification fails, let it roll back or run `headless restore <session-id>`. Never confirm merely because start or status succeeded. Repeated start for the same live session neither writes again nor extends the trial; a stale confirmation token is refused. Repeat start is refused if the trial expired or the live display state is no longer ready.

    `headless restore <session-id>` restores only that session's physical screen and leaves the virtual screen. Normal `display connect <physical-uuid>` also ends the session. Confirmation does not disable recovery when the virtual screen stops being ready. The participating virtual config cannot be disabled or removed until the physical screen is restored. Normal App quit restores first; restart does not resume a headless session. A UUID-less external with no nonzero serial is refused by recorded-ID recovery. Native timeouts are uncertain: recovery waits for a late transaction, reports `recoveryFailed` when it cannot verify the physical screen, and keeps the virtual screen. Read status and arrange recovery before any retry. This mode supplies neither network access, sleep prevention nor lock/FileVault bypass.

    ## Safety

    Do not retry a command that changes state when its reply is lost or times out. It may have been applied. Read the state first (`display list`, `brightness boost get`, `hdr get`, `image get`, `preset list`, `virtual list`, `headless status`), then decide.

    A preset can change resolution, arrangement and HDR as well as brightness, and turn displays off. Only apply a preset the user named.

    A disconnect takes a screen away from the user. Only disconnect a display when the user asked for that display by name or uuid, and keep the ordinary last-screen protection. Only the explicitly authorized `headless` workflow above may turn off the last physical screen. An input switch takes the screen away the same way: only switch when the user asked for it.

    ## Examples

    ```sh
    # Dim every external to 40 %
    crispctl display list --json | jq -r '.displays[] | select(.isBuiltin | not) | select(.connected) | .uuid' |
      while read -r uuid; do crispctl brightness set "$uuid" 40; done

    # Toggle one monitor by uuid (a KVM or Stream Deck button)
    crispctl display toggle FF162E67-65FC-436E-8AF5-7D87A8F20A4F

    # Switch to the Night preset (from a Shortcuts automation or a launchd job at 21:00)
    crispctl preset apply Night
    ```
    """#
}
// swiftlint:enable line_length
