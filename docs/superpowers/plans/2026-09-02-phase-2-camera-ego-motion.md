# Phase 2: Camera Ego-Motion Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second trigger that fires when the laptop itself is moved, while ignoring people walking past it.

**Architecture:** A pure `EgoMotionDetector` scores consecutive grayscale frames using Vision's translational image registration plus a residual check, behind an injectable `FrameSource` so the whole thing is testable on synthetic images with no camera. A `MotionTrigger` adapts it to the existing `Trigger` protocol, so the engine, capability gating and settings pick it up unchanged.

**Tech Stack:** Swift 6.2, Vision (`VNTranslationalImageRegistrationRequest`), AVFoundation (`AVCaptureSession`), CoreGraphics, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-laptop-alarm-design.md` — section 3 is the algorithm this implements.

## Global Constraints

- **Swift tools version `6.2`**; the whole package is main-actor isolated by default via `.defaultIsolation(MainActor.self)` on every target.
- **`@Sendable`, `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` are ALL banned.** If something appears to need one, stop and report — `isolated deinit` (SE-0371) is the established tool where isolation is awkward. Working examples: `PowerSourceMonitor.swift`, `SirenPlayer.swift`.
- **Zero third-party dependencies.** System frameworks only.
- **Every `Trigger` and `Response` implements `isAvailable` and `isEnabled`.** They combine in exactly one place — `Capability.isActive` — which every call site uses. Never reimplement the pair.
- **Test doubles live behind `#if DEBUG`** so they do not ship in the Release binary.
- **Bundle identifier `com.jernejkocica.laptopalarm`** must keep matching `KeychainPasscodeStore`'s default service string.
- **One path for any given piece of logic.** Four separate bugs on this project came from logic duplicated in two places where the copy dropped what made it correct. Call the existing implementation.
- **Tests must be non-vacuous.** This project has shipped three tests that passed with the logic under test deleted. For any test pinning a behaviour, verify by mutation: break the code, watch the test fail, restore it.

## Verified facts — do not re-derive

Probed against the real Vision framework on macOS 26.5 before this plan was written:

| Scenario (320x240 synthetic, non-periodic texture) | `\|shift\|` | `explained` | `score` |
|---|---|---|---|
| Camera moved 12 px | 12.00 | 1.000 | **+0.0375** |
| Camera moved 3 px | 3.00 | 1.000 | **+0.0094** |
| Person walks past (background static) | 170.29 | **-0.303** | **-0.1615** |
| Global lighting change | 0.00 | 0.000 | 0.0000 |
| Identical frames | 0.00 | 1.000 | 0.0000 |

Three consequences that are easy to get wrong:

1. **Registration alone does NOT reject a passerby.** It returns a large spurious translation (170 px here). The `explained` term is the entire discriminator, not the shift.
2. **The residual's sign convention is undocumented.** Applying the transform the wrong way makes `residualWarped` larger than `residualRaw` and drives `explained` negative for *genuine* motion — inverting the detector. Compute the residual for both sign conventions and keep the smaller; this makes the measure independent of Vision's convention.
3. **Scores are small.** A clearly-moved laptop scores ~0.04, not ~0.5. Thresholds live around 0.005–0.02.

Registration is also ambiguous on periodic patterns (a repeating grid matches at many offsets). Real scenes are not periodic; synthetic test fixtures must not be either.

---

### Task 1: Bundle prerequisites for camera access

Blocking. Without both changes the camera either crashes the app or re-prompts on every rebuild.

**Files:**
- Modify: `Scripts/make-bundle.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a bundle that can request camera access and keep the grant across rebuilds.

- [ ] **Step 1: Add the usage description**

macOS terminates an app that touches the camera with no `NSCameraUsageDescription`. It is not a warning; the process dies. Add to the `Info.plist` heredoc in `Scripts/make-bundle.sh`, beside the existing keys:

```xml
    <key>NSCameraUsageDescription</key>
    <string>LaptopAlarm watches for the laptop being picked up. Video never leaves your Mac and is never recorded.</string>
```

The wording matters commercially: this string is shown verbatim in the permission dialog and, for a theft app asking for camera access, is the whole of the user's decision.

- [ ] **Step 2: Sign with a stable identity**

TCC ties a permission grant to the code signature. An ad-hoc signature (`--sign -`) differs on every build, so the grant is lost each rebuild and the user is re-prompted forever.

Replace the signing line:

```bash
# TCC ties the camera grant to the signing identity. Ad-hoc signatures change
# every build, so the grant would be lost each time; a stable identity keeps it.
IDENTITY="${LAPTOPALARM_SIGN_IDENTITY:-Apple Development: Jernej Jan Kocica (U2C2MA4YJZ)}"
if security find-identity -v -p codesigning | grep -qF "${IDENTITY}"; then
    codesign --force --options runtime --sign "${IDENTITY}" "${APP_DIR}"
