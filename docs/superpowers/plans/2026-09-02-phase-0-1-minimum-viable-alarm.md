# Minimum Viable Alarm (Phase 0 + Phase 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu-bar macOS app that, while armed, sounds an unmissable siren at forced maximum volume when the charger is unplugged, and stops only when the correct passcode is entered.

**Architecture:** A pure-logic `AlarmCore` library (state machine, trigger/response protocols, capability gating) with thin, protocol-backed wrappers over IOKit, CoreAudio and Keychain, plus a SwiftUI `MenuBarExtra` executable. Every system dependency sits behind a protocol so the engine is unit-testable without unplugging anything. Triggers and responses declare `isAvailable`, which is the same seam the sandboxed App Store build will later use to drop unavailable features.

**Tech Stack:** Swift 6.3, Swift Package Manager, Swift Testing (`import Testing`), SwiftUI `MenuBarExtra`, IOKit (`IOPS*`, `IOPM*`), CoreAudio HAL, AVFoundation (`AVAudioEngine`), CommonCrypto (PBKDF2), Keychain Services.

**Spec:** `docs/superpowers/specs/2026-09-02-laptop-alarm-design.md`

**Verification status:** Every Swift block in Tasks 2-12 was extracted into a real package and compiled on 2026-09-02 against Swift 6.3 / macOS 26.5 SDK: the build is clean with no warnings, all **64 tests pass**, and `make-bundle.sh` produces a signed, launchable `LaptopAlarm.app`. Deviations from what is written here should be treated as suspect.

## Global Constraints

- **Platform floor:** macOS 14. Declare `platforms: [.macOS(.v14)]` in `Package.swift`.
- **Swift tools version:** `6.2` or later — required for `defaultIsolation`.
- **The whole package is main-actor isolated by default** via `.defaultIsolation(MainActor.self)` on every target. This app is entirely main-thread: IOKit run-loop callbacks, CoreAudio changes and SwiftUI state all belong there. Declaring it once removes every `@Sendable` closure and `@unchecked Sendable` conformance from the codebase. **Do not add them back** — if something appears to need one, the design is wrong, not the annotation.
- **Zero third-party dependencies.** System frameworks only. This ships commercially; every dependency is a licensing and review liability.
- **No bundled audio assets.** The siren is synthesised at runtime with `AVAudioEngine`. Bundling a sound file would create an asset-licensing problem for a paid product.
- **Every `Trigger` and `Response` must implement `isAvailable`.** Capability gating is the mechanism by which the Phase 5 App Store build drops screen-lock and lid-angle. No feature may be referenced unconditionally by the engine.
- **Test naming:** Swift Testing `@Test` functions, descriptive names, `#expect` for assertions.
- **The main executable file must not be named `main.swift`** — it conflicts with SwiftUI's `@main` attribute.
- **Bundle identifier:** `com.jernejkocica.laptopalarm`.
- **Verified API facts** (probed 2026-09-02, do not re-derive): built-in speakers have transport type `bltn` (`kAudioDeviceTransportTypeBuiltIn`); lid angle is HID element usage `0x47F` on device `0x05AC:0x8104`; `SACLockScreenImmediate` exists in `/System/Library/PrivateFrameworks/login.framework/Versions/A/login`.

---

### Task 1: Phase 0 spike — does the alarm survive a lid close?

**Throwaway probe. The code is deleted at the end of this task.** This is a decision gate: a negative result changes what the product can claim, so it runs before anything is built.

**Files:**
- Create: `spike/clamshell/main.swift` (deleted in Step 5)
- Create: `docs/superpowers/specs/2026-09-02-phase0-clamshell-result.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a written finding that Task 10 (`SleepAssertion`) and all marketing copy depend on. No code.

- [ ] **Step 1: Write the probe**

```swift
// spike/clamshell/main.swift
import Foundation
import IOKit.pwr_mgt

var ids: [IOPMAssertionID] = []
for type in [kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep] {
    var id: IOPMAssertionID = 0
    let r = IOPMAssertionCreateWithName(type as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "clamshell spike" as CFString, &id)
    print("\(type): \(r == kIOReturnSuccess ? "granted" : "FAILED \(r)")")
    if r == kIOReturnSuccess { ids.append(id) }
}

let log = URL(fileURLWithPath: NSHomeDirectory() + "/clamshell-spike.log")
try? "start \(Date())\n".write(to: log, atomically: true, encoding: .utf8)
let handle = try! FileHandle(forWritingTo: log)
handle.seekToEndOfFile()

// Heartbeat once a second. Gaps in the timestamps prove the machine slept.
for i in 1...120 {
    handle.write("tick \(i) \(Date())\n".data(using: .utf8)!)
    try? handle.synchronize()
    Thread.sleep(forTimeInterval: 1)
}
ids.forEach { IOPMAssertionRelease($0) }
```

- [ ] **Step 2: Build and start it**

```bash
mkdir -p spike/clamshell
swiftc -O spike/clamshell/main.swift -o /tmp/clamshell-spike
/tmp/clamshell-spike &
```
Expected: both assertion types print `granted`.

- [ ] **Step 3: Run the physical test**

This step is manual and cannot be automated. **Unplug the charger first** (clamshell behaviour differs on AC vs battery — on battery is the theft scenario that matters).

1. Close the lid for ~30 seconds.
2. Open it.
3. Inspect the heartbeat log:

```bash
awk '{print $3}' ~/clamshell-spike.log | head -120
```

Expected on success: unbroken one-second ticks across the closed period.
Expected on failure: a gap spanning the closed period.

Repeat **on AC power** and record both results — they may differ.

- [ ] **Step 4: Record the finding**

Write `docs/superpowers/specs/2026-09-02-phase0-clamshell-result.md` containing: the two results (battery, AC), the observed gap length if any, and one of these verdicts stated explicitly:

- **SURVIVES** — the siren keeps sounding lid-closed. `SleepAssertion` (Task 10) is sufficient on its own.
- **SLEEPS** — the siren is cut off. Then: the lid-angle trigger (Phase 3) becomes the primary lid defence because it fires *before* the lid shuts, the product must not claim protection while closed, and a follow-up spike into `kIOPMAssertionTypePreventSystemSleep` with an external-display or `caffeinate -s` comparison goes on the Phase 3 backlog.

- [ ] **Step 5: Delete the probe and commit the finding**

```bash
rm -rf spike /tmp/clamshell-spike ~/clamshell-spike.log
git add docs/superpowers/specs/2026-09-02-phase0-clamshell-result.md
git commit -m "docs: record Phase 0 clamshell sleep finding"
```

---

### Task 2: Package skeleton and injectable clock

**Files:**
- Create: `Package.swift`
- Create: `Sources/AlarmCore/Engine/AlarmClock.swift`
- Create: `Sources/AlarmCore/Support/TestClock.swift`
- Test: `Tests/AlarmCoreTests/TestClockTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AlarmClock` protocol (`now: Date`, `schedule(after:_:) -> ScheduledWork`), `ScheduledWork` protocol (`cancel()`), `SystemClock`, `TestClock` (`advance(by:)`). The grace-period countdown in Tasks 3 and 11 is tested through `TestClock`; no test may use real time.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let mainActor: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "LaptopAlarm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlarmCore", targets: ["AlarmCore"]),
        .executable(name: "LaptopAlarm", targets: ["LaptopAlarm"]),
    ],
    targets: [
        .target(name: "AlarmCore", swiftSettings: mainActor),
        .executableTarget(name: "LaptopAlarm", dependencies: ["AlarmCore"],
                          swiftSettings: mainActor),
        .testTarget(name: "AlarmCoreTests", dependencies: ["AlarmCore"],
                    swiftSettings: mainActor),
    ]
)
```

Create a placeholder so the executable target compiles:

```swift
// Sources/LaptopAlarm/Placeholder.swift
// Replaced entirely in Task 12.
enum Placeholder {}
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/AlarmCoreTests/TestClockTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func testClockDoesNotFireBeforeDeadline() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 0))
    var fired = false
    clock.schedule(after: 10) { fired = true }
    clock.advance(by: 9)
    #expect(fired == false)
}

@Test func testClockFiresAtDeadline() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 0))
    var fired = false
    clock.schedule(after: 10) { fired = true }
    clock.advance(by: 10)
    #expect(fired == true)
}

@Test func testClockDoesNotFireAfterCancel() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 0))
    var fired = false
    let work = clock.schedule(after: 10) { fired = true }
    work.cancel()
    clock.advance(by: 20)
    #expect(fired == false)
}

@Test func testClockAdvancesNow() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 100))
    clock.advance(by: 5)
    #expect(clock.now == Date(timeIntervalSince1970: 105))
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter TestClockTests`
Expected: FAIL — `cannot find 'TestClock' in scope`.

