# Non-blocking External Brightness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make external brightness react immediately when one DDC/CI channel blocks, without letting that channel delay another display or mis-pairing identical monitors.

**Architecture:** Match Apple Silicon DDC channels by the existing CoreDisplay/IORegistry location before numeric identity, enumerate channels without a blocking liveness read, and route all DDC work through one serial queue per display. While DDC availability is unknown, use the existing gamma path as an immediate preview; the final retried DDC result either replaces that preview with the normal hardware/gamma blend or keeps software brightness for the session.

**Tech Stack:** Swift 5/6, CoreGraphics, IOKit/CoreDisplay runtime lookup, Grand Central Dispatch, XCTest, XcodeGen.

**Starting point:** Branch `fix/ddc-brightness-latency`, design commit `cc76c6d`, and approved specification `docs/superpowers/specs/2026-08-20-ddc-brightness-latency-design.md`. Run every command from the repository root.

---

## File map

- Modify `Crisp/Models/DDCServiceMatcher.swift`: add optional display location and make it the highest-priority match.
- Create `Crisp/Models/DDCOperationQueuePool.swift`: own the minimum locked map of per-display serial queues.
- Modify `Crisp/Services/DDCService.swift`: collect both sides' locations, remove the liveness read, use the queue pool, and lock read-quarantine state explicitly.
- Modify `Crisp/Services/BrightnessService.swift`: preview unknown DDC changes in gamma and make one final DDC failure authoritative.
- Modify `CrispTests/DDCServiceMatcherTests.swift`: pin location-first and location-missing behavior.
- Create `CrispTests/DDCOperationQueuePoolTests.swift`: pin cross-display isolation and same-display serialization.
- Modify `project.yml`: compile the queue pool into the headless test target.

### Task 1: Match identical displays by stable location

**Files:**
- Modify: `CrispTests/DDCServiceMatcherTests.swift`
- Modify: `Crisp/Models/DDCServiceMatcher.swift`

- [ ] **Step 1: Add failing location tests**

Insert these tests before `// MARK: - Strategy 2` in `CrispTests/DDCServiceMatcherTests.swift`:

```swift
    func testLocationWinsWhenIdenticalDisplayOrderIsReversed() {
        let serviceA = DDCServiceMatcher.Identity(
            vendor: 1507, product: 12816, serial: 0, location: "IOService:/dispext0@B0000000"
        )
        let serviceB = DDCServiceMatcher.Identity(
            vendor: 1507, product: 12816, serial: 0, location: "IOService:/dispext1@90000000"
        )
        let result = DDCServiceMatcher.match(
            services: [serviceA, serviceB],
            displays: [
                (id: 2, identity: serviceB),
                (id: 5, identity: serviceA)
            ]
        )

        XCTAssertEqual(result.byDisplayID, [2: 1, 5: 0])
        XCTAssertFalse(result.ambiguous)
    }

    func testMissingLocationsPreserveModelFallback() {
        let service = DDCServiceMatcher.Identity(vendor: 1507, product: 12816, serial: 0)
        let result = DDCServiceMatcher.match(
            services: [service],
            displays: [
                (id: 5, identity: .init(vendor: 1507, product: 12816, serial: 0)),
                (id: 2, identity: .init(vendor: 1, product: 2, serial: 0))
            ]
        )

        XCTAssertEqual(result.byDisplayID, [5: 0])
        XCTAssertFalse(result.ambiguous)
    }
```

- [ ] **Step 2: Run the matcher tests and verify the new initializer fails**

Run:

```bash
make test
```

Expected: FAIL compiling `DDCServiceMatcherTests` because `Identity` has no `location` parameter.

- [ ] **Step 3: Add location to `Identity` and prioritize it**

Replace `Identity` in `Crisp/Models/DDCServiceMatcher.swift` with:

```swift
    struct Identity: Equatable {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
        let location: String?

        init(vendor: UInt32, product: UInt32, serial: UInt32, location: String? = nil) {
            self.vendor = vendor
            self.product = product
            self.serial = serial
            self.location = location
        }
    }
```

Replace the three declarations starting at `let exact = displays.first` with:

```swift
            let byLocation = idty.location.flatMap { location in
                guard !location.isEmpty else { return nil }
                return displays.first {
                    !usedDisplays.contains($0.id) && $0.identity.location == location
                }
            }
            let exact = byLocation ?? displays.first {
                !usedDisplays.contains($0.id)
                    && idty.serial != 0
                    && $0.identity.serial != 0
                    && $0.identity.vendor == idty.vendor
                    && $0.identity.product == idty.product
                    && $0.identity.serial == idty.serial
            }
            let byModel = exact ?? displays.first {
                !usedDisplays.contains($0.id)
                    && $0.identity.vendor == idty.vendor
                    && $0.identity.product == idty.product
            }
```

