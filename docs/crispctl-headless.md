# Explicit virtual-only desktop

This adds a session-only exception for a user who deliberately wants the last
physical screen off while keeping a Crisp-owned virtual desktop. It requires
Apple Silicon. Ordinary `display disconnect`, presets, input switching and the
GUI Disconnect row keep their last-physical-screen guard.

## Commands

Crisp must already be running in the logged-in user's graphical session. First
save and ensure a [virtual configuration](crispctl-virtual-displays.md), then
verify the actual mode and capture/input path. Keep its configuration UUID and
the physical screen's UUID from `display list`; runtime display IDs are not
accepted as headless selectors.

```sh
crispctl headless status --json
crispctl headless start <physical-uuid> <config-id> --json
# Verify screenshot, harmless click/input and screenshot read-back NOW.
crispctl headless confirm <session-id> --json
# When returning to the physical screen:
crispctl headless restore <session-id> --json
```

Start requires exactly one active physical screen, with that UUID, and an
already-ready virtual configuration owned by Crisp. It does not create a
virtual screen or choose another physical screen. The physical disconnect runs
through the existing serialized service and rechecks virtual readiness after
waiting for DDC. A recovery record is saved and read back through UserDefaults before the native
write (not a disk fsync guarantee). When macOS
hides the disabled screen even from the full list, recovery may use its recorded
runtime ID only while the captured vendor/product/serial/built-in descriptor
still matches and that ID does not enumerate as another screen. An unknown
hardware descriptor or a UUID-less external screen with no serial is refused; only actual online UUID read-back completes
recovery.

The reply's `headless.session` contains a new `id`, the two selectors, `phase`
and, during the trial, `confirmBy` as Unix seconds. Use that exact session ID
for confirm/restore. Confirm within **30 seconds after start completes** or
the service attempts to restore the physical screen. Repeating start for the
same live session does not issue another write or extend its deadline. Starting
another session while one is active or recovering is refused. A repeat is also
refused if the trial expired or its current display state is no longer ready. Stale confirmation
tokens are refused. The deadline is enforced with a monotonic clock.

Confirmation records the caller's acceptance; it cannot verify a remote client
or capture tool. Do not confirm from an exit code or online state alone.
Disconnecting the remote client does not end the confirmed session.

## State and recovery

`headless status` and the `headless` member of `status` report:

- `session`: absent before a session; otherwise its identity and phase:
  `entering`, `awaitingConfirmation`, `active`, `restoring`, `restored`, or
  `recoveryFailed`.
- `physicalOnline`: actual online enumeration of the named physical UUID;
  absent when there is no session or enumeration failed.
- `virtualReady`: the named configuration's current owned, online, active,
  readable-mode state, using the virtual-display identity checks.
- `lastError`: the last recovery reason or failure, including after restoration.

Reads do not enter, confirm or restore a session. A successful read means the
query succeeded, not that the session is active. Neither field proves that a
remote connection is reachable, a screen can be captured, a session is unlocked,
or the Mac will stay awake. Use `--json` in scripts; the existing JSON envelope
and exit codes are unchanged.

During the trial and after confirmation, the service checks every 500 ms. Loss
of virtual readiness triggers restoration; an unexpected physical return ends
the session through the same recovery path. The participating virtual screen
cannot be disabled, removed or geometrically edited through Crisp until the
physical screen has been restored. Name/autoCreate configuration changes do not
release the live screen. Refused GUI changes use the existing temporary error
message rather than adding a permanent panel row or another dialog.

`headless restore` or ordinary `display connect <physical-uuid>` restores only
that physical screen and keeps the virtual desktop. Repeated restore of the
same restored session changes nothing. Normal App quit waits for verified
physical recovery before releasing its virtual screens; an unverified recovery
cancels the quit. A crash does not preserve a live headless exception: the
existing saved-disconnect recovery applies on the next launch. This is not a
display or recovery service before user login.