else
    echo "warning: '${IDENTITY}' not found; falling back to ad-hoc." >&2
    echo "         The camera permission will be re-requested on every build." >&2
    codesign --force --sign - "${APP_DIR}"
fi
```

- [ ] **Step 3: Verify the bundle**

```bash
./Scripts/make-bundle.sh
codesign -dv build/LaptopAlarm.app 2>&1 | grep -E "Authority|Signature"
plutil -p build/LaptopAlarm.app/Contents/Info.plist | grep NSCamera
```
Expected: an `Authority=Apple Development: ...` line (not `adhoc`), and the camera usage string.

- [ ] **Step 4: Commit**

```bash
git add Scripts/make-bundle.sh
git commit -m "build: stable signing identity and camera usage description"
```

---

### Task 2: The ego-motion detector

The heart of Phase 2, and pure: frames in, score out, no camera, no timers.

**Files:**
- Create: `Sources/AlarmCore/Vision/EgoMotionDetector.swift`
- Create: `Sources/AlarmCore/Vision/GrayscaleFrame.swift`
- Create: `Tests/AlarmCoreTests/Support/SyntheticFrames.swift`
- Test: `Tests/AlarmCoreTests/EgoMotionDetectorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `GrayscaleFrame` (`width`, `height`, `pixels: [UInt8]`, `init(width:height:pixels:)`, `cgImage: CGImage?`); `MotionScore` (`shift: Double`, `explained: Double`, `value: Double`); `EgoMotionDetector(threshold:consecutiveFramesRequired:)` with `func score(previous:current:) -> MotionScore?`, `func submit(_ frame: GrayscaleFrame) -> Bool`, `var lastScore: MotionScore?`, `func reset()`. Task 4 drives `submit`; Task 5 reads `lastScore`.

- [ ] **Step 1: Write the synthetic frame helper**

Test fixtures must not be periodic — registration is ambiguous on repeating patterns.

