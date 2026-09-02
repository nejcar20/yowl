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
