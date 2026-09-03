import Foundation

/// Fires when the lid is closed by more than a threshold from where it was when
/// the alarm was armed.
///
/// Closing the lid is the theft gesture — someone shuts the laptop to carry it —
/// and the angle sensor sees it degrees before the lid is shut. That head start
/// is the whole point: waiting for a sleep notification means reacting after the
/// machine has already begun sleeping, which is too late to make a noise.
///
/// Measured from the arming angle rather than frame to frame, so a slow
/// deliberate close fires just as a slam does.
public final class LidAngleTrigger: Trigger {
    public let id = TriggerID("lid")
    public var identifier: String { id.rawValue }
    /// Off unless asked for. Closing your own laptop is an ordinary gesture, so
    /// this must be a deliberate choice rather than something discovered by a
    /// maximum-volume siren.
    public var isEnabled = false
    public var graceSeconds: TimeInterval

    /// Degrees of closing from the arming angle before the alarm fires.
    ///
    /// The default is 30, not the 8 first chosen. Measured, the sensor does not
    /// jitter at all (113 samples at 10 Hz: spread 0), so jitter was never the
    /// constraint — deliberate screen adjustment is. People tilt a screen by
    /// well over 8 degrees for glare, posture, or to show someone something, and
    /// each of those would have meant a maximum-volume siren. At 30 the alarm
    /// still fires roughly 80 degrees before the lid is shut on a typical
    /// working angle, which keeps the head start this trigger exists for.
    public let closingByDegrees: Double

    /// Below this the lid is effectively already shut and cannot close further.
    static let shutAngle = 5.0

    /// The lid must still be this far open when the alarm fires, or the head
    /// start is gone: firing at 15 degrees means the siren starts as the lid
    /// touches, by which point clamshell sleep is already under way.
    static let minimumFiringAngle = 30.0

    private let sensor: LidAngleSensing
    private var baseline: Double?
    private var onFire: ((TriggerID) -> Void)?

    public init(sensor: LidAngleSensing, closingByDegrees: Double = 30,
                graceSeconds: TimeInterval) {
        self.sensor = sensor
        self.closingByDegrees = closingByDegrees
        self.graceSeconds = graceSeconds
    }

    public var isAvailable: Bool { sensor.isAvailable }

    /// There must be room left to close by `closingByDegrees` BEFORE the lid is
    /// shut. Gating on the shut angle alone armed the trigger in a band where it
    /// could only fire after clamshell sleep had already begun — which is
    /// exactly the latency this trigger exists to avoid.
    public var canFireNow: Bool {
        guard sensor.isAvailable, let angle = sensor.angle else { return false }
        return angle >= minimumArmingAngle
    }

    /// Arming below this leaves no room to fire while the lid is still usefully
    /// open. Refusing is honest: a laptop already at 45 degrees cannot give the
    /// warning this trigger promises.
    public var minimumArmingAngle: Double {
        Self.minimumFiringAngle + closingByDegrees
    }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        // Re-baseline on every arm: arming with a half-closed lid must not fire
        // immediately against a baseline from a previous session.
        baseline = sensor.angle
        sensor.startReading { [weak self] angle in
            guard let self, let angle else { return }
            // Adopt the first successful reading if the arming read failed.
            // Leaving the baseline nil made the trigger deaf for the whole
            // session while the UI still said "Armed".
            guard let baseline = self.baseline else {
                // Adopt a recovered reading only if it still leaves room to
                // fire usefully; adopting one taken mid-close would set the
                // baseline part-closed and quietly make the trigger unfirable.
                if angle >= self.minimumArmingAngle { self.baseline = angle }
                return
            }
            guard baseline - angle >= self.closingByDegrees else { return }
            self.onFire?(self.id)
        }
    }

    public func stop() {
        sensor.stopReading()
        // Clearing the baseline is what actually prevents a callback still in
        // flight from firing after the user disarmed, and it is pinned by a
        // test. Releasing the handler is redundant for safety and kept only so
        // a stopped trigger does not retain its caller's closure.
        baseline = nil
        onFire = nil
    }
}