Update the matcher comments to state the order: exact non-empty location, vendor/product/non-zero serial, vendor/product, traversal fallback.

- [ ] **Step 4: Run the tests**

Run: `make test`

Expected: PASS, including `testLocationWinsWhenIdenticalDisplayOrderIsReversed` and all existing matcher behavior.

- [ ] **Step 5: Commit the matcher change**

```bash
git add Crisp/Models/DDCServiceMatcher.swift CrispTests/DDCServiceMatcherTests.swift
git commit -m "fix: match DDC channels by display location"
```

---

### Task 2: Prove per-display queue isolation

**Files:**
- Create: `CrispTests/DDCOperationQueuePoolTests.swift`
- Create: `Crisp/Models/DDCOperationQueuePool.swift`
- Modify: `project.yml`

- [ ] **Step 1: Write the failing queue tests**

Create `CrispTests/DDCOperationQueuePoolTests.swift`:

```swift
import XCTest

final class DDCOperationQueuePoolTests: XCTestCase {
    func testBlockedDisplayDoesNotDelayAnotherDisplay() {
        let pool = DDCOperationQueuePool()
        let blockedStarted = DispatchSemaphore(value: 0)
        let releaseBlocked = DispatchSemaphore(value: 0)
        let otherFinished = DispatchSemaphore(value: 0)

        pool.queue(for: 2).async {
            blockedStarted.signal()
            releaseBlocked.wait()
        }
        XCTAssertEqual(blockedStarted.wait(timeout: .now() + 1), .success)

        pool.queue(for: 5).async { otherFinished.signal() }
        XCTAssertEqual(otherFinished.wait(timeout: .now() + 0.5), .success)
        releaseBlocked.signal()
    }

    func testOperationsForOneDisplayRemainSerial() {
        let pool = DDCOperationQueuePool()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)

        pool.queue(for: 2).async {
            firstStarted.signal()
            releaseFirst.wait()
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)

        pool.queue(for: 2).async { secondStarted.signal() }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
    }
}
```

- [ ] **Step 2: Run the tests and verify the missing type fails**

Run: `make test`

Expected: FAIL compiling `DDCOperationQueuePoolTests` with `cannot find 'DDCOperationQueuePool' in scope`.

- [ ] **Step 3: Add the minimum locked queue pool**

Create `Crisp/Models/DDCOperationQueuePool.swift`:

```swift
import Foundation
import CoreGraphics

/// Keeps DDC operations serial per physical display without coupling displays.
final class DDCOperationQueuePool: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [CGDirectDisplayID: DispatchQueue] = [:]

    func queue(for displayID: CGDirectDisplayID) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[displayID] { return queue }
            let queue = DispatchQueue(
                label: "com.crisp.ddc.\(displayID)",
                qos: .userInitiated
            )
            queues[displayID] = queue
            return queue
        }
    }

    func removeQueue(for displayID: CGDirectDisplayID) {
        lock.withLock { _ = queues.removeValue(forKey: displayID) }
    }
}
```

Add this source after `DDCServiceMatcher.swift` in the `CrispTests` source list in `project.yml`:

```yaml
      - path: Crisp/Models/DDCOperationQueuePool.swift
```

- [ ] **Step 4: Run the tests**

Run: `make test`

Expected: PASS; display 5 finishes while display 2 is blocked, and display 2's second operation waits for its first.

- [ ] **Step 5: Commit the queue primitive**

```bash
git add project.yml Crisp/Models/DDCOperationQueuePool.swift CrispTests/DDCOperationQueuePoolTests.swift
git commit -m "fix: isolate DDC work by display queue"
```

---

### Task 3: Remove blocking discovery and wire isolated queues

**Files:**
- Modify: `Crisp/Services/DDCService.swift`

- [ ] **Step 1: Load CoreDisplay's display dictionary through the existing runtime-lookup pattern**

Add this file-private symbol after `CGDisplayIOServicePort`:

```swift
private let _CoreDisplayCreateInfoDictionary:
    (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
            return nil
        }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self
        )
    }()
```

Add these helpers beside `displayIdentity(from:)`:

```swift
    private func coreDisplayLocation(for displayID: CGDirectDisplayID) -> String? {
        guard let dictionary = _CoreDisplayCreateInfoDictionary?(displayID)?.takeRetainedValue()
                as NSDictionary? else { return nil }
        return dictionary[kIODisplayLocationKey] as? String
    }

    private func ioRegistryPath(for entry: io_service_t) -> String? {
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { path.deallocate() }
        guard IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: path)
    }
```

Change `displayIdentity` to accept and store the optional location:

