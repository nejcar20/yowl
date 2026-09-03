// Sources/AlarmCore/Vision/FrameSource.swift
import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import os

public enum FrameSourceError: Error, Equatable {
    case cameraUnavailable
    case accessDenied
}

public protocol FrameSourcing: AnyObject {
    /// Hardware capability, fixed for the process.
    var isAvailable: Bool { get }
    /// Whether capture is currently permitted. Changes when the user grants or
    /// revokes access, so it must never be folded into `isAvailable`.
    var isPermitted: Bool { get }
    /// Raises the capture rate while the user is watching a live readout.
    func setHighRate(_ high: Bool)
    /// Prompts for access if the user has not been asked yet. Returns whether
    /// capture is permitted. Called when the feature is switched on, so the
    /// answer is known before anything depends on it.
    func requestAccess() async -> Bool
    /// Replaces any existing handler. Restarting must never stack handlers.
    func start(onFrame: @escaping (GrayscaleFrame) -> Void) throws
    func stop()
}

/// Captures from the built-in camera, downscaling to the detector's working
/// size. The green camera light stays on for as long as this runs; that is
/// hardware-enforced and cannot be suppressed, which is why motion detection is
/// opt-in rather than on by default.
public final class CameraFrameSource: NSObject, FrameSourcing, StillCapturing,
                                      AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Read from the capture queue, so these must not be main-actor isolated.
    public nonisolated let targetWidth = 320
    public nonisolated let targetHeight = 240

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.jernejkocica.laptopalarm.frames")

    /// Everything the capture callback touches. The callback runs on the
    /// capture queue, never the main actor, so it cannot legally read
    /// main-actor state — an earlier version had no `nonisolated` on the
    /// callback at all, which made Swift 6 insert an isolation check that
    /// aborts the process on the first real frame. A lock rather than a
    /// suppression: this state genuinely is shared across threads, and saying
    /// so is the point.
    /// Resets only the per-session fields. Extracted so a test can reach it:
    /// assigning a whole fresh `CaptureState` here silently wiped
    /// `retainStills` through the memberwise init's defaults, and `start()`
    /// throws before this point without a camera, so nothing could catch it.
    nonisolated static func resetForNewSession(_ state: inout CaptureState) {
        state.lastDelivery = .distantPast
        state.isRunning = true
        state.buffer.removeAll()
        state.latestStill = nil
    }

    nonisolated struct CaptureState {
        var lastDelivery = Date.distantPast
        var isRunning = false
        /// Retained only while evidence capture is switched on. The video output
        /// already delivers full-resolution frames that get downscaled for
        /// motion, so keeping the last one costs one buffer and gives a photo
        /// from the exact moment the alarm fired — no second output, no second
        /// session, and nothing to warm up.
        var retainStills = false
        var latestStill: Data?
        /// The run-up: recent frames, oldest first, so the alarm can save the
        /// moments *before* it fired. Sampled at about 1 Hz rather than every
        /// frame — a photograph every 200 ms of the same approaching face is
        /// bandwidth without information.
        var buffer: [TimestampedStill] = []
        var lastBuffered = Date.distantPast
    }
    private let captureState = OSAllocatedUnfairLock(initialState: CaptureState())
    private nonisolated let minimumInterval: TimeInterval
    /// Raised while calibrating so the live number tracks the user's hand
    /// instead of lagging a fifth of a second behind it.
    private nonisolated let calibrationInterval: TimeInterval
    private let isCalibrationRate = OSAllocatedUnfairLock(initialState: false)
    /// Stays main-actor isolated: only the frame crosses threads, never this.
    private var onFrame: ((GrayscaleFrame) -> Void)?

    public init(framesPerSecond: Double = 5, calibrationFramesPerSecond: Double = 20) {
        self.minimumInterval = 1.0 / max(1, framesPerSecond)
        self.calibrationInterval = 1.0 / max(1, calibrationFramesPerSecond)
        super.init()
    }

    public func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Hardware only, sampled once. `Capability.isAvailable` is filtered by the
    /// engine at construction, so folding permission into it meant a Mac that
    /// launched with camera access denied dropped motion and photographs
    /// permanently — granting access afterwards could not bring them back
    /// without a relaunch, while the toggles happily reported themselves on.
    /// Permission is user configuration and is handled by `requestAccess` and
    /// `isEnabled`, both of which are re-read.
    public let isAvailable = AVCaptureDevice.default(for: .video) != nil

    /// Whether capture would be permitted right now. Distinct from availability.
    public var isPermitted: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized, .notDetermined: true
        default: false
        }
    }

    public func setHighRate(_ high: Bool) {
        isCalibrationRate.withLock { $0 = high }
    }

    /// How many seconds of run-up to keep. Ten seconds at 1 Hz is roughly
    /// 2-4 MB of JPEG and covers someone walking up to the machine.
    public nonisolated static let bufferedStillCount = 10
    private nonisolated static let bufferInterval: TimeInterval = 1

    /// Turning this on makes the source keep the most recent full-resolution
    /// frame, and a short history before it.
    public func setRetainsStills(_ retain: Bool) {
        captureState.withLock {
            $0.retainStills = retain
            if !retain {
                $0.latestStill = nil
                $0.buffer.removeAll()
            }
        }
    }

    public func bufferedStills() -> [TimestampedStill] {
        captureState.withLock { $0.buffer }
    }

    public func clearBufferedStills() {
        captureState.withLock { $0.buffer.removeAll() }
    }

    public func start(onFrame: @escaping (GrayscaleFrame) -> Void) throws {
        // Read before `stop()` clears anything, and before the session is
        // configured: the preset depends on it.
        let wantsStills = captureState.withLock { $0.retainStills }
        stop()
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw FrameSourceError.cameraUnavailable
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            throw FrameSourceError.accessDenied
        }
        self.onFrame = onFrame
        // Reset only the per-session fields. Assigning a fresh CaptureState
        // here silently wiped `retainStills` through the memberwise init's
        // defaults, so evidence capture was switched off on every start and no
        // photograph was ever taken.
        captureState.withLock { Self.resetForNewSession(&$0) }

        session.beginConfiguration()
        // Motion downscales to 320x240 by sampling, so a higher preset costs it
        // almost nothing — but a `.low` frame is useless as evidence of who took
        // the machine. Only pay for the bandwidth when stills are wanted.
        session.sessionPreset = wantsStills ? .high : .low
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

    public func captureStill() -> Data? {
        captureState.withLock { $0.latestStill }
    }

    public func stop() {
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        // Inputs and outputs are removed inside one configuration transaction;
        // removing them individually makes each its own reconfiguration.
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        captureState.withLock { $0.isRunning = false }
        onFrame = nil
    }

    isolated deinit { stop() }

    /// MUST be `nonisolated`. AVFoundation invokes this on `queue` via ObjC;
    /// without it the package's main-actor default makes Swift 6 insert an
    /// isolation assertion that aborts the process on the very first frame —
    /// invisible to tests, which drive the fake on the main actor.
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        // Throttle here rather than asking the device for a low frame rate:
        // registration is the cost, not capture, and this keeps the pacing in
        // one place regardless of what the hardware offers.
        let now = Date()
        let shouldDeliver = captureState.withLock { state -> Bool in
            guard state.isRunning,
                  now.timeIntervalSince(state.lastDelivery)
                      >= (isCalibrationRate.withLock { $0 } ? calibrationInterval : minimumInterval)
            else { return false }
            state.lastDelivery = now
            return true
        }
        guard shouldDeliver else { return }
        if captureState.withLock({ $0.retainStills }),
           let jpeg = Self.jpeg(from: sampleBuffer) {
            captureState.withLock { state in
                // Re-check: encoding takes milliseconds, and a toggle-off during
                // it would otherwise leave a full-resolution photograph of the
                // user resident after they asked for it to stop.
                guard state.retainStills else { return }
                state.latestStill = jpeg
                guard now.timeIntervalSince(state.lastBuffered) >= Self.bufferInterval
                else { return }
                state.lastBuffered = now
                state.buffer.append(TimestampedStill(jpeg: jpeg, capturedAt: now))
                if state.buffer.count > Self.bufferedStillCount {
                    state.buffer.removeFirst(state.buffer.count - Self.bufferedStillCount)
                }
            }
        }
        guard let frame = Self.grayscaleFrame(from: sampleBuffer,
                                              width: targetWidth, height: targetHeight)
        else { return }
        // Only `frame` crosses the thread boundary; the handler is read on the
        // main actor, where it lives.
        Task { @MainActor [weak self] in self?.onFrame?(frame) }
    }

    /// Encodes the full-resolution frame as JPEG for evidence.
    /// Shared: allocating a CIContext per frame measured ~2x the encode cost,
    /// for work that runs continuously for hours while armed.
    nonisolated static let sharedCIContext = CIContext(options: nil)

    nonisolated static func jpeg(from sampleBuffer: CMSampleBuffer,
                                 quality: Double = 0.8) -> Data? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let context = sharedCIContext
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                          options: [kCGImageDestinationLossyCompressionQuality
                                                    as CIImageRepresentationOption: quality])
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
    public var isPermitted = true
    public private(set) var isRunning = false
    public private(set) var startCallCount = 0
    private var onFrame: ((GrayscaleFrame) -> Void)?

    public var accessGranted = true
    public private(set) var requestAccessCallCount = 0

    public init(isAvailable: Bool = true) { self.isAvailable = isAvailable }

    public func requestAccess() async -> Bool {
        requestAccessCallCount += 1
        return accessGranted
    }

    public private(set) var isHighRate = false
    public func setHighRate(_ high: Bool) { isHighRate = high }

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