```swift
// Tests/AlarmCoreTests/Support/SyntheticFrames.swift
import Foundation
import CoreGraphics
@testable import AlarmCore

/// Deterministic, non-periodic test scenes. Periodic patterns (a repeating
/// grid) make translational registration ambiguous and would make these tests
/// meaningless.
enum SyntheticFrames {
    struct Blob { let x: CGFloat, y: CGFloat, size: CGFloat, gray: CGFloat }

    static let width = 320
    static let height = 240

    static func blobs(seed: UInt64 = 42, count: Int = 120) -> [Blob] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 10_000) / 10_000
        }
        return (0..<count).map { _ in
            Blob(x: CGFloat(next() * 320), y: CGFloat(next() * 240),
                 size: CGFloat(6 + next() * 22), gray: CGFloat(0.2 + next() * 0.7))
        }
    }

    /// `dx`/`dy` move the whole scene (the camera moved).
    /// `occluderAt` moves a foreground bar only (a person walked past).
    /// `brightness` shifts every pixel (the lighting changed).
    static func scene(dx: CGFloat = 0, dy: CGFloat = 0,
                      occluderAt: CGFloat? = nil, brightness: CGFloat = 0,
                      blobs: [Blob] = SyntheticFrames.blobs()) -> GrayscaleFrame {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: max(0, min(1, 0.2 + brightness)), alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for blob in blobs {
                ctx.setFillColor(gray: max(0, min(1, blob.gray + brightness)), alpha: 1)
                ctx.fill(CGRect(x: blob.x + dx, y: blob.y + dy, width: blob.size, height: blob.size))
            }
            if let ox = occluderAt {
                ctx.setFillColor(gray: 0.5, alpha: 1)
                ctx.fill(CGRect(x: ox, y: 0, width: 70, height: CGFloat(height)))
            }
        }
        return GrayscaleFrame(width: width, height: height, pixels: pixels)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/AlarmCoreTests/EgoMotionDetectorTests.swift
import Testing
import Foundation
@testable import AlarmCore

private let detector = { EgoMotionDetector() }

// Verified against the real Vision framework: a genuinely moved camera yields a
// warp that explains almost the whole frame.
@Test func aMovedCameraScoresPositive() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(),
                                      current: SyntheticFrames.scene(dx: 12)))
    #expect((score?.value ?? 0) > 0.01)
    #expect((score?.explained ?? 0) > 0.8)
}

// THE test. Registration returns a large spurious shift for a passerby (~170px
// measured); only the residual check rejects it. If this passes while
// `explained` is removed from the score, the detector is useless in a cafe.
@Test func aPersonWalkingPastScoresBelowZero() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(occluderAt: 40),
                                      current: SyntheticFrames.scene(occluderAt: 150)))
    #expect((score?.value ?? 1) <= 0)
    #expect((score?.shift ?? 0) > 20, "expected a large spurious shift; if this is small the fixture is not exercising the real failure mode")
}

@Test func aGlobalLightingChangeScoresZero() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(),
                                      current: SyntheticFrames.scene(brightness: 0.18)))
    #expect(abs(score?.value ?? 1) < 0.001)
}

@Test func identicalFramesScoreZero() {
    let d = detector()
    let frame = SyntheticFrames.scene()
    let score = try? #require(d.score(previous: frame, current: frame))
    #expect(abs(score?.value ?? 1) < 0.001)
}

// A small real movement must still register: someone nudging the laptop.
@Test func aSmallCameraMovementStillScoresPositive() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(),
                                      current: SyntheticFrames.scene(dx: 3)))
    #expect((score?.value ?? 0) > 0)
}

// Single-frame noise must not fire the alarm; K consecutive frames must.
@Test func oneMovedFrameDoesNotFire() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    #expect(d.submit(SyntheticFrames.scene()) == false)
    #expect(d.submit(SyntheticFrames.scene(dx: 12)) == false)
}

@Test func threeConsecutiveMovedFramesFire() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    _ = d.submit(SyntheticFrames.scene())
    #expect(d.submit(SyntheticFrames.scene(dx: 12)) == false)
    #expect(d.submit(SyntheticFrames.scene(dx: 24)) == false)
    #expect(d.submit(SyntheticFrames.scene(dx: 36)) == true)
}

// A quiet frame between moves resets the run, or noise would accumulate into
// a false alarm over minutes.
@Test func aQuietFrameResetsTheConsecutiveRun() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    _ = d.submit(SyntheticFrames.scene())
    _ = d.submit(SyntheticFrames.scene(dx: 12))
    _ = d.submit(SyntheticFrames.scene(dx: 12))   // no further movement
    _ = d.submit(SyntheticFrames.scene(dx: 24))
    #expect(d.submit(SyntheticFrames.scene(dx: 36)) == false)
}

@Test func peopleWalkingPastNeverFireHoweverManyFrames() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    var fired = false
    for x in stride(from: CGFloat(0), to: 250, by: 25) {
        if d.submit(SyntheticFrames.scene(occluderAt: x)) { fired = true }
    }
    #expect(fired == false)
}

@Test func resetClearsTheRunAndTheLastScore() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 2)
    _ = d.submit(SyntheticFrames.scene())
    _ = d.submit(SyntheticFrames.scene(dx: 12))
    d.reset()
    #expect(d.lastScore == nil)
    #expect(d.submit(SyntheticFrames.scene(dx: 24)) == false)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter EgoMotionDetectorTests`
Expected: FAIL — `cannot find 'EgoMotionDetector' in scope`.

- [ ] **Step 4: Write the frame type**

```swift
// Sources/AlarmCore/Vision/GrayscaleFrame.swift
import Foundation
import CoreGraphics

/// One 8-bit grayscale frame. Downscaled before it reaches here: registration
/// at 320x240 is cheap enough to run at 5 fps without a measurable battery cost.
///
/// Explicitly `nonisolated`: frames are built on the camera's capture queue,
/// not the main actor. The package is main-actor isolated by default, which
/// would otherwise make this initialiser unreachable from the capture callback.
nonisolated public struct GrayscaleFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var cgImage: CGImage? {
        guard pixels.count == width * height else { return nil }
        var data = pixels
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}
```

- [ ] **Step 5: Write the detector**