- [ ] **Step 4: Write the implementation**

```swift
// Sources/AlarmCore/Engine/AlarmClock.swift
import Foundation

/// A unit of scheduled work that can be cancelled before it runs.
public protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Time and scheduling, injectable so grace periods are testable without waiting.
/// Named `AlarmClock` to avoid colliding with the standard library's `Clock`.
public protocol AlarmClock: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) -> ScheduledWork
}

/// Production clock backed by `DispatchQueue.main`.
public final class SystemClock: AlarmClock {
    public init() {}
    public var now: Date { Date() }

    private final class Work: ScheduledWork {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    @discardableResult
    public func schedule(after seconds: TimeInterval,
                         _ body: @escaping () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Work(item)
    }
}
```

```swift
// Sources/AlarmCore/Support/TestClock.swift
import Foundation

/// Manually advanced clock for tests. Not used in production code.
public final class TestClock: AlarmClock {
    private final class Work: ScheduledWork {
        let deadline: Date
        let body: () -> Void
        var cancelled = false
        init(deadline: Date, body: @escaping () -> Void) {
            self.deadline = deadline
            self.body = body
        }
        func cancel() { cancelled = true }
    }

    private var pending: [Work] = []
    public private(set) var now: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) { self.now = now }

    @discardableResult
    public func schedule(after seconds: TimeInterval,
                         _ body: @escaping () -> Void) -> ScheduledWork {
        let work = Work(deadline: now.addingTimeInterval(seconds), body: body)
        pending.append(work)
        return work
    }

    /// Moves time forward, running anything whose deadline has passed.
    public func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = pending.filter { !$0.cancelled && $0.deadline <= now }
        pending.removeAll { $0.cancelled || $0.deadline <= now }
        due.forEach { $0.body() }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TestClockTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Add .gitignore before the first commit**

`.build/` appears as soon as anything is built, so this must exist now rather than later.

```bash
printf '.build/\nbuild/\n.DS_Store\n' > .gitignore
```

- [ ] **Step 7: Commit**

```bash
git add .gitignore Package.swift Sources Tests
git commit -m "feat: package skeleton with injectable clock"
```

---

### Task 3: Alarm state machine

The heart of the app, and pure — no I/O, no time, no system calls. Every transition is covered by a test.

**Files:**
- Create: `Sources/AlarmCore/Engine/AlarmState.swift`
- Test: `Tests/AlarmCoreTests/AlarmStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TriggerID` (`init(_ rawValue: String)`, `.rawValue`), `AlarmState` (`.disarmed`, `.armed`, `.grace(until:trigger:)`, `.firing(trigger:)`), `AlarmEvent` (`.arm`, `.disarm`, `.triggered(TriggerID, graceSeconds:)`, `.graceExpired`), and the free function `reduce(_:_:now:) -> AlarmState`. Task 11 drives this reducer.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/AlarmStateTests.swift
import Testing
import Foundation
@testable import AlarmCore

private let t0 = Date(timeIntervalSince1970: 1000)
private let power = TriggerID("power")

@Test func armingFromDisarmedGoesToArmed() {
    #expect(reduce(.disarmed, .arm, now: t0) == .armed)
}

@Test func triggerWithGracePeriodEntersGrace() {
    let s = reduce(.armed, .triggered(power, graceSeconds: 10), now: t0)
    #expect(s == .grace(until: t0.addingTimeInterval(10), trigger: power))
}

@Test func triggerWithoutGracePeriodFiresImmediately() {
    let s = reduce(.armed, .triggered(power, graceSeconds: 0), now: t0)
    #expect(s == .firing(trigger: power))
}

@Test func graceExpiringFires() {
    let grace = AlarmState.grace(until: t0, trigger: power)
    #expect(reduce(grace, .graceExpired, now: t0) == .firing(trigger: power))
}

@Test func disarmingDuringGraceReturnsToDisarmed() {
    let grace = AlarmState.grace(until: t0, trigger: power)
    #expect(reduce(grace, .disarm, now: t0) == .disarmed)
}

@Test func disarmingWhileFiringReturnsToDisarmed() {
    #expect(reduce(.firing(trigger: power), .disarm, now: t0) == .disarmed)
}

// Triggers must be ignored when not armed, or unplugging while disarmed
// would start screaming.
@Test func triggerWhileDisarmedIsIgnored() {
    #expect(reduce(.disarmed, .triggered(power, graceSeconds: 0), now: t0) == .disarmed)
}

// A second trigger must not restart or extend an alarm already sounding.
@Test func triggerWhileFiringIsIgnored() {
    let firing = AlarmState.firing(trigger: power)
    let other = TriggerID("lid")
    #expect(reduce(firing, .triggered(other, graceSeconds: 0), now: t0) == firing)
}

@Test func armingWhileArmedIsIdempotent() {
    #expect(reduce(.armed, .arm, now: t0) == .armed)
}

// A stale timer from a cancelled grace period must not resurrect the alarm.
@Test func graceExpiredWhileArmedIsIgnored() {
    #expect(reduce(.armed, .graceExpired, now: t0) == .armed)
}

@Test func graceExpiredWhileDisarmedIsIgnored() {
    #expect(reduce(.disarmed, .graceExpired, now: t0) == .disarmed)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AlarmStateTests`
Expected: FAIL — `cannot find 'reduce' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Engine/AlarmState.swift
import Foundation

/// Stable identifier for a trigger, used in logs, alerts and UI.
public struct TriggerID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum AlarmState: Equatable, Sendable {
    case disarmed
    case armed
    /// A trigger fired but the user still has until `until` to disarm.
    case grace(until: Date, trigger: TriggerID)
    case firing(trigger: TriggerID)
}

public enum AlarmEvent: Equatable, Sendable {
    case arm
    case disarm
    case triggered(TriggerID, graceSeconds: TimeInterval)
    case graceExpired
}

/// Pure transition function. No I/O, no ambient time — `now` is passed in so
/// grace deadlines are deterministic in tests.
public func reduce(_ state: AlarmState, _ event: AlarmEvent, now: Date) -> AlarmState {
    switch (state, event) {
    case (_, .disarm):
        return .disarmed

    case (.disarmed, .arm), (.armed, .arm):
        return .armed

    case let (.armed, .triggered(id, grace)):
        return grace > 0
            ? .grace(until: now.addingTimeInterval(grace), trigger: id)
            : .firing(trigger: id)

    case let (.grace(_, id), .graceExpired):
        return .firing(trigger: id)

    // Everything else is a no-op: triggers while disarmed or already firing,
    // stale grace timers, re-arming mid-alarm.
    default:
        return state
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AlarmStateTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Engine/AlarmState.swift Tests/AlarmCoreTests/AlarmStateTests.swift
git commit -m "feat: alarm state machine with exhaustive transition tests"
```

---

### Task 4: Capability, Trigger and Response protocols

**Files:**
- Create: `Sources/AlarmCore/Engine/Capability.swift`
- Create: `Sources/AlarmCore/Support/Fakes.swift`
- Test: `Tests/AlarmCoreTests/CapabilityTests.swift`

**Interfaces:**
- Consumes: `TriggerID` (Task 3).
- Produces: `Capability` (`identifier: String`, `isAvailable: Bool`), `Trigger` (`id: TriggerID`, `graceSeconds`, `start(onFire:)`, `stop()`), `Response` (`fire(context:)`, `reset()`), `AlarmContext` (`trigger`, `firedAt`), and the test doubles `FakeTrigger` / `FakeResponse` used by Task 11.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/CapabilityTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func unavailableTriggersAreFilteredOut() {
    let available = FakeTrigger(id: TriggerID("a"), isAvailable: true)
    let missing = FakeTrigger(id: TriggerID("b"), isAvailable: false)
    let usable: [any Trigger] = [available, missing].filter(\.isAvailable)
    #expect(usable.count == 1)
    #expect(usable.first?.id == TriggerID("a"))
}

@Test func fakeTriggerReportsFiring() {
    let trigger = FakeTrigger(id: TriggerID("a"), isAvailable: true)
    var fired: TriggerID?
    try? trigger.start { fired = $0 }
    trigger.simulateFire()
    #expect(fired == TriggerID("a"))
}

