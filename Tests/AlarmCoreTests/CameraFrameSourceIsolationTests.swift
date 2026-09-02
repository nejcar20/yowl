import Testing
import Foundation
import AVFoundation
import CoreVideo
@testable import AlarmCore

/// Builds a minimal BGRA sample buffer, as AVFoundation would deliver.
private func makeSampleBuffer(width: Int = 64, height: Int = 48) -> CMSampleBuffer? {
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else { return nil }
    var info: CMFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: pixelBuffer,
                                                       formatDescriptionOut: &info) == noErr,
          let info else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid,
                                    presentationTimeStamp: .zero,
                                    decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                   imageBuffer: pixelBuffer,
                                                   formatDescription: info,
                                                   sampleTiming: &timing,
                                                   sampleBufferOut: &buffer) == noErr
    else { return nil }
    return buffer
}

// AVFoundation calls the capture delegate on its own queue, never the main
// actor. The package is main-actor isolated by default, so without an explicit
// `nonisolated` on the callback Swift 6 inserts an isolation assertion that
// ABORTS THE PROCESS on the first real frame — and no test using FakeFrameSource
// can see it, because the fake delivers on the main actor. This test crosses the
// real thread boundary, so it fails (by killing the test run) if that
// `nonisolated` is ever removed.
@Test func theCaptureCallbackSurvivesBeingCalledOffTheMainActor() async throws {
    let source = CameraFrameSource(framesPerSecond: 5)
    let buffer = try #require(makeSampleBuffer())
    let output = AVCaptureVideoDataOutput()

    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            source.captureOutput(output, didOutput: buffer,
                                 from: AVCaptureConnection(inputPorts: [], output: output))
            continuation.resume()
        }
    }
    // Reaching here at all is the assertion: the call did not trap.
    #expect(Bool(true))
}

// The frame conversion itself must also be callable off the main actor.
@Test func frameConversionWorksOffTheMainActor() async throws {
    let buffer = try #require(makeSampleBuffer(width: 64, height: 48))
    let frame: GrayscaleFrame? = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning:
                CameraFrameSource.grayscaleFrame(from: buffer, width: 32, height: 24))
        }
    }
    let unwrapped = try #require(frame)
    #expect(unwrapped.width == 32)
    #expect(unwrapped.height == 24)
    #expect(unwrapped.pixels.count == 32 * 24)
}
