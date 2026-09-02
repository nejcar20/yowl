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