@Test func fakeResponseRecordsFireAndReset() async {
    let response = FakeResponse(identifier: "siren", isAvailable: true)
    await response.fire(context: AlarmContext(trigger: TriggerID("a"),
                                              firedAt: Date(timeIntervalSince1970: 0)))
    #expect(response.fireCount == 1)
    await response.reset()
    #expect(response.resetCount == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CapabilityTests`
Expected: FAIL — `cannot find 'FakeTrigger' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Engine/Capability.swift
import Foundation

/// Anything that may be absent on a given build or machine. The sandboxed App
/// Store build drops features by reporting `isAvailable == false` rather than
/// by conditional compilation at the call site.
public protocol Capability: AnyObject {
    var identifier: String { get }
    var isAvailable: Bool { get }
}

/// Context handed to every response when the alarm fires.
public struct AlarmContext: Sendable, Equatable {
    public let trigger: TriggerID
    public let firedAt: Date
    public init(trigger: TriggerID, firedAt: Date) {
        self.trigger = trigger
        self.firedAt = firedAt
    }
}

/// A condition that can start the alarm.
public protocol Trigger: Capability {
    var id: TriggerID { get }
    /// Seconds the user gets to disarm before the siren starts. 0 = immediate.
    var graceSeconds: TimeInterval { get }
    func start(onFire: @escaping (TriggerID) -> Void) throws
    func stop()
}

/// An action taken when the alarm fires. Must be idempotent: `fire` may be
/// called when already firing, and `reset` when never fired.
public protocol Response: Capability {
    func fire(context: AlarmContext) async
    func reset() async
}
```

```swift
// Sources/AlarmCore/Support/Fakes.swift
import Foundation

/// Test doubles. Kept in the library (not the test target) so future test
/// targets and SwiftUI previews can share them.
public final class FakeTrigger: Trigger {
    public let id: TriggerID
    public let isAvailable: Bool
    public let graceSeconds: TimeInterval
    public var identifier: String { id.rawValue }
    public private(set) var isStarted = false
    private var onFire: ((TriggerID) -> Void)?

    public init(id: TriggerID, isAvailable: Bool = true, graceSeconds: TimeInterval = 0) {
        self.id = id
        self.isAvailable = isAvailable
        self.graceSeconds = graceSeconds
    }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        isStarted = true
    }

    public func stop() {
        isStarted = false
        onFire = nil
    }

    /// Drives the trigger from a test.
    public func simulateFire() { onFire?(id) }
}

public final class FakeResponse: Response {
    public let identifier: String
    public let isAvailable: Bool
    public private(set) var fireCount = 0
    public private(set) var resetCount = 0
    public private(set) var lastContext: AlarmContext?

    public init(identifier: String, isAvailable: Bool = true) {
        self.identifier = identifier
        self.isAvailable = isAvailable
    }

    public func fire(context: AlarmContext) async {
        fireCount += 1
        lastContext = context
    }

    public func reset() async { resetCount += 1 }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CapabilityTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Engine/Capability.swift Sources/AlarmCore/Support/Fakes.swift Tests/AlarmCoreTests/CapabilityTests.swift
git commit -m "feat: capability-gated trigger and response protocols"
```

---

### Task 5: Power source monitoring and the charger-unplug trigger

**Files:**
- Create: `Sources/AlarmCore/Triggers/PowerSourceMonitor.swift`
- Create: `Sources/AlarmCore/Triggers/PowerTrigger.swift`
- Test: `Tests/AlarmCoreTests/PowerTriggerTests.swift`

**Interfaces:**
- Consumes: `Trigger`, `TriggerID` (Tasks 3-4).
- Produces: `PowerSourceMonitoring` protocol (`isOnACPower`, `startMonitoring(_:)`, `stopMonitoring()`), `IOKitPowerSourceMonitor`, `FakePowerSourceMonitor` (`simulateChange(isOnAC:)`), `PowerTrigger(monitor:graceSeconds:)` with `id == TriggerID("power")`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/PowerTriggerTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func firesWhenACIsDisconnected() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 10)
    var fired: TriggerID?
    try? trigger.start { fired = $0 }
    monitor.simulateChange(isOnAC: false)
    #expect(fired == TriggerID("power"))
}

@Test func doesNotFireWhenACIsConnected() {
    let monitor = FakePowerSourceMonitor(isOnACPower: false)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 10)
    var fired: TriggerID?
    try? trigger.start { fired = $0 }
    monitor.simulateChange(isOnAC: true)
    #expect(fired == nil)
}

// Battery-level notifications repeat constantly; only an actual AC->battery
// edge may fire, or the alarm would retrigger every few seconds.
@Test func doesNotFireOnRepeatedBatteryNotifications() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    monitor.simulateChange(isOnAC: false)
    monitor.simulateChange(isOnAC: false)
    monitor.simulateChange(isOnAC: false)
    #expect(fireCount == 1)
}

@Test func firesAgainAfterReconnectAndDisconnect() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    monitor.simulateChange(isOnAC: false)
    monitor.simulateChange(isOnAC: true)
    monitor.simulateChange(isOnAC: false)
    #expect(fireCount == 2)
}

// Arming on battery must not instantly fire.
@Test func armingWhileAlreadyOnBatteryDoesNotFire() {
    let monitor = FakePowerSourceMonitor(isOnACPower: false)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    #expect(fireCount == 0)
}

@Test func stoppingPreventsFurtherFiring() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    trigger.stop()
    monitor.simulateChange(isOnAC: false)
    #expect(fireCount == 0)
}

@Test func powerTriggerIsAlwaysAvailable() {
    let trigger = PowerTrigger(monitor: FakePowerSourceMonitor(isOnACPower: true),
                               graceSeconds: 0)
    #expect(trigger.isAvailable == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PowerTriggerTests`
Expected: FAIL — `cannot find 'PowerTrigger' in scope`.

- [ ] **Step 3: Write the monitor**

```swift
// Sources/AlarmCore/Triggers/PowerSourceMonitor.swift
import Foundation
import IOKit.ps

public protocol PowerSourceMonitoring: AnyObject {
    var isOnACPower: Bool { get }
    func startMonitoring(_ onChange: @escaping (Bool) -> Void)
    func stopMonitoring()
}

/// Real implementation. Verified working 2026-09-02.
public final class IOKitPowerSourceMonitor: PowerSourceMonitoring {
    private var source: CFRunLoopSource?
    private var onChange: ((Bool) -> Void)?

    public init() {}

    public var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
                  as String?
        else { return false }
        return type == kIOPMACPowerKey
    }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<IOKitPowerSourceMonitor>
                .fromOpaque(ctx).takeUnretainedValue()
            monitor.onChange?(monitor.isOnACPower)
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    public func stopMonitoring() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        onChange = nil
    }
}

public final class FakePowerSourceMonitor: PowerSourceMonitoring {
    public private(set) var isOnACPower: Bool
    private var onChange: ((Bool) -> Void)?

    public init(isOnACPower: Bool) { self.isOnACPower = isOnACPower }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func stopMonitoring() { onChange = nil }

    public func simulateChange(isOnAC: Bool) {
        isOnACPower = isOnAC
        onChange?(isOnAC)
    }
}
```

- [ ] **Step 4: Write the trigger**

```swift
// Sources/AlarmCore/Triggers/PowerTrigger.swift
import Foundation

/// Fires on the AC -> battery edge. Edge-detected because IOKit emits power
/// notifications continuously as the battery level changes.
public final class PowerTrigger: Trigger {
    public let id = TriggerID("power")
    public var identifier: String { id.rawValue }
    public let isAvailable = true
    public let graceSeconds: TimeInterval

    private let monitor: PowerSourceMonitoring
    private var wasOnAC: Bool
    private var onFire: ((TriggerID) -> Void)?

    public init(monitor: PowerSourceMonitoring, graceSeconds: TimeInterval) {
        self.monitor = monitor
        self.graceSeconds = graceSeconds
        self.wasOnAC = monitor.isOnACPower
    }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        wasOnAC = monitor.isOnACPower
        monitor.startMonitoring { [weak self] isOnAC in
            guard let self else { return }
            defer { self.wasOnAC = isOnAC }
            guard self.wasOnAC, !isOnAC else { return }
            self.onFire?(self.id)
        }
    }

    public func stop() {
        monitor.stopMonitoring()
        onFire = nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PowerTriggerTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AlarmCore/Triggers Tests/AlarmCoreTests/PowerTriggerTests.swift
git commit -m "feat: edge-detected charger unplug trigger"
```

---

### Task 6: Passcode storage in the Keychain

**Files:**
- Create: `Sources/AlarmCore/Security/PasscodeStore.swift`
- Test: `Tests/AlarmCoreTests/PasscodeStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PasscodeStoring` (`hasPasscode`, `setPasscode(_:) throws`, `verify(_:) -> Bool`, `clear() throws`), `InMemoryPasscodeStore` (tests), `KeychainPasscodeStore(service:account:)`, `PasscodeError`. Task 11 verifies disarm through `PasscodeStoring`.

The passcode is stored as a PBKDF2-SHA256 hash with a random salt, never in plaintext. Tests run against `InMemoryPasscodeStore` so CI never touches the real Keychain; the Keychain implementation is covered by the manual checks in Task 13.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/PasscodeStoreTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func newStoreHasNoPasscode() {
    #expect(InMemoryPasscodeStore().hasPasscode == false)
}

@Test func correctPasscodeVerifies() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    #expect(store.hasPasscode == true)
    #expect(store.verify("hunter2") == true)
}