```swift
// Sources/AlarmCore/Vision/EgoMotionDetector.swift
import Foundation
import Vision
import CoreGraphics

/// One frame pair's verdict.
public struct MotionScore: Equatable, Sendable {
    /// Global displacement in pixels, as reported by registration.
    public let shift: Double
    /// How much of the frame-to-frame change the global warp explains.
    /// ~1 when the camera moved; <= 0 when something moved *within* a still frame.
    public let explained: Double
    /// `normalisedShift * explained`. Positive only for genuine camera motion.
    public let value: Double
}

/// Distinguishes *the camera moving* from *the world moving in front of it*.
///
/// Naive frame differencing is unusable where this app is meant to be used: in
/// a cafe, people walk past constantly. The discriminator is whether a single
/// global transform explains the change between frames.
///
/// Registration alone is NOT enough — measured against the real Vision
/// framework, a person walking past a static background produces a spurious
/// shift of ~170 px. What rejects it is that warping by that transform makes
/// the image *worse*, driving `explained` negative.
public final class EgoMotionDetector {
    public let threshold: Double
    public let consecutiveFramesRequired: Int

    public private(set) var lastScore: MotionScore?
    private var previous: GrayscaleFrame?
    private var consecutiveHits = 0

    /// Defaults come from measurement, not taste: a clearly-moved laptop scores
    /// about 0.04, so the threshold belongs near 0.005, and three frames at
    /// 5 fps is ~600 ms — long enough to reject a single noisy frame, short
    /// enough that the alarm is not late.
    public init(threshold: Double = 0.005, consecutiveFramesRequired: Int = 3) {
        self.threshold = threshold
        self.consecutiveFramesRequired = max(1, consecutiveFramesRequired)
    }

    public func reset() {
        previous = nil
        consecutiveHits = 0
        lastScore = nil
    }

    /// Feeds one frame. Returns true when movement has been sustained for
    /// `consecutiveFramesRequired` frames.
    public func submit(_ frame: GrayscaleFrame) -> Bool {
        defer { previous = frame }
        guard let previous else { return false }
        guard let score = score(previous: previous, current: frame) else { return false }
        lastScore = score
        consecutiveHits = score.value > threshold ? consecutiveHits + 1 : 0
        return consecutiveHits >= consecutiveFramesRequired
    }

    public func score(previous: GrayscaleFrame, current: GrayscaleFrame) -> MotionScore? {
        guard previous.width == current.width, previous.height == current.height,
              let previousImage = previous.cgImage, let currentImage = current.cgImage
        else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currentImage,
                                                              options: [:])
        let handler = VNImageRequestHandler(cgImage: previousImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return nil }

        let transform = observation.alignmentTransform
        let dx = Double(transform.tx), dy = Double(transform.ty)
        let shift = (dx * dx + dy * dy).squareRoot()

        let width = previous.width, height = previous.height
        let residualRaw = Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                                      width: width, height: height, dx: 0, dy: 0)
        // Vision's transform direction is undocumented, and applying it the
        // wrong way inverts the detector — `explained` goes negative for
        // genuine motion. Measuring both conventions and keeping the better
        // alignment makes this independent of which way round it is.
        let ix = Int(dx.rounded()), iy = Int(dy.rounded())
        let residualWarped = min(
            Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                        width: width, height: height, dx: ix, dy: iy),
            Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                        width: width, height: height, dx: -ix, dy: -iy))

        let explained = 1 - residualWarped / max(residualRaw, 0.001)
        let value = (shift / Double(width)) * explained
        return MotionScore(shift: shift, explained: explained, value: value)
    }

    /// Mean |a - b| over the region where `a` shifted by (dx, dy) overlaps `b`.
    static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8],
                                       width: Int, height: Int, dx: Int, dy: Int) -> Double {
        var total = 0.0
        var counted = 0
        for y in 0..<height {
            let sy = y + dy
            if sy < 0 || sy >= height { continue }
            for x in 0..<width {
                let sx = x + dx
                if sx < 0 || sx >= width { continue }
                total += abs(Double(a[sy * width + sx]) - Double(b[y * width + x]))
                counted += 1
            }
        }
        return counted > 0 ? total / Double(counted) : 255
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter EgoMotionDetectorTests`
Expected: PASS, 10 tests.

- [ ] **Step 7: Prove the passerby test is not vacuous**

This is the test the whole feature rests on. Verify it fails when the discriminator is removed:

```bash
# Temporarily neuter `explained`, then restore.
sed -i '' 's|let value = (shift / Double(width)) \* explained|let value = (shift / Double(width))  // MUTATION|' Sources/AlarmCore/Vision/EgoMotionDetector.swift
swift test --filter aPersonWalkingPastScoresBelowZero
```
Expected: FAIL. Then restore the line and re-run; expected PASS. Record both outputs in your report.

- [ ] **Step 8: Commit**

```bash
git add Sources/AlarmCore/Vision Tests/AlarmCoreTests/EgoMotionDetectorTests.swift Tests/AlarmCoreTests/Support
git commit -m "feat: ego-motion detector that ignores passers-by"
```

---

### Task 3: Camera frame source

**Files:**
- Create: `Sources/AlarmCore/Vision/FrameSource.swift`
- Test: `Tests/AlarmCoreTests/FrameSourceTests.swift`

