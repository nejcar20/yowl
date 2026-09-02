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
///
/// Measured behaviour, real Vision framework, 320x240:
///
///     textured scene, camera moved 3-160 px   explained +1.000   FIRES at every speed
///     textured scene, person walks past       explained -0.481   quiet
///     dark noisy room                         value     +0.001   quiet
///     PERIODIC scene (blinds, tiles, brick)   explained +1.000   FIRES INDISCRIMINATELY
///
/// **Known limitation: periodic backgrounds.** Where the scene repeats — window
/// blinds, tiled floors, brick, a radiator — translational registration is
/// ambiguous: shifting by one stripe width aligns as well as the true shift, so
/// the residual cannot tell a passer-by from the laptop being moved and both
/// score high. Two guards were tried and both were worse than the disease: a cap
/// on plausible shift made the detector blind to a snatch (the fast motion that
/// matters most), and a left/right half-agreement rule disabled it whenever half
/// the view was a plain wall. Neither is a tuning problem; both are structurally
/// wrong for this measure.
///
/// The failure direction is at least the safe one — it over-fires rather than
/// staying silent — and the live sensitivity readout exists so a user can find
/// out in ten seconds whether their table is one of the bad ones. Solving it
/// properly needs a different measure (feature-based registration with an
/// inlier ratio, or optical flow coherence) and belongs in its own phase.
public final class EgoMotionDetector {
    /// Settable so the sensitivity slider takes effect without rebuilding the
    /// detector — otherwise it would only apply after a relaunch.
    public var threshold: Double
    public let consecutiveFramesRequired: Int

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

        let ix = Int(dx.rounded()), iy = Int(dy.rounded())

        // Both residuals are measured over the SAME overlap region. Comparing a
        // warped residual over a shrinking window against a raw residual over
        // the whole frame biases `explained` upward exactly as the shift grows.
        let residualRaw = Self.meanAbsoluteDifference(previous.pixels, current.pixels,
                                                     width: width, height: height,
                                                     dx: 0, dy: 0,
                                                     restrictedTo: (ix, iy))

        // A scene with nothing happening in it carries no signal, and
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
                                        restrictedTo: (-ix, -iy)))

        let explained = 1 - residualWarped / residualRaw
        let value = (shift / Double(width)) * explained
        return MotionScore(shift: shift, explained: explained, value: value)
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
