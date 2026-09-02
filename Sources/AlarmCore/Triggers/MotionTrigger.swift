// Sources/AlarmCore/Triggers/MotionTrigger.swift
import Foundation

public enum MotionTriggerError: Error, Equatable {
    /// Calibration was requested while the alarm holds the camera.
    case armed
}

/// Fires when the laptop itself is moved, ignoring movement in front of it.
///
/// The camera light is on for as long as this is armed — hardware-enforced and
/// impossible to hide — so this trigger is off by default and the user opts in.
public final class MotionTrigger: Trigger {
    public let id = TriggerID("motion")
    public var identifier: String { id.rawValue }
    /// Off unless asked for. Every other feature defaults on, but this one
    /// holds the camera open and lights the green indicator, so the safe
    /// default belongs in the type rather than only in the app that wires it.
    public var isEnabled = false
    public var graceSeconds: TimeInterval

    /// Exposed so the calibration window can show the live score: thresholds
    /// correct at a kitchen table are wrong in a dim cafe, so the user has to
    /// be able to watch the number at the table they actually sit at.
    public let detector: EgoMotionDetector

    private let source: FrameSourcing
    private var onFire: ((TriggerID) -> Void)?
    private var isCalibrating = false

    public init(source: FrameSourcing, detector: EgoMotionDetector,
                graceSeconds: TimeInterval) {
        self.source = source
        self.detector = detector
        self.graceSeconds = graceSeconds
    }

    public var isAvailable: Bool { source.isAvailable }

    /// Prompts for camera access if it has not been decided yet, so the answer
    /// is known when the user switches the feature on rather than discovered at
    /// arm time, when it is too late to tell them.
    public func requestAccess() async -> Bool { await source.requestAccess() }

    /// Motion needs no prior state to detect, unlike the charger trigger, which
    /// needs an AC-to-battery edge that does not exist if already on battery.
    public var canFireNow: Bool { true }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        // Arming takes the camera back from a calibration session rather than
        // running both against one source.
        if isCalibrating { stopCalibration() }
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
        // Both hold the one camera. Calibrating while armed would silently
        // replace the firing handler and disable the alarm with no error and no
        // state change, so the exclusion lives here rather than only in the UI.
        guard onFire == nil else { throw MotionTriggerError.armed }
        isCalibrating = true
        detector.reset()
        try source.start { [weak self] frame in
            guard let self else { return }
            _ = self.detector.submit(frame)
            if let score = self.detector.lastScore { onScore(score) }
        }
    }

    public func stopCalibration() {
        isCalibrating = false
        source.stop()
        detector.reset()
    }
}
