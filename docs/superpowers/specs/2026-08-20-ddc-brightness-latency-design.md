# Non-blocking external brightness control

Status: approved design, pre-implementation.
Date: 2026-08-20

## Purpose

External brightness changes must react immediately even when another monitor's
DDC/CI channel is slow or unavailable. A failed monitor must not delay a healthy
monitor, and two identical monitors with no numeric serial must still map to the
correct hardware channels.

## Root cause and measured reproduction

The affected setup has two AOC U32N10 displays. Both report vendor 1507,
product 12816, and numeric serial 0. Their stable CoreDisplay locations are
different (`dispext0` and `dispext1`).

`DDCService.buildAVServiceMapByProximity()` performs a synchronous
`IOAVServiceReadI2C` before accepting each external channel. On this hardware:

- `dispext0`: the liveness read fails after 12.131 seconds.
- `dispext1`: the same read succeeds in 0.010 seconds.

All monitors currently share one `ddcQueue`, so the slow call stalls reads and
writes for both displays. The delay is intermittent because it appears only
when an adjustment lands behind a probe or retry. The slow channel also makes
actual DDC calls block, so deleting only the liveness read is insufficient.

## Design

### Stable channel matching

Extend `DDCServiceMatcher.Identity` with an optional IORegistry location.
CoreDisplay's `IODisplayLocation` is the target-side value; the path of the
framebuffer preceding each `DCPAVServiceProxy` is the service-side value.

Matching order becomes:

1. exact non-empty location;
2. vendor + product + non-zero serial;
3. vendor + product;
4. existing traversal-order fallback.

The location match distinguishes the two U32N10 panels even though their
vendor, product, numeric serial, EDID UUID, and product name are identical.
Systems where CoreDisplay does not expose a location retain today's behavior.

Enumerate every external `DCPAVServiceProxy` without issuing the synchronous
liveness read. Real VCP operations remain the authority on whether a channel
works; an unsolicited read is neither a reliable capability test nor safe for
latency.

### Per-display I/O isolation

Replace the single DDC operation queue with one serial queue per
`CGDirectDisplayID`. Operations for one display remain ordered, while a blocked
driver call cannot hold another display's writes. Cache and quarantine state
that was implicitly protected by the global queue receives explicit locking.
Display removal drops its queue and state through the existing cache cleanup.

### Responsive unknown-DDC path

Known-good DDC and known-software displays keep their current paths. When DDC
availability is still unknown:

1. apply the requested level immediately with the existing software gamma path;
2. enqueue the coalesced hardware DDC write on that display's queue;
3. on success, mark DDC available and remove the temporary gamma preview;
4. on final failure, mark DDC unavailable and retain software brightness.

`DDCService.writeAsync` already performs its bounded retries, so one final
failure is enough to choose software for the session; the outer three-failure
layer is removed. Reconnect invalidation permits a recovered or recabled monitor
to be probed again.

The DDC completion only removes the preview when no newer target is pending.
This prevents a late completion for an old slider value from overwriting the
newest preview. Below the existing 15% blend threshold, success restores the
normal DDC-plus-gamma blend rather than an identity gamma table.

## Scope

Expected production changes:

- `Crisp/Models/DDCServiceMatcher.swift`
- `Crisp/Services/DDCService.swift`
- `Crisp/Services/BrightnessService.swift`
- focused matcher and per-display queue isolation tests

No UI, localization, new dependency, or user preference is added. Built-in
brightness is unchanged; its measured `DisplayServicesSetBrightness` cost is
0.009 ms average (120 same-value calls), so it is not part of this defect.

## Error handling

- Missing CoreDisplay or location: use identity and traversal fallback.
- DDC read/write blocks: only that display's hardware queue waits; the visible
  adjustment has already occurred through software gamma.
- DDC write eventually succeeds: switch to hardware without applying a stale
  completion over a newer target.
- DDC write fails after its existing retries: stay in software mode until the
  display reconnects.

## Testing and verification

- Unit test: location wins for two otherwise-identical displays whose CoreGraphics
  and IORegistry orders differ.
- Unit test: missing locations preserve existing exact/model/fallback behavior.
- Unit test: a blocked operation for display A does not delay display B, while
  operations for one display remain serial.
- Run `make check`.
- Hardware verification on the dual-U32N10 setup:
  - repeatedly drag both sliders immediately after launch and panel open;
  - confirm the healthy display is never delayed by the slow channel;
  - confirm the slow display changes immediately through software fallback;
  - confirm each slider controls its own physical panel;
  - rapidly retarget a slider while its DDC write is pending and confirm a late
    completion never restores an older level;
  - reconnect both displays and repeat to exercise cache invalidation.

Success means no visible brightness change waits for the measured 12-second I/O
timeout, while known-good monitors continue using hardware DDC.

## Rejected alternatives

- Only split the queue: fixes the healthy display but leaves the slow display
  unresponsive.
- Only remove the liveness read: later reads or writes can still block.
- Add a manual "Force software" setting: exposes an implementation failure to
  users and does not fix cross-display blocking.
- Run concurrent reads and writes against one channel: risks corrupting fragile
  monitor DDC controllers; per-display serialization remains mandatory.
