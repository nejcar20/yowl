import Foundation

/// Whether the current configuration could actually catch a theft.
///
/// This exists because a toggle can silently disable the whole alarm. Switching
/// the charger trigger off left the app looking ready while nothing was
/// watching, and the way that was discovered was by unplugging the charger and
/// hearing silence. The user has to be told before they walk away, not after.
public enum ProtectionStatus: Equatable {
    /// At least one trigger is available, enabled, and able to fire.
    case protected
    /// Every trigger is switched off, or the ones switched on are unavailable
    /// in this build.
    case nothingEnabled
    /// Triggers are enabled but none has anything left to detect — the charger
    /// trigger with the charger already unplugged, for instance.
    case nothingCanFireNow

    public init(triggers: [any Trigger]) {
        let usable = triggers.filter(\.isActive)
        if usable.isEmpty {
            self = .nothingEnabled
        } else if !usable.contains(where: \.canFireNow) {
            self = .nothingCanFireNow
        } else {
            self = .protected
        }
    }

    /// Nil only when the configuration can genuinely protect the machine.
    public var warning: String? {
        switch self {
        case .protected:
            return nil
        case .nothingEnabled:
            return "Nothing is watching. Turn on a trigger in Settings, or this will not catch a theft."
        case .nothingCanFireNow:
            return "Nothing can fire right now. If only the charger trigger is on, plug the charger in."
        }
    }
}