```swift
    private func displayIdentity(
        from productAttributes: [String: Any],
        location: String? = nil
    ) -> DDCServiceMatcher.Identity? {
        func u32(_ value: Any?) -> UInt32? {
            if let v = value as? UInt32 { return v }
            if let v = value as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
            if let v = value as? NSNumber { return v.uint32Value }
            return nil
        }
        guard let vendor = u32(productAttributes["LegacyManufacturerID"]),
              let product = u32(productAttributes["ProductID"]) else { return nil }
        return DDCServiceMatcher.Identity(
            vendor: vendor,
            product: product,
            serial: u32(productAttributes["SerialNumber"]) ?? 0,
            location: location
        )
    }
```

- [ ] **Step 2: Collect framebuffer paths and enumerate channels without I2C**

In the framebuffer branch of `buildAVServiceMapByProximity()`, pass the registry path:

```swift
               let pa = da["ProductAttributes"] as? [String: Any],
               let id = displayIdentity(from: pa, location: ioRegistryPath(for: entry)) {
                lastIdentity = id
            }
```

Replace the liveness-read block for `DCPAVServiceProxy` with:

```swift
                if location == nil || location == "External",
                   let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
                    ordered.append(avService)
                    identities.append(lastIdentity)
                }
```

When building `displays`, add the CoreDisplay location:

```swift
        let displays: [(id: CGDirectDisplayID, identity: DDCServiceMatcher.Identity)] = externalIDs.map {
            (id: $0, identity: DDCServiceMatcher.Identity(
                vendor: CGDisplayVendorNumber($0),
                product: CGDisplayModelNumber($0),
                serial: CGDisplaySerialNumber($0),
                location: coreDisplayLocation(for: $0)))
        }
```

Update comments that say “working AVServices” or “answers I2C” to “external AVServices”; real VCP operations now determine capability.

- [ ] **Step 3: Replace the global queue and protect quarantine dictionaries**

Replace `ddcQueue` with:

```swift
    private let operationQueues = DDCOperationQueuePool()
```

Add beside `readFailStreak`:

```swift
    private let readStateLock = NSLock()
```

Replace `readSynchronous` with:

```swift
    private func readSynchronous(
        displayID: CGDirectDisplayID,
        command: UInt8
    ) -> (current: UInt16, max: UInt16)? {
        let quarantined = readStateLock.withLock { () -> Bool in
            guard let until = readQuarantineUntil[displayID] else { return false }
            guard Date() >= until else { return true }
            readQuarantineUntil.removeValue(forKey: displayID)
            readFailStreak[displayID] = 0
            return false
        }
        guard !quarantined else { return nil }

#if arch(arm64)
        let result = arm64Read(displayID: displayID, command: command)
#else
        let result = intelReadSynchronous(displayID: displayID, command: command)
#endif

        readStateLock.withLock {
            if result == nil {
                let streak = readFailStreak[displayID, default: 0] + 1
                readFailStreak[displayID] = streak
                if streak >= readQuarantineThreshold {
                    readQuarantineUntil[displayID] = Date().addingTimeInterval(readQuarantineInterval)
                }
            } else {
                readFailStreak[displayID] = 0
            }
        }
        return result
    }
```

Replace every `ddcQueue.async` in `writeAsync`, `readAsync`, and `readBatchVCPCodes` with:

```swift
operationQueues.queue(for: displayID).async {
```

Keep each existing closure body and retry loop unchanged.

Replace the read-state cleanup in `clearCache(for:)` with:

```swift
        readStateLock.withLock {
            readFailStreak.removeValue(forKey: displayID)
            readQuarantineUntil.removeValue(forKey: displayID)
        }
        operationQueues.removeQueue(for: displayID)
```

Replace the asynchronous read-state cleanup in `invalidateAllChannelMappings()` with:

```swift
        readStateLock.withLock {
            readFailStreak.removeAll()
            readQuarantineUntil.removeAll()
        }
```

Do not remove all operation queues during a global channel-map invalidation: online display IDs keep the same queue, so an in-flight operation cannot overlap a newly-created queue. Removed displays still drop their queue through `clearCache(for:)`.

- [ ] **Step 4: Compile and run unit tests**

Run:

```bash
make compile
make test
```

Expected: `Crisp-bin` builds and all tests pass without the removed `ddcQueue` symbol.

- [ ] **Step 5: Commit DDC service wiring**

```bash
git add Crisp/Services/DDCService.swift
git commit -m "fix: prevent one DDC channel blocking other displays"
```

---

### Task 4: Make unknown and failed DDC writes visibly immediate

**Files:**
- Modify: `Crisp/Services/BrightnessService.swift`

- [ ] **Step 1: Remove the redundant outer failure counter**

Delete:

```swift
    private var ddcFailStreak: [CGDirectDisplayID: Int] = [:]
```

