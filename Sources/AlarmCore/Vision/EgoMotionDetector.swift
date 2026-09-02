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

    /// A shift larger than this fraction of the frame width is registration
    /// failure, not motion. At 5 fps a hand nudge moves the scene by tens of
    /// pixels; measurements on periodic scenes (blinds, tiles) produced bogus
    /// shifts of 200+ px on a 320 px frame, and those dominated the score.
    static let maximumPlausibleShiftFraction = 0.15

    /// Below this overlap the residual is averaged over too little of the frame
    /// to mean anything, and `explained` is compared against a raw residual
    /// measured elsewhere.
    static let minimumOverlapFraction = 0.6

    /// Left and right halves must agree on the shift to within this many
    /// pixels. A real camera move displaces every part of the frame by the same
    /// amount; a person crossing the view, or a periodic pattern aligning to the
    /// wrong stripe, does not survive that check.
    static let maximumHalfDisagreement = 4.0

    /// A scene with less frame-to-frame variation than this carries no
    /// information to register on — a dark room, or the lid part-closed. Sensor
    /// noise alone was enough to complete a run and fire the siren.
    static let minimumSceneActivity = 0.75

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
        guard let score = score(previous: previous, current: frame) else {
            // An unscorable pair is not evidence of movement. Leaving the run
            // intact lets a stalled sequence be completed by a single hit
            // minutes later.
            consecutiveHits = 0
            // Clear the readout too: a stale number displayed live reads as a
            // current measurement.
            lastScore = nil
            return false
        }
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

        // Guard 1: an implausible shift is registration failure. Accepting it is
        // what let a bogus 215 px shift on a striped background outscore the
        // laptop genuinely being picked up.
        guard shift <= Double(width) * Self.maximumPlausibleShiftFraction else {
            return MotionScore(shift: shift, explained: 0, value: 0)
        }

        // Guard 2: the halves of the frame must agree. This is what separates
        // "the camera moved" from "something moved in front of it": a genuine
        // move displaces both halves identically, while a passer-by shows up in
        // one half, and an ambiguous periodic pattern resolves differently in
        // each. Registration alone cannot tell these apart -- measured, a person
        // crossing a striped background scored higher than the laptop actually
        // being picked up.
        if let (leftShift, rightShift) = Self.halfShifts(previous: previous, current: current) {
            let disagreement = ((leftShift.0 - rightShift.0) * (leftShift.0 - rightShift.0)
                              + (leftShift.1 - rightShift.1) * (leftShift.1 - rightShift.1)).squareRoot()
            guard disagreement <= Self.maximumHalfDisagreement else {
                return MotionScore(shift: shift, explained: 0, value: 0)
            }
        }

        let ix = Int(dx.rounded()), iy = Int(dy.rounded())

        // Guard 3: too little overlap left to measure anything honestly.
        let overlap = Self.overlapFraction(width: width, height: height, dx: ix, dy: iy)
        guard overlap >= Self.minimumOverlapFraction else {
            return MotionScore(shift: shift, explained: 0, value: 0)
        }

        // Both residuals are measured over the SAME overlap region. Comparing a
        // warped residual over a shrinking window against a raw residual over
        // the whole frame biases `explained` upward exactly as the shift grows.
        let residualRaw = Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                                     width: width, height: height,
                                                     dx: 0, dy: 0,
                                                     restrictedTo: (ix, iy))

        // Guard 4: a scene with nothing happening in it carries no signal, and
        // dividing by a near-zero residual turns sensor noise into a siren.
        guard residualRaw >= Self.minimumSceneActivity else {
            return MotionScore(shift: shift, explained: 0, value: 0)
        }

        // Vision's transform direction is undocumented, and applying it the
        // wrong way inverts the detector. Measuring both conventions and
        // keeping the better alignment removes the guess.
        let residualWarped = min(
            Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                        width: width, height: height, dx: ix, dy: iy,
                                        restrictedTo: (ix, iy)),
            Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                        width: width, height: height, dx: -ix, dy: -iy,
                                        restrictedTo: (ix, iy)))

        let explained = 1 - residualWarped / residualRaw
        let value = (shift / Double(width)) * max(0, explained)
        return MotionScore(shift: shift, explained: explained, value: value)
    }

    /// Registers the left and right halves independently. Returns nil when
    /// either half cannot be registered, in which case the check is skipped
    /// rather than treated as disagreement.
    static func halfShifts(previous: GrayscaleFrame,
                           current: GrayscaleFrame) -> ((Double, Double), (Double, Double))? {
        let half = previous.width / 2
        guard let previousLeft = previous.cropped(x: 0, width: half),
              let currentLeft = current.cropped(x: 0, width: half),
              let previousRight = previous.cropped(x: half, width: half),
              let currentRight = current.cropped(x: half, width: half),
              let left = rawShift(previousLeft, currentLeft),
              let right = rawShift(previousRight, currentRight)
        else { return nil }
        return (left, right)
    }

    static func rawShift(_ a: GrayscaleFrame, _ b: GrayscaleFrame) -> (Double, Double)? {
        guard let aImage = a.cgImage, let bImage = b.cgImage else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: bImage, options: [:])
        let handler = VNImageRequestHandler(cgImage: aImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return nil }
        return (Double(observation.alignmentTransform.tx), Double(observation.alignmentTransform.ty))
    }

    /// Fraction of the frame still overlapping after a shift of (dx, dy).
    static func overlapFraction(width: Int, height: Int, dx: Int, dy: Int) -> Double {
        let w = max(0, width - abs(dx)), h = max(0, height - abs(dy))
        return Double(w * h) / Double(width * height)
    }

    /// Mean |a - b| with `a` sampled at an offset of (dx, dy), measured over the
    /// region that a shift of `restrictedTo` leaves overlapping. Both the raw and
    /// the warped residual pass the same `restrictedTo` so they cover identical
    /// pixels and are actually comparable.
    static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8],
                                       width: Int, height: Int, dx: Int, dy: Int,
                                       restrictedTo region: (dx: Int, dy: Int)) -> Double {
        let xLower = max(0, -region.dx), xUpper = min(width, width - region.dx)
        let yLower = max(0, -region.dy), yUpper = min(height, height - region.dy)
        guard xLower < xUpper, yLower < yUpper else { return 255 }

        var total = 0.0
        var counted = 0
        for y in yLower..<yUpper {
            let sy = y + dy
            if sy < 0 || sy >= height { continue }
            for x in xLower..<xUpper {
                let sx = x + dx
                if sx < 0 || sx >= width { continue }
                total += abs(Double(a[sy * width + sx]) - Double(b[y * width + x]))
                counted += 1
            }
        }
        return counted > 0 ? total / Double(counted) : 255
    }
}
