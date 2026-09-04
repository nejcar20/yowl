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
    /// trigger with the charger already unplugged, for instance. Carries the
    /// triggers actually responsible, because the message that named every
    /// possible cause joined by "or" was a guess in every single case.
    case nothingCanFireNow(blocked: Set<TriggerID>)

    public init(triggers: [any Trigger]) {
        let usable = triggers.filter(\.isActive)
        if usable.isEmpty {
            self = .nothingEnabled
        } else if !usable.contains(where: \.canFireNow) {
            // Only the active ones: a switched-off trigger is not why arming is
            // refused, and naming it sends the user to fix the wrong thing.
            self = .nothingCanFireNow(blocked: Set(usable.map(\.id)))
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
        case let .nothingCanFireNow(blocked):
            return Self.blockedMessage(for: blocked)
        }
    }

    /// One instruction, naming only what is actually in the way. The reader is
    /// standing at a laptop they are about to walk away from; they need the next
    /// action, not a list of things that might be true.
    private static func blockedMessage(for blocked: Set<TriggerID>) -> String {
        let fixes = [
            (TriggerID("power"), "plug the charger in"),
            (TriggerID("lid"), "open the lid further"),
        ].filter { blocked.contains($0.0) }.map(\.1)

        guard !fixes.isEmpty else {
            // A trigger this build cannot explain still has to warn: reporting
            // no reason would read as "protected".
            return "Nothing can fire right now. Switch on another trigger in Settings."
        }

        let action = fixes.joined(separator: " and ")
        return "\(action.prefix(1).uppercased())\(action.dropFirst()) to arm, "
             + "or switch on another trigger in Settings."
    }
}
