# MacBook Anti-Theft Alarm — Design

**Date:** 2026-09-02
**Status:** Approved for planning
**Target hardware:** Apple Silicon MacBook Pro (verified on Mac17,9 / M5 Pro, macOS 26.5)

## 1. Purpose

A menu-bar macOS app that makes physically stealing an unattended MacBook loud,
conspicuous, and evidence-generating. Sold commercially for a low single-digit
EUR price, shipped simultaneously to the Mac App Store and as a direct download.

**Explicit non-goal:** this is a deterrent, not a recovery system. Find My,
Activation Lock, and FileVault remain the user's actual protection. Marketing
copy must not imply otherwise, and onboarding actively tells the user to enable
them.

## 2. Hardware constraints (verified, not assumed)

Probed on the target machine before design:

| Capability | Finding |
|---|---|
| Accelerometer / Sudden Motion Sensor | **Absent.** `ioreg -c SMCMotionSensor` returns nothing; zero motion keys in the IOKit registry. Apple removed the SMS along with spinning disks. True inertial motion detection is impossible. |
| Lid angle sensor | **Present.** HID device, VendorID `0x05AC`, ProductID `0x8104`, usage page `0x20` (Sensors), usage `0x8A`. Reports hinge angle continuously. |
| AC power state | Available via IOKit power sources. No permissions. |
| Code signing | `Apple Development` identity present. `Developer ID Application` and `Apple Distribution` still required for sale (paid Apple Developer Program). |

The absent accelerometer is the single most design-shaping fact: "the laptop was
moved" must be inferred from the camera and the hinge, not measured directly.

## 3. Core algorithm: ego-motion vs. scene motion

Naive frame differencing is unusable — the primary environment is a cafe, where
people walk past constantly and would trigger it continuously. The app must
distinguish **the camera moving** from **the world moving in front of a still
camera**.

The discriminator is whether a *single global transform* explains the change
between frames.

Per frame pair, at ~5 fps on 320x240 grayscale:

1. `VNTranslationalImageRegistrationRequest` (previous -> current) yields the best
   global alignment transform. Take its translation `(tx, ty)`.
2. `shift = hypot(tx, ty) / frameWidth` — normalized global displacement.
3. `residualRaw    = mean|current - previous|`
   `residualWarped = mean|current - warp(previous, transform)|`
   `explained      = 1 - residualWarped / max(residualRaw, epsilon)`
4. `movementScore  = shift * explained`
5. Fire when `movementScore > threshold` for **K consecutive frames** (default K=3,
   i.e. ~600 ms).

Behaviour by scenario:

| Scenario | shift | explained | score | Outcome |
|---|---|---|---|---|
| Person walks past | ~0 (background dominates and is static) | low | ~0 | Ignored |
| Lighting change (cloud, lamp) | ~0 | low (no translation explains it) | ~0 | Ignored |
| Laptop lifted or turned | large | high (warp explains nearly everything) | large | **Alarm** |

The `explained` term is what makes this robust: it rejects both localized motion
and global illumination change, which are the two dominant false-positive sources.

Known limitation, documented rather than solved: a person filling essentially the
entire frame can be misread as camera motion. At that distance they are close
enough to be reaching for the machine, so the failure mode is acceptable.

**Sensitivity is not tunable in the abstract.** Thresholds correct at a kitchen
table are wrong in a dim cafe. The app ships a live Test window showing the
current `movementScore` in real time so the user can calibrate at the actual
table they sit at. This is a required feature, not a debug aid.

**Corroboration.** Lid angle and camera ego-motion are independent signals that
agree when a machine is picked up. Each can therefore be tuned conservatively on
its own, with a combined high-confidence rule (`angle delta AND coherent frame
shift`) firing at lower individual thresholds.

## 4. Architecture

Capability gating is the backbone, not a refinement. Shipping sandboxed and
unsandboxed builds simultaneously means every trigger and every response declares
its own availability, and the engine composes whatever is present. The App Store
variant is then an entitlements file plus a compile-time flag, never a fork.