@Test func wrongPasscodeFails() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    #expect(store.verify("hunter3") == false)
}

@Test func verifyFailsWhenNoPasscodeSet() {
    #expect(InMemoryPasscodeStore().verify("anything") == false)
}

@Test func emptyPasscodeIsRejected() {
    let store = InMemoryPasscodeStore()
    #expect(throws: PasscodeError.self) { try store.setPasscode("") }
}

@Test func passcodeIsNotStoredInPlaintext() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    let blob = try #require(store.rawRecord)
    #expect(String(data: blob, encoding: .utf8)?.contains("hunter2") != true)
    #expect(blob.range(of: Data("hunter2".utf8)) == nil)
}

// Two stores with the same passcode must produce different hashes, or a
// stolen record would reveal that two users share a passcode.
@Test func saltsDifferBetweenStores() throws {
    let a = InMemoryPasscodeStore(); try a.setPasscode("same")
    let b = InMemoryPasscodeStore(); try b.setPasscode("same")
    #expect(a.rawRecord != b.rawRecord)
}

@Test func clearingRemovesPasscode() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    try store.clear()
    #expect(store.hasPasscode == false)
    #expect(store.verify("hunter2") == false)
}

@Test func changingPasscodeInvalidatesTheOldOne() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("old")
    try store.setPasscode("new")
    #expect(store.verify("old") == false)
    #expect(store.verify("new") == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PasscodeStoreTests`
Expected: FAIL — `cannot find 'InMemoryPasscodeStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Security/PasscodeStore.swift
import Foundation
import Security
import CommonCrypto

public enum PasscodeError: Error, Equatable {
    case empty
    case keychain(OSStatus)
}

public protocol PasscodeStoring: AnyObject {
    var hasPasscode: Bool { get }
    func setPasscode(_ passcode: String) throws
    func verify(_ passcode: String) -> Bool
    func clear() throws
}

/// Salt + PBKDF2-SHA256 hash, serialised as `salt || hash`.
enum PasscodeHasher {
    static let saltBytes = 16
    static let hashBytes = 32
    static let rounds: UInt32 = 210_000   // OWASP 2023 guidance for PBKDF2-SHA256

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes, &bytes)
        return Data(bytes)
    }

    static func hash(_ passcode: String, salt: Data) -> Data {
        var out = [UInt8](repeating: 0, count: hashBytes)
        let pw = Array(passcode.utf8)
        salt.withUnsafeBytes { saltBuf in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.map { Int8(bitPattern: $0) }, pw.count,
                saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &out, hashBytes)
        }
        return Data(out)
    }

    static func makeRecord(_ passcode: String) -> Data {
        let salt = randomSalt()
        return salt + hash(passcode, salt: salt)
    }

    static func matches(_ passcode: String, record: Data) -> Bool {
        guard record.count == saltBytes + hashBytes else { return false }
        let salt = record.prefix(saltBytes)
        let expected = record.suffix(hashBytes)
        let actual = hash(passcode, salt: Data(salt))
        // Constant-time comparison.
        guard actual.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(actual, expected) { diff |= a ^ b }
        return diff == 0
    }
}

/// Used by tests so CI never touches the real Keychain.
public final class InMemoryPasscodeStore: PasscodeStoring {
    public private(set) var rawRecord: Data?
    public init() {}
    public var hasPasscode: Bool { rawRecord != nil }

    public func setPasscode(_ passcode: String) throws {
        guard !passcode.isEmpty else { throw PasscodeError.empty }
        rawRecord = PasscodeHasher.makeRecord(passcode)
    }

    public func verify(_ passcode: String) -> Bool {
        guard let rawRecord else { return false }
        return PasscodeHasher.matches(passcode, record: rawRecord)
    }

    public func clear() throws { rawRecord = nil }
}

public final class KeychainPasscodeStore: PasscodeStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.jernejkocica.laptopalarm",
                account: String = "disarm-passcode") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        else { return nil }
        return item as? Data
    }

    public var hasPasscode: Bool { load() != nil }

    public func setPasscode(_ passcode: String) throws {
        guard !passcode.isEmpty else { throw PasscodeError.empty }
        let record = PasscodeHasher.makeRecord(passcode)
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = record
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasscodeError.keychain(status) }
    }

    public func verify(_ passcode: String) -> Bool {
        guard let record = load() else { return false }
        return PasscodeHasher.matches(passcode, record: record)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasscodeError.keychain(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PasscodeStoreTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Security Tests/AlarmCoreTests/PasscodeStoreTests.swift
git commit -m "feat: PBKDF2-hashed passcode storage in the Keychain"
```

---

### Task 7: Forcing audio output to maximum

The siren is worthless if the Mac is muted or on headphones. This captures the audio state, forces built-in speakers to full volume, and restores everything on disarm.

**Files:**
- Create: `Sources/AlarmCore/Audio/AudioOutputControl.swift`
- Test: `Tests/AlarmCoreTests/AudioOutputTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AudioOutputState` (`deviceID: UInt32`, `volume: Float`, `muted: Bool`), `AudioOutputControlling` (`currentState()`, `forceMaxVolumeOnBuiltInSpeakers()`, `restore(_:)`), `CoreAudioOutputControl`, `FakeAudioOutputControl` (`.state`, `.forceCount`, `.restoredStates`). Task 8 composes this into `SirenResponse`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/AudioOutputTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func forcingSetsFullVolumeAndUnmutes() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.2, muted: true))
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    #expect(audio.state.volume == 1.0)
    #expect(audio.state.muted == false)
}

@Test func restoringPutsBackTheCapturedState() {
    let original = AudioOutputState(deviceID: 1, volume: 0.2, muted: true)
    let audio = FakeAudioOutputControl(state: original)
    let captured = audio.currentState()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    audio.restore(captured)
    #expect(audio.state == original)
}

// The state captured before forcing must be the pre-force state, or disarming
// would restore full volume and leave the user deafened.
@Test func capturedStateIsUnaffectedByLaterForcing() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.35, muted: false))
    let captured = audio.currentState()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    #expect(captured.volume == 0.35)
}

@Test func forcingIsIdempotent() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.2, muted: true))
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    #expect(audio.forceCount == 2)
    #expect(audio.state.volume == 1.0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioOutputTests`
