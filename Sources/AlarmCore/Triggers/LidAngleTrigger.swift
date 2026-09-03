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
    public var isEnabled = true
    public var graceSeconds: TimeInterval

    /// Degrees of closing from the arming angle before the alarm fires. The
    /// hinge reading jitters by about a degree while typing, so this must be
    /// comfortably above that without waiting for the lid to be shut.
    public let closingByDegrees: Double

    /// Below this the lid is effectively already shut and cannot close further.
    static let shutAngle = 5.0

    private let sensor: LidAngleSensing
    private var baseline: Double?
    private var onFire: ((TriggerID) -> Void)?

    public init(sensor: LidAngleSensing, closingByDegrees: Double = 8,
                graceSeconds: TimeInterval) {
        self.sensor = sensor
        self.closingByDegrees = closingByDegrees
        self.graceSeconds = graceSeconds
    }

    public var isAvailable: Bool { sensor.isAvailable }

    /// An already-shut lid cannot be closed any further, so there is nothing
    /// left for this trigger to detect — the same reasoning as the charger
    /// trigger refusing when the charger is already out.
    public var canFireNow: Bool {
        guard sensor.isAvailable, let angle = sensor.angle else { return false }
        return angle > Self.shutAngle
    }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        // Re-baseline on every arm: arming with a half-closed lid must not fire
        // immediately against a baseline from a previous session.
        baseline = sensor.angle
        sensor.startReading { [weak self] angle in
            guard let self, let baseline = self.baseline else { return }
            guard baseline - angle >= self.closingByDegrees else { return }
            self.onFire?(self.id)
        }
    }

    public func stop() {
        sensor.stopReading()
        baseline = nil
        onFire = nil
    }
}
