import Foundation

/// Fires on the AC -> battery edge. Edge-detected because IOKit emits power
/// notifications continuously as the battery level changes.
public final class PowerTrigger: Trigger {
    public let id = TriggerID("power")
    public var identifier: String { id.rawValue }
    public let isAvailable = true
    public var isEnabled = true
    public var graceSeconds: TimeInterval

    /// Only an AC -> battery edge fires this trigger, so arming while already
    /// on battery can never fire: the edge is gone. The engine uses this to
    /// refuse the arm rather than leave the user with a shield icon and no
    /// protection (the likely sequence being: thief pulls charger, owner
    /// disarms, owner re-arms while still unplugged).
    public var canFireNow: Bool { monitor.isOnACPower }

    private let monitor: PowerSourceMonitoring
    private var wasOnAC: Bool
    private var onFire: ((TriggerID) -> Void)?

    public init(monitor: PowerSourceMonitoring, graceSeconds: TimeInterval) {
        self.monitor = monitor
        self.graceSeconds = graceSeconds
        self.wasOnAC = monitor.isOnACPower
    }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        wasOnAC = monitor.isOnACPower
        monitor.startMonitoring { [weak self] isOnAC in
            guard let self else { return }
            defer { self.wasOnAC = isOnAC }
            guard self.wasOnAC, !isOnAC else { return }
            self.onFire?(self.id)
        }
    }

    public func stop() {
        monitor.stopMonitoring()
        onFire = nil
    }
}
