import Foundation

/// User preference storage.
///
/// This is a *separate axis* from `Capability.isAvailable`. `isAvailable`
/// answers "can this run on this machine and in this build?" — it is what lets
/// a sandboxed App Store build drop features it is forbidden to use, and the
/// user must never be able to switch those on. `isEnabled` answers "does the
/// user want this one active?" A feature runs only when both are true.
public protocol PreferenceStoring: AnyObject {
    /// Defaults to `true`: a user who never opens settings gets the most
    /// protection, not the least.
    func isEnabled(_ identifier: String) -> Bool
    func setEnabled(_ enabled: Bool, for identifier: String)
    var graceSeconds: TimeInterval { get set }
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
    }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func isEnabled(_ identifier: String) -> Bool {
        defaults.object(forKey: Key.enabled(identifier)) as? Bool ?? true
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

}

#if DEBUG
public final class InMemoryPreferences: PreferenceStoring {
    private var enabled: [String: Bool] = [:]
    private var storedGrace = GraceLimits.defaultValue

    public init() {}

    public func isEnabled(_ identifier: String) -> Bool { enabled[identifier] ?? true }
    public func setEnabled(_ enabled: Bool, for identifier: String) {
        self.enabled[identifier] = enabled
    }

    public var graceSeconds: TimeInterval {
        get { storedGrace }
        set { storedGrace = GraceLimits.clamp(newValue) }
    }
}
#endif