**Interfaces:**
- Consumes: `GrayscaleFrame` (Task 2).
- Produces: `FrameSourcing` (`isAvailable: Bool`, `start(onFrame:) throws`, `stop()`); `CameraFrameSource(framesPerSecond:)`; `FakeFrameSource` (`emit(_:)`, `isRunning`, `startCallCount`); `FrameSourceError.cameraUnavailable`, `.accessDenied`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/FrameSourceTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func aFakeSourceDeliversFramesToItsHandler() throws {
    let source = FakeFrameSource()
    var received: [GrayscaleFrame] = []
    try source.start { received.append($0) }
    source.emit(SyntheticFrames.scene())
    source.emit(SyntheticFrames.scene(dx: 5))
    #expect(received.count == 2)
}

@Test func stoppingHaltsDelivery() throws {
    let source = FakeFrameSource()
    var count = 0
    try source.start { _ in count += 1 }
    source.stop()
    source.emit(SyntheticFrames.scene())
    #expect(count == 0)
    #expect(source.isRunning == false)
}

// Restarting must not stack handlers: two live handlers would double every
// frame and halve the effective consecutive-frame threshold.
@Test func restartingReplacesTheHandlerRatherThanAddingOne() throws {
    let source = FakeFrameSource()
    var first = 0, second = 0
    try source.start { _ in first += 1 }
    try source.start { _ in second += 1 }
    source.emit(SyntheticFrames.scene())
    #expect(first == 0)
    #expect(second == 1)
}

@Test func anUnavailableSourceThrowsOnStart() {
    let source = FakeFrameSource(isAvailable: false)
    #expect(throws: FrameSourceError.self) { try source.start { _ in } }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FrameSourceTests`
Expected: FAIL — `cannot find 'FakeFrameSource' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Vision/FrameSource.swift
import Foundation
import AVFoundation
import CoreVideo

public enum FrameSourceError: Error, Equatable {
    case cameraUnavailable
    case accessDenied
}

public protocol FrameSourcing: AnyObject {
    var isAvailable: Bool { get }
    /// Replaces any existing handler. Restarting must never stack handlers.
    func start(onFrame: @escaping (GrayscaleFrame) -> Void) throws
    func stop()
}

/// Captures from the built-in camera, downscaling to the detector's working
/// size. The green camera light stays on for as long as this runs; that is
/// hardware-enforced and cannot be suppressed, which is why motion detection is
/// opt-in rather than on by default.
public final class CameraFrameSource: NSObject, FrameSourcing,
                                      AVCaptureVideoDataOutputSampleBufferDelegate {
    public let targetWidth = 320
    public let targetHeight = 240

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.jernejkocica.laptopalarm.frames")
    private var onFrame: ((GrayscaleFrame) -> Void)?
    private var lastDelivery = Date.distantPast
    private let minimumInterval: TimeInterval

    public init(framesPerSecond: Double = 5) {
        self.minimumInterval = 1.0 / max(1, framesPerSecond)
        super.init()
    }

    public var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
            && AVCaptureDevice.authorizationStatus(for: .video) != .denied
            && AVCaptureDevice.authorizationStatus(for: .video) != .restricted
    }

    public func start(onFrame: @escaping (GrayscaleFrame) -> Void) throws {
        stop()
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw FrameSourceError.cameraUnavailable
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            throw FrameSourceError.accessDenied
        }
        self.onFrame = onFrame

        session.beginConfiguration()
        session.sessionPreset = .low
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            throw FrameSourceError.cameraUnavailable
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
    }

    public func stop() {
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        onFrame = nil
    }

    isolated deinit { stop() }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Throttle here rather than asking the device for a low frame rate:
        // registration is the cost, not capture, and this keeps the pacing in
        // one place regardless of what the hardware offers.
        let now = Date()
        guard now.timeIntervalSince(lastDelivery) >= minimumInterval else { return }
        lastDelivery = now
        guard let frame = Self.grayscaleFrame(from: sampleBuffer,
                                              width: targetWidth, height: targetHeight)
        else { return }
        // The capture queue is not the main actor; hop before touching the
        // handler, which owns main-actor state.
        Task { @MainActor [weak self] in self?.onFrame?(frame) }
    }

    /// Downscales and converts BGRA to 8-bit grayscale.
    nonisolated static func grayscaleFrame(from sampleBuffer: CMSampleBuffer,
                                           width: Int, height: Int) -> GrayscaleFrame? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let source = base.assumingMemoryBound(to: UInt8.self)

        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = y * sourceHeight / height
            for x in 0..<width {
                let sx = x * sourceWidth / width
                let offset = sy * bytesPerRow + sx * 4
                let b = Int(source[offset]), g = Int(source[offset + 1]), r = Int(source[offset + 2])
                pixels[y * width + x] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
            }
        }
        return GrayscaleFrame(width: width, height: height, pixels: pixels)
    }
}

#if DEBUG
public final class FakeFrameSource: FrameSourcing {
    public let isAvailable: Bool
    public private(set) var isRunning = false
    public private(set) var startCallCount = 0
    private var onFrame: ((GrayscaleFrame) -> Void)?

    public init(isAvailable: Bool = true) { self.isAvailable = isAvailable }

    public func start(onFrame: @escaping (GrayscaleFrame) -> Void) throws {
        guard isAvailable else { throw FrameSourceError.cameraUnavailable }
        startCallCount += 1
        self.onFrame = onFrame
        isRunning = true
    }

    public func stop() {
        isRunning = false
        onFrame = nil
    }

    public func emit(_ frame: GrayscaleFrame) { onFrame?(frame) }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FrameSourceTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Vision/FrameSource.swift Tests/AlarmCoreTests/FrameSourceTests.swift
git commit -m "feat: throttled camera frame source behind a protocol"
```

---

### Task 4: The motion trigger

**Files:**
- Create: `Sources/AlarmCore/Triggers/MotionTrigger.swift`
- Test: `Tests/AlarmCoreTests/MotionTriggerTests.swift`

**Interfaces:**
- Consumes: `Trigger`, `TriggerID` (existing); `EgoMotionDetector` (Task 2); `FrameSourcing`, `FakeFrameSource` (Task 3).
- Produces: `MotionTrigger(source:detector:graceSeconds:)` with `id == TriggerID("motion")`, conforming to `Trigger`. Task 5 reads `detector.lastScore`; Task 6 shows it in settings.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AlarmCoreTests/MotionTriggerTests.swift
import Testing
import Foundation
@testable import AlarmCore

private func makeTrigger(_ source: FakeFrameSource,
                         required: Int = 3) -> MotionTrigger {
    MotionTrigger(source: source,
                  detector: EgoMotionDetector(threshold: 0.005,
                                              consecutiveFramesRequired: required),
                  graceSeconds: 0)
}

@Test func sustainedCameraMotionFiresTheTrigger() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for dx in stride(from: CGFloat(0), through: 48, by: 12) {
        source.emit(SyntheticFrames.scene(dx: dx))
    }
    #expect(fired == TriggerID("motion"))
}

