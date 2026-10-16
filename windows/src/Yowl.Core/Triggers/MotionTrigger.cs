using Yowl.Core.Engine;
using Yowl.Core.Vision;

namespace Yowl.Core.Triggers;

/// <summary>
/// Fires when the laptop itself is moved, ignoring movement in front of it.
///
/// The camera light is on for as long as this is armed, so it is off by
/// default and the user opts in.
/// </summary>
public sealed class MotionTrigger : ITrigger
{
    private readonly IFrameSource _source;
    private Action<TriggerId>? _onFire;
    private bool _isCalibrating;

    public MotionTrigger(IFrameSource source, EgoMotionDetector detector, TimeSpan grace)
    {
        _source = source;
        Detector = detector;
        Grace = grace;
        // Hardware only, captured once: the engine filters on this at
        // construction, so folding permission in would strand the trigger for
        // the session after access was granted.
        IsAvailable = source.IsAvailable;
    }

    public TriggerId Id => TriggerId.Motion;
    public string Identifier => Id.Value;
    public bool IsAvailable { get; }
    public bool IsEnabled { get; set; }
    public TimeSpan Grace { get; set; }

    /// <summary>Motion needs no prior state, unlike the charger's AC-to-battery edge.</summary>
    public bool CanFireNow => true;

    /// <summary>Exposed for the live readout in Settings.</summary>
    public EgoMotionDetector Detector { get; }

    public Task<bool> RequestAccessAsync() => _source.RequestAccessAsync();

    public void Start(Action<TriggerId> onFire)
    {
        // Arming takes the camera back from a calibration session rather than
        // running both against one camera.
        if (_isCalibrating) StopCalibration();
        _onFire = onFire;
        // Frames from an earlier session must not let one new frame complete an old run.
        Detector.Reset();
        _source.Start(frame =>
        {
            if (Detector.Submit(frame)) _onFire?.Invoke(Id);
        });
    }

    public void Stop()
    {
        _source.Stop();
        Detector.Reset();
        _onFire = null;
    }

    /// <summary>
    /// Runs the detector without arming, for the live sensitivity readout.
    /// Refused while armed: both hold the one camera, and calibrating would
    /// silently replace the firing handler and disable the alarm.
    /// </summary>
    public void StartCalibration(Action<MotionScore> onScore)
    {
        if (_onFire is not null) throw new InvalidOperationException("The alarm is armed.");
        _isCalibrating = true;
        _source.SetHighRate(true);
        Detector.Reset();
        _source.Start(frame =>
        {
            Detector.Submit(frame);
            if (Detector.LastScore is { } score) onScore(score);
        });
    }

    public void StopCalibration()
    {
        _isCalibrating = false;
        _source.SetHighRate(false);
        _source.Stop();
        Detector.Reset();
    }
}
