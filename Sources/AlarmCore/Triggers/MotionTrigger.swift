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

    /// Runs the detector without arming the alarm, for the live sensitivity
    /// readout. Thresholds correct at a kitchen table are wrong in a dim cafe,
    /// so the user has to be able to watch the number at their actual table.
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
}