A native timeout is uncertain. The App tracks completion beyond its waiting
wrapper and does not issue the opposite headless write while that transaction
is still running. Recovery waits up to 30 seconds for completion; if it remains
pending, state is `recoveryFailed` and recovery is revisited once completion is
observed. A known failed recovery is not retried in a blind loop. The virtual
screen remains protected. Refresh status before deciding to retry; keep a
physical reconnect/relaunch route available. Reconnecting a physically unplugged
monitor cannot be accomplished by this command.

Keep Awake, system sleep settings, network access, login/FileVault/lock control
and screenshot/input tools are outside this change.

## Controlled device check

Build both App and CLI from this branch, back up the installed bundle and
preferences, and arrange an independent recovery route. Confirm no unrelated
display changes are in progress. Use one disposable virtual configuration and
record the original physical UUIDs, modes and held-disconnect records.

1. With the virtual config saved but offline, require start refusal and unchanged
   physical topology. Ensure it, and require the ordinary last-screen disconnect
   to remain refused.
2. Start the explicit session. Independently enumerate displays: the named
   physical screen must be offline and the same owned virtual screen online.
   Repeat start and require the same session/deadline and no extra screen.
3. Do not confirm. Require the physical screen to return after the trial and
   `restored` state. A stale token must not confirm a later trial.
4. Start another trial, take a screenshot of a disposable window, click a harmless
   control, type a marker and take a second screenshot to read it back. Confirm
   that session. Require virtual disable refusal while it is active.
5. Restore and verify the physical UUID/mode and original held-disconnect records.
   Separately confirm a trial, quit normally, and require physical recovery before
   the virtual disappears. Reopen without resuming the headless exception.
6. Restore the physical screen before removing the disposable virtual config.
   Preserve unrelated preferences and saved-disconnect records.

Real WindowServer failures, very late commits, forced process death and physical
hotplug are separate coverage. Tests or a successful CLI exit do not establish
those hardware results. See the draft PR for the executed local device evidence.


## Local validation (2026-10-16)

On the current MacBook Pro (macOS 27.2 beta), the App/CLI compiled, passed
`make check` (193 tests, strict lint, x86_64 typecheck and 276 localization
keys), and were installed with matching artifact hashes and verified signatures.

- Offline virtual config: refused with unchanged physical topology. Ordinary
  last-physical-screen disconnect remained refused with the virtual online.
- Explicit start: independent CoreGraphics enumeration showed only the owned
  1920×1080 virtual screen, while the built-in was offline. Repeated start kept
  the same trial/session/deadline; stale tokens and a different target were refused.
- No confirmation: the physical screen returned automatically and state became
  `restored`. Manual restore and repeated restore also passed.
- Virtual-only UI: a disposable TextEdit RTF accepted a formatting-control click
  and text input. Screenshots/accessibility showed the result; saved plain text
  matched exactly. Confirmation succeeded after this read-back, and the desktop
  stayed virtual-only beyond the original trial deadline. Earlier trials whose
  confirmation arrived late were correctly rolled back and refused confirmation.
- Active session: disabling its virtual screen was refused. Normal App quit
  restored the physical screen before releasing the virtual display; relaunch
  did not resume the exception. Ordinary display connect also ended a trial.
- Test config removed; original topology/mode and unrelated held-disconnect
  records were preserved. The tested headless-session build remains installed and running.

The hardware checks exposed a missing-UUID restore failure, corrected by the
recorded-ID/descriptor fallback above and covered by a focused regression test.
Force-kill recovery, real WindowServer timeouts/late commits, forced virtual loss,
physical hotplug and a Mac mini external monitor were not exercised. These are
coverage limits for this draft, not claimed device results.

### Review follow-up

Code `6aa86db` passed `make check` (195 tests, 277 localization keys), was
installed with matching App/CLI hashes and strict signatures, and repeated the
native start/repeat, guarded writes, metadata edit, manual/automatic restore,
expired-confirmation refusal and normal quit/reopen checks. Cleanup preserved
the original physical topology/mode and held-disconnect records. The new
custom-panel GUI interactions and GUI rebuild/CLI overlap were reviewed and
compiled, but were not interactively exercised in this follow-up. The earlier
TextEdit screenshot/input proof above belongs to code `2e00752`.