@Test func peopleWalkingPastNeverFireTheTrigger() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for x in stride(from: CGFloat(0), to: 250, by: 25) {
        source.emit(SyntheticFrames.scene(occluderAt: x))
    }
    #expect(fired == nil)
}

@Test func stoppingHaltsTheSourceAndPreventsFiring() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    trigger.stop()
    #expect(source.isRunning == false)
    for dx in stride(from: CGFloat(0), through: 48, by: 12) {
        source.emit(SyntheticFrames.scene(dx: dx))
    }
    #expect(fired == nil)
}

// Re-arming must start from a clean slate: leftover frames from the previous
// session would let a single new frame complete an old run.
@Test func restartingResetsTheDetector() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fireCount = 0
    try trigger.start { _ in fireCount += 1 }
    source.emit(SyntheticFrames.scene())
    source.emit(SyntheticFrames.scene(dx: 12))
    trigger.stop()
    try trigger.start { _ in fireCount += 1 }
    source.emit(SyntheticFrames.scene(dx: 24))
    #expect(fireCount == 0)
}

@Test func theTriggerIsUnavailableWhenTheCameraIs() {
    let trigger = makeTrigger(FakeFrameSource(isAvailable: false))
    #expect(trigger.isAvailable == false)
}

// Motion can always fire: unlike the charger, it needs no prior state.
@Test func theTriggerCanAlwaysFireNow() {
    #expect(makeTrigger(FakeFrameSource()).canFireNow == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MotionTriggerTests`
Expected: FAIL — `cannot find 'MotionTrigger' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AlarmCore/Triggers/MotionTrigger.swift
import Foundation

/// Fires when the laptop itself is moved, ignoring movement in front of it.
///
/// The camera light is on for as long as this is armed — hardware-enforced and
/// impossible to hide — so this trigger is off by default and the user opts in.
public final class MotionTrigger: Trigger {
    public let id = TriggerID("motion")
    public var identifier: String { id.rawValue }
    public var isEnabled = true
    public var graceSeconds: TimeInterval

    /// Exposed so the calibration window can show the live score: thresholds
    /// correct at a kitchen table are wrong in a dim cafe, so the user has to
    /// be able to watch the number at the table they actually sit at.
    public let detector: EgoMotionDetector

    private let source: FrameSourcing
    private var onFire: ((TriggerID) -> Void)?

    public init(source: FrameSourcing, detector: EgoMotionDetector,
                graceSeconds: TimeInterval) {
        self.source = source
        self.detector = detector
        self.graceSeconds = graceSeconds
    }

    public var isAvailable: Bool { source.isAvailable }

    /// Motion needs no prior state to detect, unlike the charger trigger, which
    /// needs an AC-to-battery edge that does not exist if already on battery.
    public var canFireNow: Bool { true }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        // Clean slate: frames from a previous session must not let a single new
        // frame complete an old consecutive run.
        detector.reset()
        try source.start { [weak self] frame in
            guard let self else { return }
            if self.detector.submit(frame) {
                self.onFire?(self.id)
            }
        }
    }

    public func stop() {
        source.stop()
        detector.reset()
        onFire = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MotionTriggerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AlarmCore/Triggers/MotionTrigger.swift Tests/AlarmCoreTests/MotionTriggerTests.swift
git commit -m "feat: motion trigger driven by ego-motion detection"
```

---

### Task 5: Wire motion into the app, with trigger checkboxes and a calibration readout

With a second trigger, the trigger section stops being pointless and appears.

**Files:**
- Modify: `Sources/LaptopAlarm/AppModel.swift`
- Modify: `Sources/LaptopAlarm/SettingsSection.swift`
- Modify: `Sources/AlarmCore/Triggers/MotionTrigger.swift` (adds the calibration pair)
- Modify: `Sources/AlarmCore/Settings/Preferences.swift` (adds the defaulted `isEnabled` overload)

**Interfaces:**
- Consumes: `MotionTrigger`, `CameraFrameSource`, `EgoMotionDetector` (Tasks 2-4); existing `AlarmEngine`, `PreferenceStoring`, `Capability.isActive`.
- Produces: `AppModel.motionEnabled`, `.motionAvailable`, `.setMotionEnabled(_:)`, `.liveMotionScore`, `.startCalibration()`, `.stopCalibration()`, `.isCalibrating`.

- [ ] **Step 1: Construct the trigger and expose its settings**

In `AppModel.init`, after the existing `PowerTrigger`:

```swift
        let motion = MotionTrigger(source: CameraFrameSource(framesPerSecond: 5),
                                   detector: EgoMotionDetector(),
                                   graceSeconds: preferences.graceSeconds)
        self.motionTrigger = motion
```

Add it to the engine's trigger array (`triggers: [trigger, motion]`), store `private let motionTrigger: MotionTrigger`, and add published mirrors beside the response ones:

```swift
    @Published private(set) var motionEnabled = false
    @Published private(set) var liveMotionScore: Double?
    @Published private(set) var isCalibrating = false
```

Apply the stored preference at the end of `init`, matching how the responses are applied — but **default motion to off**:

```swift
        // Motion is the one feature that is off unless asked for: it holds the
        // camera open, and the green light is hardware-enforced. Everything
        // else defaults on; this one requires a decision.
        motion.isEnabled = motion.isAvailable && preferences.isEnabled(motion.identifier, default: false)
        motionEnabled = motion.isActive
```

This requires a defaulted overload on the preference store — add to `PreferenceStoring` and both implementations:

```swift
    func isEnabled(_ identifier: String, default defaultValue: Bool) -> Bool
```

with `UserDefaultsPreferences` reading `defaults.object(forKey:) as? Bool ?? defaultValue`, `InMemoryPreferences` reading `enabled[identifier] ?? defaultValue`, and the existing single-argument form implemented once in a protocol extension as `isEnabled(identifier, default: true)` so the two forms cannot drift.

- [ ] **Step 2: Add the setter and the calibration controls**

```swift
    var motionAvailable: Bool { motionTrigger.isAvailable }

    func setMotionEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        let applied = enabled && motionTrigger.isAvailable
        motionTrigger.isEnabled = applied
        preferences.setEnabled(applied, for: motionTrigger.identifier)
        motionEnabled = motionTrigger.isActive
    }

    /// Live score readout. Sensitivity cannot be tuned in the abstract: the
    /// user has to watch the number while nudging the laptop at the table they
    /// actually use. Only runs while the settings pane asks for it, so the
    /// camera light is never on unexplained.
    func startCalibration() {
        guard !settingsLocked, motionTrigger.isAvailable, !isCalibrating else { return }
        do {
            try motionTrigger.startCalibration { [weak self] score in
                self?.liveMotionScore = score.value
            }
            isCalibrating = true
        } catch {
            settingsMessage = "Could not open the camera. Grant access in System Settings ▸ Privacy & Security ▸ Camera."
        }
    }

    func stopCalibration() {
        motionTrigger.stopCalibration()
        isCalibrating = false
        liveMotionScore = nil
    }
```

Add the matching pair to `MotionTrigger`, reusing its own start/stop rather than duplicating the wiring:

```swift
    /// Runs the detector without arming the alarm, for the calibration readout.
    public func startCalibration(onScore: @escaping (MotionScore) -> Void) throws {
        detector.reset()
        try source.start { [weak self] frame in
            guard let self else { return }
            _ = self.detector.submit(frame)
            if let score = self.detector.lastScore { onScore(score) }
        }
    }

    public func stopCalibration() {
        source.stop()
        detector.reset()
    }
```

- [ ] **Step 3: Add the UI**

In `SettingsSection.swift`, above the "When the alarm fires" group:

```swift
                if model.motionAvailable {
                    Text("What triggers the alarm").font(.caption).foregroundStyle(.secondary)
                    Text("Charger unplugged").font(.caption2).foregroundStyle(.secondary)
                    Toggle("Laptop is moved (uses the camera)", isOn: Binding(
                        get: { model.motionEnabled },
                        set: { model.setMotionEnabled($0) }))
                    Text("The camera light stays on while armed. Video never leaves your Mac.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if model.motionEnabled {
                        HStack {
                            Button(model.isCalibrating ? "Stop test" : "Test sensitivity") {
                                model.isCalibrating ? model.stopCalibration() : model.startCalibration()
                            }
                            if let score = model.liveMotionScore {
                                Text(String(format: "%.4f", score))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(score > 0.005 ? Color.red : Color.secondary)
                            }
                        }
                        if model.isCalibrating {
                            Text("Nudge the laptop: the number should jump. Wave a hand in front: it should not.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
```

- [ ] **Step 4: Build and verify the suite still passes**

Run: `swift build && swift test`
Expected: clean build, no warnings, all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LaptopAlarm
git commit -m "feat: motion trigger settings with live sensitivity readout"
```

---

### Task 6: Manual verification

Automated tests cannot confirm the camera opens, the permission prompt appears, or that the detector behaves on real video. This task is manual and its output is a written record.

**Files:**
- Create: `docs/superpowers/specs/2026-09-02-phase2-acceptance.md`

- [ ] **Step 1: Run the suite and build the bundle**

```bash
swift test && ./Scripts/make-bundle.sh && open build/LaptopAlarm.app
```

- [ ] **Step 2: Walk the scenarios**

Record PASS/FAIL with a note for each.

1. **Permission prompt** — enable "Laptop is moved". macOS asks for camera access, quoting the usage string. Grant it.
2. **Grant persists** — quit, run `./Scripts/make-bundle.sh` again, relaunch, enable motion. **No second prompt.** A prompt here means the signing identity is not stable.
3. **Camera light** — the green light comes on when armed with motion enabled, and goes off on disarm.
4. **Live score, still** — click "Test sensitivity" and leave the laptop alone. The number stays near zero.
5. **Live score, moved** — nudge the laptop a centimetre. The number jumps above 0.005.
6. **Live score, hand waved** — wave a hand across the camera without touching the laptop. **The number must stay near zero.** This is the whole feature; a failure here means it is unusable in a cafe.
7. **Live score, someone walks past** — best tested somewhere with foot traffic. Number stays near zero.
8. **Real alarm** — arm with motion on, charger plugged in, then pick the laptop up. Siren fires.
9. **No false alarm at rest** — arm with motion on and leave it untouched for ten minutes. It must not fire.
10. **Motion off means camera off** — disable motion, arm. The camera light must NOT come on.

- [ ] **Step 3: Record and commit**

Write the results, with the observed score values from scenarios 4-7 — those numbers are the evidence for whether the default threshold of 0.005 is right for real cameras, which synthetic frames cannot tell us.

```bash
git add docs/superpowers/specs/2026-09-02-phase2-acceptance.md
git commit -m "docs: Phase 2 acceptance results"
```

- [ ] **Step 4: Tune if needed**

If scenario 6 or 7 produced scores above the threshold, the default is wrong for real sensor noise. Raise `EgoMotionDetector`'s default threshold to sit clearly above the observed noise floor and re-run 5 and 6. Record the change and its justification.

## Out of scope for this plan

Lid-angle and Wi-Fi triggers (Phase 3); snapshot, location and alert transport (Phase 4); the sandboxed App Store target (Phase 5); onboarding, licensing and notarisation (Phase 6). Corroboration between the lid sensor and camera — spec §3's combined high-confidence rule — needs the lid trigger and belongs with Phase 3.
