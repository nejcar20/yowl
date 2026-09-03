import Foundation

/// User preference storage.
///
/// This is a *separate axis* from `Capability.isAvailable`. `isAvailable`
/// answers "can this run on this machine and in this build?" — it is what lets
/// a sandboxed App Store build drop features it is forbidden to use, and the
/// user must never be able to switch those on. `isEnabled` answers "does the
/// user want this one active?" A feature runs only when both are true.
public protocol PreferenceStoring: AnyObject {
    /// Most features default on: a user who never opens settings gets the most
    /// protection, not the least. Motion is the exception and passes `false`,
    /// because it holds the camera open.
    func isEnabled(_ identifier: String, default defaultValue: Bool) -> Bool
    func setEnabled(_ enabled: Bool, for identifier: String)
    var graceSeconds: TimeInterval { get set }
    var motionThreshold: Double { get set }
}

public extension PreferenceStoring {
    /// The common case, defined once on top of the defaulted form so the two
    /// cannot drift apart.
    func isEnabled(_ identifier: String) -> Bool { isEnabled(identifier, default: true) }
}

/// The firing threshold, and the sensitivity slider that sets it.
///
/// The range comes from measurement against the real Vision framework, not
/// taste: a 3 px camera move scores ~0.0094, a 12 px move ~0.0375, and sensor
/// noise in a dark room ~0.0014. A threshold below 0.001 would fire on noise;
/// above 0.05 only a large deliberate movement registers.
public enum MotionSensitivity {
    public static let minimum = 0.001
    public static let maximum = 0.05
    public static let defaultValue = 0.005

    static func clamp(_ value: Double) -> Double { min(max(value, minimum), maximum) }

    /// Sensitivity runs the opposite way to the threshold it sets: more
    /// sensitive means a lower bar. Mapped logarithmically, because the useful
    /// values are bunched at the low end — linear would spend most of the
    /// slider's travel in a range where nothing changes.
    public static func threshold(forSensitivity sensitivity: Double) -> Double {
        let clamped = min(max(sensitivity, 0), 1)
        let logMin = log(minimum), logMax = log(maximum)
        return exp(logMax + (logMin - logMax) * clamped)
    }

    public static func sensitivity(forThreshold threshold: Double) -> Double {
        let logMin = log(minimum), logMax = log(maximum)
        return min(max((logMax - log(clamp(threshold))) / (logMax - logMin), 0), 1)
    }
}

public enum GraceLimits {
    public static let minimum: TimeInterval = 0
    public static let maximum: TimeInterval = 60
    /// Zero by default: the siren fires the instant the charger goes, leaving
    /// no window for a thief to find the app and quit it.
    public static let defaultValue: TimeInterval = 0

    static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimum), maximum)
    }
}

public final class UserDefaultsPreferences: PreferenceStoring {
    private let defaults: UserDefaults
    private enum Key {
        static func enabled(_ identifier: String) -> String { "enabled.\(identifier)" }
        static let grace = "graceSeconds"
        static let motionThreshold = "motionThreshold"
    }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func isEnabled(_ identifier: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: Key.enabled(identifier)) as? Bool ?? defaultValue
    }

    public func setEnabled(_ enabled: Bool, for identifier: String) {
        defaults.set(enabled, forKey: Key.enabled(identifier))
    }

    public var graceSeconds: TimeInterval {
        get {
            guard let stored = defaults.object(forKey: Key.grace) as? Double
            else { return GraceLimits.defaultValue }
            return GraceLimits.clamp(stored)
        }
        set { defaults.set(GraceLimits.clamp(newValue), forKey: Key.grace) }
    }

    public var motionThreshold: Double {
        get {
            guard let stored = defaults.object(forKey: Key.motionThreshold) as? Double
            else { return MotionSensitivity.defaultValue }
            return MotionSensitivity.clamp(stored)
        }
        set { defaults.set(MotionSensitivity.clamp(newValue), forKey: Key.motionThreshold) }
    }
}

#if DEBUG
public final class InMemoryPreferences: PreferenceStoring {
    private var enabled: [String: Bool] = [:]
    private var storedGrace = GraceLimits.defaultValue

    public init() {}

    public func isEnabled(_ identifier: String, default defaultValue: Bool) -> Bool {
        enabled[identifier] ?? defaultValue
    }
    public func setEnabled(_ enabled: Bool, for identifier: String) {
        self.enabled[identifier] = enabled
    }

    public var graceSeconds: TimeInterval {
        get { storedGrace }
        set { storedGrace = GraceLimits.clamp(newValue) }
    }

    private var storedThreshold = MotionSensitivity.defaultValue
    public var motionThreshold: Double {
        get { storedThreshold }
        set { storedThreshold = MotionSensitivity.clamp(newValue) }
    }
}
#endif
