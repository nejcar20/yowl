using Yowl.Core.Engine;
using Yowl.Core.Vision;

namespace Yowl.Core.Evidence;

/// <summary>
/// Photographs whoever is in front of the machine when the alarm fires.
///
/// Several shots rather than one: the first often catches the back of a head,
/// and someone walking away with a laptop turns around. Cannot fail the alarm:
/// the siren is the point and evidence a bonus, so a camera that gives no image
/// is skipped.
/// </summary>
public sealed class SnapshotResponse : IResponse
{
    public const string Id = "snapshot";

    private readonly IStillCapture _camera;
    private readonly IEvidenceStore _store;
    private readonly IAlarmClock _clock;
    private readonly int _shotCount;
    private readonly TimeSpan _interval;
    private readonly List<IScheduledWork> _pendingShots = [];

    public SnapshotResponse(IStillCapture camera, IEvidenceStore store, IAlarmClock clock,
                            int shotCount = 3, TimeSpan? interval = null)
    {
        _camera = camera;
        _store = store;
        _clock = clock;
        _shotCount = Math.Max(1, shotCount);
        _interval = interval ?? TimeSpan.FromSeconds(2);
        // Hardware, captured once: a machine with no camera is never offered
        // the toggle. Permission is user configuration, in IsEnabled.
        IsAvailable = camera.IsAvailable;
    }

    public string Identifier => Id;
    public bool IsAvailable { get; }
    /// <summary>Off unless asked for: it writes photographs of people to disk.</summary>
    public bool IsEnabled { get; set; }

    public Task FireAsync(AlarmContext context)
    {
        CancelPending();
        // The run-up first, oldest to newest, then the moment itself.
        foreach (var still in _camera.BufferedStills())
            _store.Save(new EvidenceItem(still.Jpeg, still.CapturedAt, context.Trigger.Value));
        _camera.ClearBufferedStills();
        Capture(context);
        for (var shot = 1; shot < _shotCount && _interval > TimeSpan.Zero; shot++)
            _pendingShots.Add(_clock.Schedule(_interval * shot, () => Capture(context)));
        return Task.CompletedTask;
    }

    public Task ResetAsync()
    {
        // Stop photographing the room the moment the user disarms.
        CancelPending();
        return Task.CompletedTask;
    }

    private void Capture(AlarmContext context)
    {
        if (_camera.CaptureStill() is not { } jpeg) return;
        // The time of this shot, not of the trigger: sharing the trigger's time
        // gave every shot one filename and two thirds of the evidence was lost.
        _store.Save(new EvidenceItem(jpeg, _clock.Now, context.Trigger.Value));
    }

    private void CancelPending()
    {
        foreach (var work in _pendingShots) work.Cancel();
        _pendingShots.Clear();
    }
}
