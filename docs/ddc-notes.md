# DDC/CI field notes

Findings from a 2026-08 debugging session with two externals on an M4 Max
(each on its own passive DP 1.4 to USB-C cable), plus the defenses Crisp
ships as a result. Read this before touching DDCService or chasing a
"brightness slider does nothing" report.

## The stack

- `Crisp/Services/DDCService.swift`: raw DDC/CI. On Apple Silicon this is
  IOAVService I2C against DCPAVServiceProxy registry nodes, paired to
  displays by CoreDisplay/IORegistry location first, then
  vendor/product/serial identity, then traversal order. Every operation
  runs on that display's own serial queue: one channel that blocks for
  seconds (#72) can no longer hold up the other monitors. Validates every
  reply's header AND checksum. Quarantines a display's reads after 6
  consecutive raw failures (10 min expiry, fresh probe window after). The
  whole display-to-channel map is flushed on any display reconfiguration
  (IDs get reshuffled with no removal event).
- `Crisp/Services/BrightnessService.swift`: routing and pacing. DDC when
  it works, full-range software gamma when `ddcAvailable` latches false (3
  consecutive failed writes), and full-range software gamma while a
  display is in HDR mode (`hdrDimmedDisplays`, pushed by
  BrightnessBoostService): a DisplayHDR monitor owns its luminance and
  silently discards DDC brightness writes while still acking them. Writes
  coalesce per display (latest target wins, ~50 ms floor) and carry a
  topology/request token, so a reply that lands after a reconnect or after
  a newer drag value is discarded instead of applied. While a write is
  outstanding and DDC capability is still unknown, the gamma preview shows
  the target immediately and settles once the hardware acks.
- The unified log, subsystem `com.crisp.app`, categories `ddc`,
  `brightness`, `volume`, `keys`. Channel pairing per display and the
  strategy it took, every probe reply or its failure class (I2C error,
  bad header with the first six bytes, bad checksum, max 0), writes that
  failed all three attempts, the three-failure latch to gamma, HDR
  routing, read quarantine start and expiry, the map flush on
  reconfiguration, any single I2C op over 500 ms (issue #72 saw 12 s reads),
  and the key tap lifecycle. Per-write chatter sits at debug (memory only). The bug form
  asks reporters for `log show --last 30m --predicate 'subsystem ==
  "com.crisp.app"' --style compact`. Read that capture before asking
  questions; #14, #57 and #72 were each one capture's worth.
- `scripts/ddc-probe.swift`: read-only. Lists displays, channels, and
  raw VCP 0x10 replies with header/checksum verdicts. Run this FIRST when
  a slider goes dead; it names the failure in seconds.
- In-app tell for a user's Mac (no scripts): `defaults write com.crisp.app
  crisp.showBrightnessControlMode -bool true`, relaunch Crisp. A caption
  above each brightness slider then reads DDC (green, a write or read
  succeeded), Software (orange, the three-failure latch flipped to gamma),
  or System for the built-in; nothing until the first write settles it.
  `-bool false` or `defaults delete` puts it back. Not in 1.5.0.
- `scripts/ddc-write-probe.swift [aoc|dell] <value ... | burst>`: sends
  real brightness writes (visible on the monitor). `burst` simulates a
  slider drag (61 writes, 50ms pacing).
- `scripts/ddc-stress-probe.swift`: interleaves garbage-channel reads
  with healthy-channel writes/reads, for cross-contamination testing.

## Measured monitor behavior

**AOC Q27G3XMN** (DP, 165Hz): reads are unreliable by design defect.
Publicly documented (blog.szynalski.com/2024/06/aoc-q27g3xmn-review):
roughly half of all DDC commands are randomly ignored, across batches,
with no firmware update path. Observed reply garbage: DDC NULL frames
(`6E 80 ...`), echoes of our own request, repeated single-byte noise,
stale EDID bytes. Reads degrade further under read traffic (clean first
read after power-on, garbage within a few) and occasionally recover.
Writes are reliable except when the controller fully wedges. Treat this
monitor as write-only; that is what the quarantine effectively does.

**Dell U2412M** (DP, portrait): textbook-clean DDC in both directions,
absent from every quirk database. Two quirks anyway: (1) incoming DDC
writes auto-dismiss its OSD menu; (2) app brightness traffic while its
OSD menu is open can wedge its DDC controller completely deaf (no I2C
ack at all): this is what BetterDisplay's "does not support DDC" panel
was showing. Also: it applies each brightness write with an internal
fade, so rapid write streams (long slider drags) visibly flash as each
write restarts the fade. Seen on other Dells too; accepted as a quirk.

## AVService pairing (Apple Silicon)

The DDC channel (DCPAVServiceProxy) and a display's identity (DisplayAttributes ->
ProductAttributes) live in sibling subtrees under the same dispextN registry node;
identity is never an ancestor of the AVService, so an upward parent-chain walk can't
find it. `buildAVServiceMapByProximity` (DDCService.swift) does a single depth-first
walk of the whole IOService plane instead, associating each AVService with the most
recently seen identity (the same proximity strategy MonitorControl uses). Matching
order: (1) stable CoreDisplay/IORegistry location, (2) vendor+product+non-zero serial
then vendor+product, (3) traversal-order fallback for anything identity matching
missed (e.g. two identical monitors that share vendor/product/serial). An earlier,
ancestor-walk-based approach fell through to a sorted-CGDirectDisplayID index whenever
the walk failed, which mis-paired channels and drove the wrong monitor; the sorted
index doesn't track that the AVService order follows the framebuffer order within the
same subtree, which is what proximity matching relies on instead.

## Failure classes and defenses

| Failure | Symptom | Defense |
| --- | --- | --- |
| Garbage reply passes weak validation | Bogus max poisons the write scale; slider saturates partway (100/255 = top 61% dead) | Checksum validation on every reply |
| Read-hammering a fragile controller | Controller degrades into garbage/wedge | Read quarantine, 6 strikes, 10 min expiry |
| Deaf channel (no ack) answers each read attempt after about 6 s | The arrival probe's 3 attempts per VCP code held a disconnect's DDC hold for 33 s (U2412M, 2026-10-05) | One failed attempt over 3 s quarantines reads at once; the capabilities read stops when reads are quarantined |
| Display IDs reshuffled, no removal event | Channel map crossed: each slider drives the OTHER monitor; both look dead | Full map flush on every reconfiguration, identity re-match, per-display generation token discards in-flight work for the IDs whose channel actually changed |
| One display's I2C blocks for seconds | Every other display's slider stalls with it | Per-display serial queues; coalesced latest-wins writes; immediate software preview while the write is outstanding |
| Channel goes deaf (no ack) | Writes fail cleanly | 3-failure latch to full-range software gamma; recovery on reconnect |
| Monitor in HDR discards DDC writes (still acks) | 15-100% of slider dead, ack-based detection blind | HDR state routes the whole 0-100 range to software gamma |
| Firmware fills the high byte of the volume max (Dell S2725DSM replies 0xFF64 for 0 to 100, #162) | Volume keys and slider give only mute or full volume | Volume max taken from the low byte (`DDCVolumeMax`), the byte ddcutil reads 0x62 from |

## DDC volume value range

Audio Adjustment > DDC Value Range sets a maximum raw volume value, saved by
display UUID (`crisp.volumeMaxOverrides`). Keys and sliders map 0–100% onto
`0…min(hardwareMax, ceiling)`. The right end restores the full hardware range;
lowering the ceiling clips the current volume, while raising it preserves it.

## Recovery, in order of escalation

1. Open the monitor's OSD menu briefly (documented to wake a stale DDC
   handler; no power cycle needed).
2. Replug the video cable (forces re-enumeration; also clears every
   Crisp-side cache and latch via the reconfiguration path).
3. Pull the monitor's POWER cord ~10s (standby is not enough; the DDC
   controller stays powered). This is the only cure for a fully deaf
   controller, and per ddcutil's tracker even it is not guaranteed.

## The hold around enable and disable

WindowServer's display enable waits behind an in-flight I2C transaction on
the DCP, and the whole Mac freezes with it (2.8 to 3.0 s measured on a
wedged channel, #110). So every SkyLight enable and disable is wrapped in
`DDCService.hold()`: it drains the DDC queues, parks them until the
transaction has landed, and logs `waited N ms for DDC to go idle` past
500 ms. The 15 s safety timeout bounds only the parked phase. The drain
itself waits for whatever read or write is in flight with no Crisp-side
bound, on purpose: a read that takes 6 s to give up costs 6 s of waiting,
where issuing the transaction under it costs 6 s of a frozen Mac.

Probing a channel whose display is off or wedged holds the same DCP I2C engine for
about six seconds before it fails, so re-walking the registry for an unpaired display
on every DDC op kept that engine busy for most of a refresh, and WindowServer's enable
freezes behind it the same way (issue #33's shape; measured once as a 6 s freeze on a
reconnect that landed inside a 6 s volume read). `DDCService.noChannelSince` remembers
a miss for 20 s so a refresh does one walk instead of six, while still picking up a
monitor that answers late. A read attempt that fails after more than 3 s quarantines that display's reads at once for the same reason (`deafAttemptMs`): on 2026-10-05 a deaf U2412M's arrival probe queued 0x62 and 0x60 at 3 attempts each, every attempt took about 6 s, and the disconnect behind it waited 33 s. The reconfiguration flush still clears the quarantine, because a replug is recovery step 2 and IDs reshuffle, so a deaf channel costs one 6 s attempt per display change.

## Input switching (#196)

Measured on 2026-10-05 on the AOC Q27G3XMN, with the Mac on one input and a PC on another, through m1ddc (by display UUID, since its display numbers follow the main display) and crispctl.

An input write (VCP 0x60) from the Mac lands also when the Mac is not the active input: with the AOC showing the PC, a write from the Mac switched it back. Many monitors accept DDC only on the active input, so this is the AOC's behavior, not a rule; on such a monitor only the switch away works from Crisp.

While the monitor shows the other source, macOS keeps it online and active the whole time (30 samples over 15 s), so the pointer and new windows can go onto a screen nobody sees. That is the state that stopped `crispctl display poweroff`, which is why `InputSwitchService` disconnects the display after the write. The disconnect takes it out of the list within 0.6 s. A disconnected display has no DDC channel (the m1ddc write failed and its list dropped the AOC), so the way back is Reconnect first, then the write: the channel was back within 0.5 s of the Reconnect, and the AOC stayed on the PC until the write. That write makes the monitor re-link, and macOS loses the display for about 1.5 s before it comes back. So `InputSwitchService.reconnect` writes the Mac's input once, as soon as the Reconnect returns, with no retry and no read back: with the Mac on HDMI and the PC on the DP input (USB-C), the write went out 190 ms after the enable and the AOC re-linked to the Mac about 0.5 s later. One test had the write acked with no switch, but there the Mac was on both inputs at once, so the other input was a second Mac display and not a real source. The case of the Mac on DisplayPort with a second computer is not measured: the AOC has one DP input.

An input with no signal does not hold: the AOC switches to it and back at once, the same from its own OSD, so a test needs a live source on the target input.

Reads: over DisplayPort, 18 of 20 unvalidated 0x60 reads gave the right value, and Crisp's checksum check drops the other two; over HDMI none of the unvalidated reads were right. The AOC replies max 0x200E for 0x60, but other monitors report max 0 for a code with no scale, so reads of 0x60 accept max 0.

The capabilities string (365 bytes on the AOC, `60( 11 12 0F)` for HDMI 1, HDMI 2 and DisplayPort 1) read the same in two runs over DisplayPort, but about 9 of 10 chunk replies were bad: 93 and 192 requests for 13 good chunks. So `DDCService.readCapabilities` sends one chunk per queue turn (brightness keeps flowing between them) with a budget of 400 bad replies, and `InputSwitchService` reads it once per monitor, when its input list is first opened, and keeps the result.

## Rules of engagement

- Never trust an acked write as proof DDC works; only a checksum-valid
  read proves anything, and some monitors (AOC above) never give one.
- Never let a read result touch the write scale unless it validated.
- Avoid sending brightness from an app while a monitor's OSD menu is
  open when reproducing bugs; on some firmware that collision wedges the
  controller (undocumented anywhere else as of 2026-08).
- ddcutil (Linux) is the richest source of per-monitor DDC quirk
  knowledge: www.ddcutil.com/faq and its GitHub issues.
