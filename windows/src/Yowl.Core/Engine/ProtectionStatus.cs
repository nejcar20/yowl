namespace Yowl.Core.Engine;

/// <summary>
/// Whether the current configuration could actually catch a theft.
///
/// A toggle can silently disable the whole alarm: on the Mac, switching the
/// charger trigger off left the app looking ready while nothing was watching,
/// and that was found by unplugging the charger and hearing silence. The user
/// has to be told before they walk away, not after.
/// </summary>
public abstract record ProtectionStatus
{
    public sealed record Protected : ProtectionStatus;

    /// <summary>Every trigger is off, or the ones switched on are unavailable.</summary>
    public sealed record NothingEnabled : ProtectionStatus;

    /// <summary>
    /// Triggers are on but none has anything left to detect. Carries the
    /// triggers actually responsible, because a message naming every possible
    /// cause is a guess in every single case.
    /// </summary>
    public sealed record NothingCanFireNow(IReadOnlySet<TriggerId> Blocked) : ProtectionStatus;

    public static ProtectionStatus From(IEnumerable<ITrigger> triggers)
    {
        var usable = triggers.Where(t => t.IsActive()).ToList();
        if (usable.Count == 0) return new NothingEnabled();
        // Only the active ones: a switched-off trigger is not why arming is
        // refused, and naming it sends the user to fix the wrong thing.
        if (!usable.Any(t => t.CanFireNow))
            return new NothingCanFireNow(usable.Select(t => t.Id).ToHashSet());
        return new Protected();
    }

    /// <summary>Null only when the configuration can genuinely protect the machine.</summary>
    public string? Warning => this switch
    {
        Protected => null,
        NothingEnabled => "Nothing is watching. Turn on a trigger in Settings, or this will not catch a theft.",
        NothingCanFireNow n => BlockedMessage(n.Blocked),
        _ => null,
    };

    private static string BlockedMessage(IReadOnlySet<TriggerId> blocked)
    {
        // One instruction, naming only what is in the way. The reader is about
        // to walk away from the laptop; they need the next action.
        if (blocked.Contains(TriggerId.Power))
            return "Plug the charger in to arm, or switch on another trigger in Settings.";
        return "Nothing can fire right now. Switch on another trigger in Settings.";
    }
}