```
AlarmCore/                    Swift package. No UI. Fully unit-testable.
  Engine/
    AlarmEngine.swift         State machine, trigger->response orchestration
    AlarmState.swift          disarmed | armed | grace(deadline) | firing
    Capability.swift          Availability gating protocol
  Triggers/
    Trigger.swift             protocol Trigger { var isAvailable: Bool; func start/stop }
    PowerTrigger.swift        AC disconnect (IOPSNotificationCreateRunLoopSource)
    LidAngleTrigger.swift     HID sensor 0x05AC/0x8104        [direct build only]
    ScreenSleepTrigger.swift  screensDidSleepNotification     [MAS fallback]
    WiFiTrigger.swift         CoreWLAN trusted-SSID leave
    BluetoothTrigger.swift    Paired-device disconnect        [P2, direct only]
    MotionTrigger.swift       Camera ego-motion (section 3)
  Vision/
    EgoMotionDetector.swift   The algorithm above. Pure, injectable frame source.
    FrameSource.swift         AVCaptureSession wrapper + test double
  Responses/
    Response.swift            protocol Response { var isAvailable: Bool; func fire }
    SirenResponse.swift
    ScreenLockResponse.swift  SACLockScreenImmediate          [direct build only]
    SnapshotResponse.swift    Webcam burst
    LocationResponse.swift    CoreLocation coarse fix
    AlertResponse.swift       Delegates to AlertTransport (section 6)
  Audio/
    VolumeController.swift    CoreAudio: force output, unmute, volume 1.0, restore
    SirenPlayer.swift         Looping AVAudioPlayer
  Security/
    PasscodeStore.swift       Keychain, salted hash
    SleepAssertion.swift      IOPMAssertion while armed
  Transport/                  See section 6
  Settings/

App/                          Shared SwiftUI
  MenuBarApp.swift            MenuBarExtra
  SettingsView.swift
  SensitivityTestView.swift   Live movementScore calibration
  OnboardingView.swift        Permissions, Find My nudge, ntfy QR pairing

Targets: LaptopAlarm (Developer ID) | LaptopAlarm-MAS (sandboxed)
```

### State machine

`disarmed -> arming (pre-flight capability + permission checks) -> armed`
`armed -> [trigger fires] -> grace(N seconds) -> firing`
`firing -> [disarm] -> disarmed`

Grace period is per-trigger and user-configurable. Defaults: **10 s** for charger
unplug (commonly accidental), **0 s** for motion and lid (rarely accidental once
calibrated). During `grace` the app shows a countdown and plays a soft warning
tone; disarming cancels it.

## 5. Distribution matrix

| Feature | Direct (Developer ID) | Mac App Store (sandboxed) |
|---|---|---|
| Charger unplug | Yes | Yes |
| Siren, forced max volume | Yes | Yes |
| Camera ego-motion, snapshot | Yes | Yes (`com.apple.security.device.camera`) |
| Location | Yes | Yes (`...personal-information.location`) |
| Wi-Fi trusted-network leave | Yes | Yes |
| Push alert | Yes | Yes (`com.apple.security.network.client`) |
| **Lid angle sensor** | Yes | **No** — no sandbox entitlement covers internal HID sensors. Falls back to `screensDidSleepNotification`, which fires only after the lid is shut. |
| **Auto-lock screen** | Yes (`SACLockScreenImmediate`, private) | **No** — private API, automatic rejection. No public equivalent exists. |
| **Relaunch after force-quit** | Yes (LaunchAgent `KeepAlive`) | **No** — cannot install LaunchAgents, and quit-resistance is itself a review risk. |

### Disarm flow differs by build, as a direct consequence

- **Direct build:** the alarm locks the screen, so unlocking the Mac *is* the
  disarm. The account password already proves ownership; no second secret to
  invent or forget. Siren continues over the lock screen.
- **MAS build:** no screen lock, so an always-on-top panel takes an app passcode
  stored in the Keychain. Weaker, and honestly so — a thief can hold the power
  button. Documented, not hidden.

## 6. Alert transport (provider-agnostic)

Push delivery is abstracted so the provider can be replaced without touching the
engine. ntfy.sh is the first implementation, not an assumption baked into the
design — a commercial product will plausibly want its own backend and APNs rather
than depending on a free public service's uptime and world-readable topics.

```swift
struct AlertPayload {            // Provider-neutral. No ntfy vocabulary.
    let title: String
    let body: String
    let urgency: Urgency         // .normal | .high | .critical
    let occurredAt: Date
    let location: CLLocation?
    let images: [Data]           // JPEG snapshots
}

protocol AlertTransport {
    var identifier: String { get }
    var isConfigured: Bool { get }
    func send(_ payload: AlertPayload) async throws
    func sendTestAlert() async throws
}
```