Expected: FAIL — `cannot find 'FakeAudioOutputControl' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Audio/AudioOutputControl.swift
import Foundation
import CoreAudio

public struct AudioOutputState: Equatable, Sendable {
    public let deviceID: UInt32
    public let volume: Float
    public let muted: Bool
    public init(deviceID: UInt32, volume: Float, muted: Bool) {
        self.deviceID = deviceID
        self.volume = volume
        self.muted = muted
    }
}

public protocol AudioOutputControlling: AnyObject {
    func currentState() -> AudioOutputState
    func forceMaxVolumeOnBuiltInSpeakers() throws
    func restore(_ state: AudioOutputState)
}

/// Real CoreAudio implementation. Verified 2026-09-02: the built-in output
/// reports transport type `bltn` and exposes a settable main-element volume.
public final class CoreAudioOutputControl: AudioOutputControlling {
    public init() {}

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private var defaultOutputDevice: AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &device)
        return device
    }

    private func volume(of device: AudioDeviceID) -> Float {
        var addr = address(kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr),
              AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                         &size, &value) == noErr
        else { return channelVolume(of: device) }
        return value
    }

    /// Some devices expose no main-element volume, only per-channel volume.
    private func channelVolume(of device: AudioDeviceID) -> Float {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 1)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr),
              AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                         &size, &value) == noErr
        else { return 0 }
        return value
    }

    private func setVolume(_ value: Float, on device: AudioDeviceID) {
        var v = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        var main = address(kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput)
        if AudioObjectHasProperty(AudioObjectID(device), &main),
           AudioObjectSetPropertyData(AudioObjectID(device), &main, 0, nil,
                                      size, &v) == noErr {
            return
        }
        // Fall back to per-channel (stereo) volume.
        for channel in UInt32(1)...UInt32(2) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(AudioObjectID(device), &addr) else { continue }
            AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil, size, &v)
        }
    }

    private func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr),
              AudioObjectGetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                         &size, &value) == noErr
        else { return false }
        return value == 1
    }

    private func setMuted(_ muted: Bool, on device: AudioDeviceID) {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(AudioObjectID(device), &addr) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(AudioObjectID(device), &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func setDefaultOutputDevice(_ device: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal)
        var value = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    /// Finds the internal speakers, so headphones cannot silence the alarm.
    private func builtInOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devices) == noErr else { return nil }

        return devices.first { device in
            var transportAddr = address(kAudioDevicePropertyTransportType,
                                        kAudioObjectPropertyScopeGlobal)
            var transport = UInt32(0)
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(device), &transportAddr, 0, nil,
                                             &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }

            // Must actually have output streams — the built-in mic also reports `bltn`.
            var streamAddr = address(kAudioDevicePropertyStreams,
                                     kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(device), &streamAddr, 0, nil,
                                                 &streamSize) == noErr else { return false }
            return streamSize > 0
        }
    }

    public func currentState() -> AudioOutputState {
        let device = defaultOutputDevice
        return AudioOutputState(deviceID: UInt32(device),
                                volume: volume(of: device),
                                muted: isMuted(device))
    }

    public func forceMaxVolumeOnBuiltInSpeakers() throws {
        if let builtIn = builtInOutputDevice(), builtIn != defaultOutputDevice {
            setDefaultOutputDevice(builtIn)
        }
        let device = defaultOutputDevice
        setMuted(false, on: device)
        setVolume(1.0, on: device)
    }

    public func restore(_ state: AudioOutputState) {
        let device = AudioDeviceID(state.deviceID)
        setDefaultOutputDevice(device)
        setVolume(state.volume, on: device)
        setMuted(state.muted, on: device)
    }
}

public final class FakeAudioOutputControl: AudioOutputControlling {
    public private(set) var state: AudioOutputState
    public private(set) var forceCount = 0
    public private(set) var restoredStates: [AudioOutputState] = []

    public init(state: AudioOutputState) { self.state = state }

    public func currentState() -> AudioOutputState { state }

    public func forceMaxVolumeOnBuiltInSpeakers() throws {
        forceCount += 1
        state = AudioOutputState(deviceID: state.deviceID, volume: 1.0, muted: false)
    }

    public func restore(_ state: AudioOutputState) {
        restoredStates.append(state)
        self.state = state
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioOutputTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Audio Tests/AlarmCoreTests/AudioOutputTests.swift
git commit -m "feat: force built-in speakers to max volume with state restore"
```

---

### Task 8: Synthesised siren and the siren response

The siren is generated at runtime — a two-tone sweep via `AVAudioSourceNode` — so the product ships no licensed audio assets.

**Files:**
- Create: `Sources/AlarmCore/Audio/SirenPlayer.swift`
- Create: `Sources/AlarmCore/Responses/SirenResponse.swift`
- Test: `Tests/AlarmCoreTests/SirenResponseTests.swift`

**Interfaces:**
- Consumes: `Response`, `AlarmContext` (Task 4); `AudioOutputControlling`, `FakeAudioOutputControl` (Task 7).
- Produces: `SirenPlaying` (`isPlaying`, `start()`, `stop()`), `AVSirenPlayer`, `FakeSirenPlayer` (`startCount`, `stopCount`), `SirenResponse(player:audio:)` with `identifier == "siren"`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/SirenResponseTests.swift
import Testing
import Foundation
@testable import AlarmCore

private let ctx = AlarmContext(trigger: TriggerID("power"),
                               firedAt: Date(timeIntervalSince1970: 0))

private func makeResponse(volume: Float = 0.3, muted: Bool = true)
    -> (SirenResponse, FakeSirenPlayer, FakeAudioOutputControl) {
    let player = FakeSirenPlayer()
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: volume, muted: muted))
    return (SirenResponse(player: player, audio: audio), player, audio)
}

@Test func firingStartsThePlayerAtFullVolume() async {
    let (response, player, audio) = makeResponse()
    await response.fire(context: ctx)
    #expect(player.isPlaying == true)
    #expect(audio.state.volume == 1.0)
    #expect(audio.state.muted == false)
}

@Test func resettingStopsThePlayerAndRestoresAudio() async {
    let (response, player, audio) = makeResponse(volume: 0.3, muted: true)
    await response.fire(context: ctx)
    await response.reset()
    #expect(player.isPlaying == false)
    #expect(audio.state == AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
}

// Firing twice must not overwrite the saved state with the forced state, or
// disarming would leave the machine at full volume.
@Test func firingTwiceStillRestoresTheOriginalVolume() async {
    let (response, _, audio) = makeResponse(volume: 0.3, muted: false)
    await response.fire(context: ctx)
    await response.fire(context: ctx)
    await response.reset()
    #expect(audio.state.volume == 0.3)
}

@Test func resettingWithoutFiringIsHarmless() async {
    let (response, player, audio) = makeResponse(volume: 0.3, muted: false)
    await response.reset()
    #expect(player.stopCount == 1)
    #expect(audio.restoredStates.isEmpty)
}

