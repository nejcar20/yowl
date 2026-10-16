using Yowl.Core.Engine;
using Yowl.Core.Evidence;

namespace Yowl.Core.Alerts;

/// <summary>Tells the user's phone the alarm went off, with photographs if there are any.</summary>
public sealed class AlertResponse(IAlertTransport transport, IEvidenceStore evidence) : IResponse
{
    public const string Id = "alert";

    private IAlertTransport _transport = transport;
    private CancellationTokenSource? _inFlight;

    public string Identifier => Id;

    /// <summary>
    /// Always true: sending is possible on every machine. Whether a link is set
    /// up is user configuration and lives in IsEnabled, which the engine
    /// re-reads on every fire. On the Mac, making this dynamic filtered alerts
    /// out at launch, so alerts enabled later never fired for a real alarm.
    /// </summary>
    public bool IsAvailable => true;

    /// <summary>Off unless asked for: it sends photographs of people off the machine.</summary>
    public bool IsEnabled { get; set; }

    /// <summary>
    /// Mirrors the photographs setting, so turning photographs off also stops
    /// previously taken ones being sent, as the privacy policy promises.
    /// </summary>
    public bool IncludesPhotographs { get; set; }

    /// <summary>The most recent alarm send, so tests can await it.</summary>
    internal Task LastSend { get; private set; } = Task.CompletedTask;

    public void ReplaceTransport(IAlertTransport transport) => _transport = transport;

    /// <summary>A message the user asked for, to verify pairing. Returns whether it reached the server.</summary>
    public async Task<bool> SendTestAsync()
    {
        try
        {
            await _transport.SendAsync(new AlertPayload("Yowl", "Test alert — your laptop can reach you.",
                                                         AlertUrgency.Normal, DateTimeOffset.Now, []));
            return true;
        }
        catch (AlertTransportException)
        {
            return false;
        }
    }

    /// <summary>
    /// The machine is about to sleep with the alarm going. The siren is about to
    /// stop, so the owner is told it stopped because the laptop slept, not
    /// because anyone disarmed it. Best effort: there is only a moment.
    /// </summary>
    public async Task SendSleepNoticeAsync()
    {
        if (!this.IsActive()) return;
        try
        {
            await _transport.SendAsync(new AlertPayload("Yowl",
                "The laptop went to sleep — the siren stopped. It sounds again when it wakes.",
                AlertUrgency.Normal, DateTimeOffset.Now, []));
        }
        catch (AlertTransportException) { }
    }

    public Task FireAsync(AlarmContext context)
    {
        // Nowhere to send is a no-op, not a failure.
        if (!_transport.IsConfigured) return Task.CompletedTask;
        _inFlight?.Cancel();
        var cancellation = new CancellationTokenSource();
        _inFlight = cancellation;

        var payload = new AlertPayload("Yowl", Describe(context), AlertUrgency.Critical, context.FiredAt,
                                       IncludesPhotographs ? evidence.RecentJpegs(3) : []);
        var transport = _transport;
        // Not awaited by the engine: a slow or dead network must never delay
        // the siren, and a failure must never reach the engine.
        LastSend = Task.Run(async () =>
        {
            if (cancellation.IsCancellationRequested) return;
            try { await transport.SendAsync(payload); }
            catch (AlertTransportException) { }
        });
        return Task.CompletedTask;
    }

    public Task ResetAsync()
    {
        _inFlight?.Cancel();
        _inFlight = null;
        return Task.CompletedTask;
    }

    internal static string Describe(AlarmContext context) => context.Trigger.Value switch
    {
        "power" => "The charger was unplugged.",
        "motion" => "The laptop was moved.",
        _ => "The alarm was triggered.",
    };
}