Implementations: `NtfyTransport` (v1), with `APNsTransport`, `PushoverTransport`,
`WebhookTransport`, and `SMTPTransport` as drop-in successors. Selection is
settings-driven; `AlertResponse` holds an `AlertTransport` and knows nothing about
any provider. Failures are queued and retried, and never block the siren.

**NtfyTransport specifics.** Topic is 128 bits of randomness generated at first
launch and stored in the Keychain — on ntfy.sh, topic secrecy *is* the access
control, since anyone who guesses a topic can read it. Pairing is done by
scanning a QR code in onboarding. A custom server URL and optional auth token are
exposed for users who self-host.

**Privacy.** Webcam images and location leaving the device to a third party makes
a privacy policy legally mandatory (GDPR, and App Review requires one regardless),
and ntfy.sh must be named in it as a processor. Onboarding discloses this
explicitly at the point of enabling alerts.

## 7. Implementation notes

- **Sleep prevention.** While armed, hold `IOPMAssertionCreateWithName` with
  `PreventUserIdleSystemSleep` and `PreventSystemSleep`. Whether these defeat
  clamshell sleep on current macOS is **unproven and must be established first**
  (see Phase 0). The lid angle sensor mitigates the risk regardless, since the
  siren starts while the lid is still degrees from shut.
- **Forced audio.** Save prior audio state, then: switch default output to the
  built-in speakers (defeats plugged-in headphones), unmute
  (`kAudioDevicePropertyMute`), set `kAudioDevicePropertyVolumeScalar` to 1.0,
  play a looping siren. Restore saved state on disarm.
- **Screen lock (direct only).** `dlopen` login.framework, `dlsym`
  `SACLockScreenImmediate`. Guarded behind `isAvailable`; the symbol's absence
  degrades gracefully rather than crashing.
- **Login item.** `SMAppService.mainApp.register()`, both builds.
- **Evidence storage.** Snapshots written to Application Support with timestamps,
  retained locally regardless of whether transport succeeds.

## 8. Testing strategy

`AlarmCore` has no UI and injectable clock, frame source, and transport, so the
substance is unit-testable without a physical theft.

- **EgoMotionDetector** against synthetic frame pairs, the highest-value tests in
  the project: (a) a synthetically translated image must score high; (b) a static
  background with a moving blob must score near zero; (c) a global brightness
  change must score near zero; (d) translation plus a moving blob must still fire.
- **State machine** transitions, grace expiry, disarm, re-arm.
- **Triggers and responses** via fakes; capability gating verified by asserting
  the MAS composition excludes lock, lid, and Bluetooth.
- **Transport** against a stubbed server, including retry and offline queueing.
- **Manual, on-device:** clamshell survival, forced volume over headphones, TCC
  permission flows, real cafe calibration.

## 9. Phasing

- **Phase 0 — Feasibility spike (blocking).** Prove clamshell sleep survival, lid
  angle sensor reads, and the private lock symbol. A negative clamshell result
  changes the design, so nothing else starts first.
- **Phase 1 — Minimum viable alarm.** Engine, state machine, power trigger, siren
  with forced volume, disarm. Useful on its own.
- **Phase 2 — Ego-motion.** Detector, synthetic-frame test suite, live Test window.
- **Phase 3 — Remaining triggers.** Lid angle, Wi-Fi trusted networks.
- **Phase 4 — Evidence and alerting.** Snapshot, location, `AlertTransport`,
  `NtfyTransport`, QR pairing.
- **Phase 5 — Dual distribution.** MAS target, entitlements, capability-gating
  verification, sandbox testing.
- **Phase 6 — Commercial.** Onboarding, licensing, notarization, privacy policy,
  store assets.

## 10. Commercial prerequisites

- **Apple Developer Program** (EUR 99/yr) required for both `Developer ID
  Application` and `Apple Distribution` certificates. Enrollment can take days and
  blocks shipping, not building — start immediately.
- **EU VAT** applies from the first consumer sale. Paddle or Lemon Squeezy as
  merchant of record handles it for direct sales; Apple handles it for MAS.
- **Licensing** for the direct build: license key activation validated once and
  cached in the Keychain, with an offline grace period.
- **Privacy policy** naming ntfy.sh as a processor. Mandatory for both channels.

## 11. Open questions

- Does the power assertion actually survive clamshell close? Resolved by Phase 0.
- Is Bluetooth paired-device disconnect worth shipping at all, given it measures
  connection state rather than distance? Deferred to P2 pending Phase 0 findings.