@Test func sirenIsAlwaysAvailable() {
    let (response, _, _) = makeResponse()
    #expect(response.isAvailable == true)
    #expect(response.identifier == "siren")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SirenResponseTests`
Expected: FAIL — `cannot find 'SirenResponse' in scope`.

- [ ] **Step 3: Write the player**

```swift
// Sources/AlarmCore/Audio/SirenPlayer.swift
import Foundation
import AVFoundation

public protocol SirenPlaying: AnyObject {
    var isPlaying: Bool { get }
    func start()
    func stop()
}

/// Generates a two-tone siren in real time. No bundled audio asset, so there
/// is no sample licence to worry about in a paid product.
public final class AVSirenPlayer: SirenPlaying {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var phase: Double = 0
    private var elapsed: Double = 0
    public private(set) var isPlaying = false

    private let lowHz = 700.0
    private let highHz = 1100.0
    private let sweepSeconds = 0.5

    public init() {}

    public func start() {
        guard !isPlaying else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // Triangle sweep between the two tones.
                let cyclePosition = self.elapsed
                    .truncatingRemainder(dividingBy: self.sweepSeconds * 2) / self.sweepSeconds
                let ramp = cyclePosition < 1 ? cyclePosition : 2 - cyclePosition
                let frequency = self.lowHz + (self.highHz - self.lowHz) * ramp

                let sample = Float(sin(self.phase) * 0.9)
                self.phase += 2 * .pi * frequency / sampleRate
                if self.phase > 2 * .pi { self.phase -= 2 * .pi }
                self.elapsed += 1 / sampleRate

                for buffer in buffers {
                    let pointer = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < pointer.count { pointer[frame] = sample }
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            isPlaying = true
        } catch {
            engine.detach(node)
            sourceNode = nil
        }
    }

    public func stop() {
        guard isPlaying else { return }
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        phase = 0
        elapsed = 0
        isPlaying = false
    }
}

public final class FakeSirenPlayer: SirenPlaying {
    public private(set) var isPlaying = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public init() {}
    public func start() { startCount += 1; isPlaying = true }
    public func stop() { stopCount += 1; isPlaying = false }
}
```

- [ ] **Step 4: Write the response**

```swift
// Sources/AlarmCore/Responses/SirenResponse.swift
import Foundation

/// Forces the speakers to full volume and sounds the siren, restoring the
/// user's audio settings on reset.
public final class SirenResponse: Response {
    public let identifier = "siren"
    public let isAvailable = true

    private let player: SirenPlaying
    private let audio: AudioOutputControlling
    /// Captured on the first fire only, so a repeat fire cannot overwrite it
    /// with the already-forced state.
    private var savedState: AudioOutputState?

    public init(player: SirenPlaying, audio: AudioOutputControlling) {
        self.player = player
        self.audio = audio
    }

    public func fire(context: AlarmContext) async {
        if savedState == nil { savedState = audio.currentState() }
        try? audio.forceMaxVolumeOnBuiltInSpeakers()
        player.start()
    }

    public func reset() async {
        player.stop()
        if let savedState {
            audio.restore(savedState)
            self.savedState = nil
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SirenResponseTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AlarmCore/Audio/SirenPlayer.swift Sources/AlarmCore/Responses Tests/AlarmCoreTests/SirenResponseTests.swift
git commit -m "feat: runtime-synthesised siren with audio state restore"
```

---

### Task 9: Screen lock response, gated by capability

Uses the private `SACLockScreenImmediate`. **Direct build only** — this is exactly the feature the App Store build drops, so it must degrade cleanly to `isAvailable == false` rather than crash.

**Files:**
- Create: `Sources/AlarmCore/Responses/ScreenLockResponse.swift`
- Test: `Tests/AlarmCoreTests/ScreenLockResponseTests.swift`

**Interfaces:**
- Consumes: `Response`, `AlarmContext` (Task 4).
- Produces: `ScreenLocking` (`isAvailable`, `lock()`), `LoginFrameworkScreenLocker`, `FakeScreenLocker` (`lockCount`), `ScreenLockResponse(locker:)` with `identifier == "screen-lock"`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/ScreenLockResponseTests.swift
import Testing
import Foundation
@testable import AlarmCore

private let ctx = AlarmContext(trigger: TriggerID("power"),
                               firedAt: Date(timeIntervalSince1970: 0))

@Test func firingLocksTheScreen() async {
    let locker = FakeScreenLocker(isAvailable: true)
    let response = ScreenLockResponse(locker: locker)
    await response.fire(context: ctx)
    #expect(locker.lockCount == 1)
}

@Test func unavailableLockerMakesTheResponseUnavailable() {
    let response = ScreenLockResponse(locker: FakeScreenLocker(isAvailable: false))
    #expect(response.isAvailable == false)
}

// Under sandbox the symbol is missing; firing anyway must be a silent no-op.
@Test func firingWithUnavailableLockerDoesNothing() async {
    let locker = FakeScreenLocker(isAvailable: false)
    let response = ScreenLockResponse(locker: locker)
    await response.fire(context: ctx)
    #expect(locker.lockCount == 0)
}

// Unlocking the Mac is the disarm; there is nothing to undo.
@Test func resetDoesNotUnlock() async {
    let locker = FakeScreenLocker(isAvailable: true)
    let response = ScreenLockResponse(locker: locker)
    await response.fire(context: ctx)
    await response.reset()
    #expect(locker.lockCount == 1)
}

@Test func realLockerFindsTheSymbolOnThisMachine() {
    // Verified present 2026-09-02. Fails under sandbox, which is the point.
    #expect(LoginFrameworkScreenLocker().isAvailable == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScreenLockResponseTests`
Expected: FAIL — `cannot find 'ScreenLockResponse' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Responses/ScreenLockResponse.swift
import Foundation

public protocol ScreenLocking: AnyObject {
    var isAvailable: Bool { get }
    func lock()
}

/// Wraps the private `SACLockScreenImmediate`. There is no public API for
/// locking the screen, so the App Store build will simply report
/// `isAvailable == false` and the engine will skip this response.
public final class LoginFrameworkScreenLocker: ScreenLocking {
    private typealias LockFn = @convention(c) () -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let symbol: LockFn?

    public init() {
        handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            RTLD_LAZY)
        if let handle, let sym = dlsym(handle, "SACLockScreenImmediate") {
            symbol = unsafeBitCast(sym, to: LockFn.self)
        } else {
            symbol = nil
        }
    }

    public var isAvailable: Bool { symbol != nil }

    public func lock() { _ = symbol?() }
}

public final class FakeScreenLocker: ScreenLocking {
    public let isAvailable: Bool
    public private(set) var lockCount = 0
    public init(isAvailable: Bool) { self.isAvailable = isAvailable }
    public func lock() { guard isAvailable else { return }; lockCount += 1 }
}

/// Locks the screen so a thief cannot browse an open session while it screams.
/// Deliberately has no `reset`: unlocking the Mac is the disarm.
public final class ScreenLockResponse: Response {
    public let identifier = "screen-lock"
    private let locker: ScreenLocking

    public init(locker: ScreenLocking) { self.locker = locker }

    public var isAvailable: Bool { locker.isAvailable }

    public func fire(context: AlarmContext) async {
        guard locker.isAvailable else { return }
        locker.lock()
    }

    public func reset() async {}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScreenLockResponseTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Responses/ScreenLockResponse.swift Tests/AlarmCoreTests/ScreenLockResponseTests.swift
git commit -m "feat: capability-gated screen lock response"
```

---

### Task 10: Sleep assertion held while armed

**Files:**
- Create: `Sources/AlarmCore/Security/SleepAssertion.swift`
- Test: `Tests/AlarmCoreTests/SleepAssertionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SleepPreventing` (`isHeld`, `acquire(reason:)`, `release()`), `IOKitSleepAssertion`, `FakeSleepAssertion` (`acquireCount`, `releaseCount`, `lastReason`). Task 11 acquires on arm and releases on disarm.

If Task 1 concluded **SLEEPS**, this task is still built exactly as written — it correctly prevents idle sleep, which matters for the machine sitting untouched on a table. Only the marketing claim about lid-closed protection changes.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/SleepAssertionTests.swift
import Testing
@testable import AlarmCore

@Test func acquiringHoldsTheAssertion() {
    let assertion = FakeSleepAssertion()
    assertion.acquire(reason: "armed")
    #expect(assertion.isHeld == true)
    #expect(assertion.lastReason == "armed")
}

@Test func releasingDropsTheAssertion() {
    let assertion = FakeSleepAssertion()
    assertion.acquire(reason: "armed")
    assertion.release()
    #expect(assertion.isHeld == false)
}

@Test func acquiringTwiceDoesNotDoubleAcquire() {
    let assertion = FakeSleepAssertion()
    assertion.acquire(reason: "armed")
    assertion.acquire(reason: "armed")
    #expect(assertion.acquireCount == 1)
}

@Test func releasingWithoutAcquiringIsHarmless() {
    let assertion = FakeSleepAssertion()
    assertion.release()
    #expect(assertion.releaseCount == 0)
    #expect(assertion.isHeld == false)
}

// Verified grantable 2026-09-02.
@Test func realAssertionCanBeAcquiredAndReleased() {
    let assertion = IOKitSleepAssertion()
    assertion.acquire(reason: "unit test")
    #expect(assertion.isHeld == true)
    assertion.release()
    #expect(assertion.isHeld == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SleepAssertionTests`
Expected: FAIL — `cannot find 'FakeSleepAssertion' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Security/SleepAssertion.swift
import Foundation
import IOKit.pwr_mgt

public protocol SleepPreventing: AnyObject {
    var isHeld: Bool { get }
    func acquire(reason: String)
    func release()
}

/// Holds both idle-sleep and system-sleep assertions while the alarm is armed.
/// Both were verified grantable on 2026-09-02; whether they defeat *clamshell*
/// sleep is recorded in the Phase 0 finding.
public final class IOKitSleepAssertion: SleepPreventing {
    private var ids: [IOPMAssertionID] = []
    public init() {}
    public var isHeld: Bool { !ids.isEmpty }

    public func acquire(reason: String) {
        guard ids.isEmpty else { return }
        for type in [kIOPMAssertPreventUserIdleSystemSleep,
                     kIOPMAssertionTypePreventSystemSleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id)
            if result == kIOReturnSuccess { ids.append(id) }
        }
    }

    public func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
    }
}

public final class FakeSleepAssertion: SleepPreventing {
    public private(set) var isHeld = false
    public private(set) var acquireCount = 0
    public private(set) var releaseCount = 0
    public private(set) var lastReason: String?
    public init() {}

    public func acquire(reason: String) {
        guard !isHeld else { return }
        isHeld = true
        acquireCount += 1
        lastReason = reason
    }

    public func release() {
        guard isHeld else { return }
        isHeld = false
        releaseCount += 1
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SleepAssertionTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Security/SleepAssertion.swift Tests/AlarmCoreTests/SleepAssertionTests.swift
git commit -m "feat: sleep assertion held while armed"
```

---

### Task 11: The alarm engine

Wires triggers, responses, clock, passcode and sleep assertion onto the Task 3 state machine. Fully tested through fakes — no unplugging, no waiting, no noise.

**Files:**
- Create: `Sources/AlarmCore/Engine/AlarmEngine.swift`
- Test: `Tests/AlarmCoreTests/AlarmEngineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2-10.
- Produces: `AlarmEngine(triggers:responses:clock:passcodes:sleepAssertion:)`, `.state`, `.onStateChange`, `.arm() throws`, `.disarm(passcode:) -> Bool`, `AlarmEngineError.noPasscodeSet`. Task 12's UI drives exactly this surface.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/AlarmEngineTests.swift
import Testing
import Foundation
@testable import AlarmCore

private struct Rig {
    let engine: AlarmEngine
    let trigger: FakeTrigger
    let siren: FakeResponse
    let unavailable: FakeResponse
    let clock: TestClock
    let sleep: FakeSleepAssertion
}

private func makeRig(graceSeconds: TimeInterval = 0, passcode: String = "1234") -> Rig {
    let trigger = FakeTrigger(id: TriggerID("power"), graceSeconds: graceSeconds)
    let siren = FakeResponse(identifier: "siren")
    let unavailable = FakeResponse(identifier: "screen-lock", isAvailable: false)
    let clock = TestClock()
    let sleep = FakeSleepAssertion()
    let store = InMemoryPasscodeStore()
    try? store.setPasscode(passcode)
    let engine = AlarmEngine(triggers: [trigger],
                             responses: [siren, unavailable],
                             clock: clock,
                             passcodes: store,
                             sleepAssertion: sleep)
    return Rig(engine: engine, trigger: trigger, siren: siren,
               unavailable: unavailable, clock: clock, sleep: sleep)
}

@Test func armingStartsTriggersAndHoldsSleepAssertion() throws {
    let rig = makeRig()
    try rig.engine.arm()
    #expect(rig.engine.state == .armed)
    #expect(rig.trigger.isStarted == true)
    #expect(rig.sleep.isHeld == true)
}

@Test func armingWithoutAPasscodeThrows() {
    let engine = AlarmEngine(triggers: [], responses: [], clock: TestClock(),
                             passcodes: InMemoryPasscodeStore(),
                             sleepAssertion: FakeSleepAssertion())
    #expect(throws: AlarmEngineError.noPasscodeSet) { try engine.arm() }
}

@Test func triggerWithoutGraceFiresResponsesImmediately() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.engine.state == .firing(trigger: TriggerID("power")))
    #expect(rig.siren.fireCount == 1)
}

@Test func unavailableResponsesAreNeverFired() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.unavailable.fireCount == 0)
}

@Test func graceDelaysFiring() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    #expect(rig.engine.state == .grace(until: rig.clock.now.addingTimeInterval(10),
                                       trigger: TriggerID("power")))
    #expect(rig.siren.fireCount == 0)
    rig.clock.advance(by: 10)
    await Task.yield()
    #expect(rig.siren.fireCount == 1)
}

@Test func disarmingDuringGraceCancelsTheAlarm() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    #expect(rig.engine.disarm(passcode: "1234") == true)
    rig.clock.advance(by: 30)
    await Task.yield()
    #expect(rig.siren.fireCount == 0)
    #expect(rig.engine.state == .disarmed)
}

@Test func correctPasscodeStopsTheSiren() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.engine.disarm(passcode: "1234") == true)
    await Task.yield()
    #expect(rig.siren.resetCount == 1)
    #expect(rig.engine.state == .disarmed)
}

@Test func wrongPasscodeLeavesTheSirenSounding() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.engine.disarm(passcode: "wrong") == false)
    #expect(rig.engine.state == .firing(trigger: TriggerID("power")))
    #expect(rig.siren.resetCount == 0)
}

@Test func disarmingStopsTriggersAndReleasesSleepAssertion() throws {
    let rig = makeRig()
    try rig.engine.arm()
    _ = rig.engine.disarm(passcode: "1234")
    #expect(rig.trigger.isStarted == false)
    #expect(rig.sleep.isHeld == false)
}

@Test func stateChangesAreObservable() throws {
    let rig = makeRig()
    var observed: [AlarmState] = []
    rig.engine.onStateChange = { observed.append($0) }
    try rig.engine.arm()
    _ = rig.engine.disarm(passcode: "1234")
    #expect(observed == [.armed, .disarmed])
}

// Re-arming after an alarm must work, or the app is single-use.
@Test func rearmingAfterAnAlarmWorks() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    _ = rig.engine.disarm(passcode: "1234")
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.siren.fireCount == 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AlarmEngineTests`
Expected: FAIL — `cannot find 'AlarmEngine' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Engine/AlarmEngine.swift
import Foundation

public enum AlarmEngineError: Error, Equatable {
    case noPasscodeSet
}

/// Orchestrates triggers, responses and the state machine.
///
/// Main-actor isolated: triggers deliver callbacks from IOKit run-loop sources
/// and the UI observes state, so a single actor removes the need for locking.
public final class AlarmEngine {
    private let triggers: [any Trigger]
    private let responses: [any Response]
    private let clock: AlarmClock
    private let passcodes: PasscodeStoring
    private let sleepAssertion: SleepPreventing?
    private var graceWork: ScheduledWork?

    public private(set) var state: AlarmState = .disarmed {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public var onStateChange: ((AlarmState) -> Void)?

    public init(triggers: [any Trigger],
                responses: [any Response],
                clock: AlarmClock,
                passcodes: PasscodeStoring,
                sleepAssertion: SleepPreventing?) {
        // Capability gating: unavailable features are dropped here, once.
        self.triggers = triggers.filter(\.isAvailable)
        self.responses = responses.filter(\.isAvailable)
        self.clock = clock
        self.passcodes = passcodes
        self.sleepAssertion = sleepAssertion
    }

    public func arm() throws {
        guard passcodes.hasPasscode else { throw AlarmEngineError.noPasscodeSet }
        guard state == .disarmed else { return }

        for trigger in triggers {
            let grace = trigger.graceSeconds
            try? trigger.start { [weak self] id in
                self?.handleTrigger(id, graceSeconds: grace)
            }
        }
        sleepAssertion?.acquire(reason: "LaptopAlarm armed")
        state = reduce(state, .arm, now: clock.now)
    }

    @discardableResult
    public func disarm(passcode: String) -> Bool {
        guard passcodes.verify(passcode) else { return false }
        graceWork?.cancel()
        graceWork = nil
        triggers.forEach { $0.stop() }
        sleepAssertion?.release()
        state = reduce(state, .disarm, now: clock.now)
        Task { for response in responses { await response.reset() } }
        return true
    }

    func handleTrigger(_ id: TriggerID, graceSeconds: TimeInterval) {
        let next = reduce(state, .triggered(id, graceSeconds: graceSeconds),
                          now: clock.now)
        guard next != state else { return }
        state = next

        switch next {
        case .grace:
            graceWork = clock.schedule(after: graceSeconds) { [weak self] in
                self?.graceExpired()
            }
        case .firing:
            fireResponses(trigger: id)
        default:
            break
        }
    }

    private func graceExpired() {
        let next = reduce(state, .graceExpired, now: clock.now)
        guard next != state else { return }
        state = next
        if case let .firing(id) = next { fireResponses(trigger: id) }
    }

    private func fireResponses(trigger: TriggerID) {
        let context = AlarmContext(trigger: trigger, firedAt: clock.now)
        Task { for response in responses { await response.fire(context: context) } }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AlarmEngineTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, **64 tests**, no concurrency warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/AlarmCore/Engine/AlarmEngine.swift Tests/AlarmCoreTests/AlarmEngineTests.swift
git commit -m "feat: alarm engine wiring triggers, responses and grace periods"
```

---

### Task 12: Menu bar app and bundle assembly

**Files:**
- Delete: `Sources/LaptopAlarm/Placeholder.swift`
- Create: `Sources/LaptopAlarm/LaptopAlarmApp.swift`
- Create: `Sources/LaptopAlarm/AppModel.swift`
- Create: `Sources/LaptopAlarm/MenuBarContent.swift`
- Create: `Sources/LaptopAlarm/DisarmPanel.swift`
- Create: `Scripts/make-bundle.sh`

**Interfaces:**
- Consumes: `AlarmEngine`, `AlarmState`, `PowerTrigger`, `IOKitPowerSourceMonitor`, `SirenResponse`, `AVSirenPlayer`, `CoreAudioOutputControl`, `ScreenLockResponse`, `LoginFrameworkScreenLocker`, `KeychainPasscodeStore`, `IOKitSleepAssertion`, `SystemClock`.
- Produces: a runnable `LaptopAlarm.app`. Phase 5 replaces this bundling step with an Xcode project for the sandboxed target.

- [ ] **Step 1: Write the app model**

```swift
// Sources/LaptopAlarm/AppModel.swift
import SwiftUI
import AlarmCore

final class AppModel: ObservableObject {
    @Published private(set) var state: AlarmState = .disarmed
    @Published var passcodeEntry = ""
    @Published var errorMessage: String?
    @Published var needsPasscodeSetup: Bool

    private let engine: AlarmEngine
    private let passcodes: KeychainPasscodeStore

    init() {
        let passcodes = KeychainPasscodeStore()
        self.passcodes = passcodes
        self.needsPasscodeSetup = !passcodes.hasPasscode

        let trigger = PowerTrigger(monitor: IOKitPowerSourceMonitor(),
                                   graceSeconds: 10)
        let siren = SirenResponse(player: AVSirenPlayer(),
                                  audio: CoreAudioOutputControl())
        let lock = ScreenLockResponse(locker: LoginFrameworkScreenLocker())

        engine = AlarmEngine(triggers: [trigger],
                             responses: [siren, lock],
                             clock: SystemClock(),
                             passcodes: passcodes,
                             sleepAssertion: IOKitSleepAssertion())
        engine.onStateChange = { [weak self] newState in
            self?.state = newState
        }
    }

    var isArmed: Bool { state != .disarmed }
    var isFiring: Bool { if case .firing = state { return true }; return false }

    func setPasscode(_ passcode: String) {
        do {
            try passcodes.setPasscode(passcode)
            needsPasscodeSetup = false
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the passcode."
        }
    }

    func arm() {
        do {
            try engine.arm()
            errorMessage = nil
        } catch AlarmEngineError.noPasscodeSet {
            needsPasscodeSetup = true
            errorMessage = "Set a passcode before arming."
        } catch {
            errorMessage = "Could not arm."
        }
    }

    func disarm() {
        if engine.disarm(passcode: passcodeEntry) {
            passcodeEntry = ""
            errorMessage = nil
        } else {
            passcodeEntry = ""
            errorMessage = "Wrong passcode."
        }
    }
}
```

- [ ] **Step 2: Write the views**

```swift
// Sources/LaptopAlarm/MenuBarContent.swift
import SwiftUI
import AlarmCore

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText).font(.headline)

            if model.needsPasscodeSetup {
                PasscodeSetupField(model: model)
            } else if model.isArmed {
                DisarmPanel(model: model)
            } else {
                Button("Arm") { model.arm() }
                    .keyboardShortcut("a")
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var statusText: String {
        switch model.state {
        case .disarmed: "Disarmed"
        case .armed: "Armed"
        case .grace: "Triggered — disarm now"
        case .firing: "ALARM"
        }
    }
}

struct PasscodeSetupField: View {
    @ObservedObject var model: AppModel
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose a passcode to disarm the alarm.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Passcode", text: $entry)
                .onSubmit { model.setPasscode(entry); entry = "" }
            Button("Save") { model.setPasscode(entry); entry = "" }
                .disabled(entry.isEmpty)
        }
    }
}
```

```swift
// Sources/LaptopAlarm/DisarmPanel.swift
import SwiftUI

struct DisarmPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Passcode", text: $model.passcodeEntry)
                .onSubmit { model.disarm() }
            Button("Disarm") { model.disarm() }
                .disabled(model.passcodeEntry.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }
}
```

```swift
// Sources/LaptopAlarm/LaptopAlarmApp.swift
import SwiftUI

@main
struct LaptopAlarmApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isFiring
                  ? "bell.badge.fill"
                  : (model.isArmed ? "lock.shield.fill" : "lock.shield"))
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Write the bundle script**

```bash
# Scripts/make-bundle.sh
#!/bin/bash
set -euo pipefail

APP_NAME="LaptopAlarm"
BUNDLE_ID="com.jernejkocica.laptopalarm"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"

swift build -c release --product "${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature is enough for local runs; Phase 6 switches to Developer ID.
codesign --force --deep --sign - "${APP_DIR}"
echo "Built ${APP_DIR}"
```

Make it executable:

```bash
chmod +x Scripts/make-bundle.sh
```

- [ ] **Step 4: Build the bundle**

Run: `./Scripts/make-bundle.sh`
Expected: `Built build/LaptopAlarm.app`, no compiler errors.

- [ ] **Step 5: Verify it launches**

Run: `open build/LaptopAlarm.app`
Expected: a shield icon appears in the menu bar, no Dock icon. Clicking it shows the passcode setup field on first run.

- [ ] **Step 6: Commit**

```bash
rm -f Sources/LaptopAlarm/Placeholder.swift
git add -A Sources/LaptopAlarm Scripts/make-bundle.sh
git commit -m "feat: menu bar app and bundle assembly script"
```

---

### Task 13: End-to-end verification

Automated tests cannot prove the siren is audible or that the screen actually locks. This task is manual and its output is a written record.

**Files:**
- Create: `docs/superpowers/specs/2026-09-02-phase1-acceptance.md`

**Interfaces:**
- Consumes: `build/LaptopAlarm.app` (Task 12).
- Produces: a pass/fail record per scenario. Any failure becomes a bug task before Phase 2 starts.

- [ ] **Step 1: Run the full automated suite**

Run: `swift test`
Expected: all tests pass. Record the count.

- [ ] **Step 2: Walk the acceptance scenarios**

For each, record PASS or FAIL with a note. **Plug the charger in before each run.**

1. **First-run setup** — launch, click the icon, set passcode "1234". The setup field is replaced by an Arm button.
2. **Arm** — click Arm. The icon changes to a filled shield.
3. **Grace period** — unplug the charger. Nothing sounds yet; the status reads "Triggered — disarm now".
4. **Disarm during grace** — enter "1234" within 10 seconds. No siren ever sounds; status returns to Disarmed.
5. **Full alarm** — re-arm, set system volume to ~10%, mute the Mac, unplug, and wait out the 10 seconds. The siren sounds at **full volume despite the mute**, and the screen locks.
6. **Wrong passcode** — log back in, enter "9999". The siren keeps sounding and "Wrong passcode." appears.
7. **Correct passcode** — enter "1234". The siren stops **and the system volume returns to ~10%, still muted.** This is the regression that Task 8's tests guard.
8. **Headphone defeat** — plug in headphones or connect Bluetooth ones, arm, unplug. The siren must come out of the **built-in speakers**.
9. **Re-arm** — arm again and repeat scenario 5. The alarm fires a second time.
10. **Idle sleep** — arm, leave the machine untouched past its display-sleep timeout. It must not sleep.
11. **Lid close** — arm, unplug, close the lid for 30 seconds, reopen. Record whether the siren was still sounding. **Compare against the Task 1 finding**; a discrepancy means the assertion is not being held while armed.
12. **Disarmed safety** — quit and relaunch the app without arming. Unplug the charger. **Nothing must happen.**

- [ ] **Step 3: Record the results and commit**

Write `docs/superpowers/specs/2026-09-02-phase1-acceptance.md` with the test count from Step 1 and the twelve scenario results. For any FAIL, note the observed behaviour precisely.

```bash
git add docs/superpowers/specs/2026-09-02-phase1-acceptance.md
git commit -m "docs: Phase 1 acceptance test results"
```

- [ ] **Step 4: Decide**

If scenarios 5, 7, 8 or 12 failed, fix before Phase 2 — those are the core promise of the product. A failure in 11 is expected if Task 1 concluded SLEEPS and is not a blocker.

---

## Out of scope for this plan

Deliberately excluded, each with its own later plan: camera ego-motion detection and the sensitivity Test window (Phase 2); lid-angle and Wi-Fi triggers (Phase 3); snapshot, location and `AlertTransport`/ntfy (Phase 4); the sandboxed Mac App Store target and entitlements (Phase 5); onboarding, licensing, notarisation and the privacy policy (Phase 6).