Also delete `ddcFailStreak.removeValue(forKey: displayID)` from `invalidateDDCState(for:)`. `DDCService.writeAsync` retains its existing three low-level attempts.

- [ ] **Step 2: Preview unknown DDC brightness and preserve the established low-end blend**

In `writeDDCBrightnessCoalesced`, replace the gamma-update block beginning with `queue.async` with:

```swift
        let ddcStatus = ddcAvailableLock.withLock { ddcAvailable[displayID] }
        queue.async { [weak self] in
            guard let self else { return }
            if ddcStatus == nil {
                self.setSoftwareBrightness(percent, for: displayID)
            } else if ddcStatus == true {
                if percent < self.gammaBlendThreshold {
                    self.setSoftwareBrightness(
                        percent / self.gammaBlendThreshold * 100.0,
                        for: displayID
                    )
                } else if let factor = self.currentSoftwareBrightness(for: displayID), factor < 1.0 {
                    self.setSoftwareBrightness(100.0, for: displayID)
                }
            }
        }
```

This keeps known-good behavior unchanged and gives the unknown path an immediate software result before any DDC read/write can finish.

- [ ] **Step 3: Make the final retried write result authoritative**

Replace the body of the `writeAsync` completion in `pumpDDCWrite(for:)` with:

```swift
            guard let self else { return }
            if success {
                self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = true }
                let hasNewerTarget = self.ddcPumpLock.withLock {
                    self.pendingDDCPercent[displayID] != nil
                }
                if !hasNewerTarget {
                    self.queue.async {
                        let stillCurrent = self.ddcPumpLock.withLock {
                            self.pendingDDCPercent[displayID] == nil
                        }
                        guard stillCurrent else { return }
                        let softwarePercent = percent < self.gammaBlendThreshold
                            ? percent / self.gammaBlendThreshold * 100.0
                            : 100.0
                        self.setSoftwareBrightness(softwarePercent, for: displayID)
                    }
                }
                self.pumpDDCWrite(for: displayID)
            } else {
                self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = false }
                let fallbackPercent = self.ddcPumpLock.withLock { () -> Double in
                    let latest = self.pendingDDCPercent.removeValue(forKey: displayID) ?? percent
                    self.ddcPumpActive.remove(displayID)
                    return latest
                }
                self.queue.async {
                    self.setSoftwareBrightness(fallbackPercent, for: displayID)
                }
            }
```

Success clears an unknown preview only if it is still the latest target. A final failure stops the pump, applies the newest pending value in software, and makes future calls use the existing `currentStatus == false` branch.

- [ ] **Step 4: Compile and run the full local checks**

Run:

```bash
make check
```

Expected: lint is silent, all tests pass, localization export passes, and the command ends with `check passed: lint clean, tests green, localization keys complete`.

- [ ] **Step 5: Commit responsive fallback behavior**

```bash
git add Crisp/Services/BrightnessService.swift
git commit -m "fix: preview slow DDC brightness changes in software"
```

---

### Task 5: Hardware verification and PR-ready diff

**Files:**
- No source edits expected.

- [ ] **Step 1: Create a disposable test app and launch the branch build**

Run:

```bash
ditto /Applications/Crisp.app /tmp/Crisp-DDC-Test.app
CRISP_APP=/tmp/Crisp-DDC-Test.app make dev
```

Expected: `Crisp 1.5.0 running` from `/tmp/Crisp-DDC-Test.app`; the signed release in `/Applications` remains unchanged.

- [ ] **Step 2: Verify the two U32N10 displays**

With both AOC U32N10 displays connected:

1. Open Crisp and immediately drag each external slider repeatedly.
2. Confirm the slow `dispext0` panel changes immediately through gamma instead of waiting roughly 12 seconds.
3. While `dispext0` is probing, drag `dispext1` and confirm it changes independently.
4. Confirm each slider controls its own physical panel.
5. Rapidly move one slider to several values and stop; confirm no late DDC completion restores an older level.
6. Disconnect and reconnect both displays, then repeat steps 1–5 to exercise state invalidation.

Expected: neither visible change waits for DDC, the healthy channel is not blocked, and no stale completion or swapped mapping is visible.

- [ ] **Step 3: Restore the release app after the hardware run**

Run:

```bash
pkill -x Crisp || true
open /Applications/Crisp.app
```

Expected: the installed notarized v1.5.0 app is running again.

- [ ] **Step 4: Verify the final branch**

Run:

```bash
git status --short --branch
git diff --check origin/main...HEAD
git log --oneline origin/main..HEAD
```

Expected: clean `fix/ddc-brightness-latency` branch, no whitespace errors, and only the design/plan plus the focused matcher, queue, DDC service, brightness service, test, and `project.yml` commits.
