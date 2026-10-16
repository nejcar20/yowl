using Yowl.Core.Engine;

namespace Yowl.Core.Triggers;

public interface IPowerSourceMonitor
{
    bool IsOnAcPower { get; }

    /// <summary>Replaces any existing handler. May report the same value repeatedly.</summary>
    void Start(Action<bool> onChange);
    void Stop();
}

/// <summary>
/// Fires on the AC-to-battery edge. Edge-detected because Windows reports power
/// status changes for many reasons besides the charger, such as battery level.
/// </summary>
public sealed class PowerTrigger(IPowerSourceMonitor monitor, TimeSpan grace) : ITrigger
{
    public TriggerId Id => TriggerId.Power;
    public string Identifier => Id.Value;
    public bool IsAvailable => true;
    public bool IsEnabled { get; set; } = true;
    public TimeSpan Grace { get; set; } = grace;

    private bool _wasOnAc = monitor.IsOnAcPower;
    private Action<TriggerId>? _onFire;

    /// <summary>
    /// Arming while already on battery can never fire: the edge is gone. The
    /// likely sequence is thief pulls charger, owner disarms, owner re-arms
    /// while still unplugged.
    /// </summary>
    public bool CanFireNow => monitor.IsOnAcPower;

    public void Start(Action<TriggerId> onFire)
    {
        _onFire = onFire;
        _wasOnAc = monitor.IsOnAcPower;
        monitor.Start(isOnAc =>
        {
            var fell = _wasOnAc && !isOnAc;
            _wasOnAc = isOnAc;
            if (fell) _onFire?.Invoke(Id);
        });
    }

    public void Stop()
    {
        monitor.Stop();
        _onFire = null;
    }
}
