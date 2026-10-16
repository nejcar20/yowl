using Yowl.Core.Engine;

namespace Yowl.Core.Responses;

public interface ISirenPlayer
{
    /// <summary>Whether sound is actually being produced, read from the audio device.</summary>
    bool IsPlaying { get; }

    /// <summary>Starts the siren. A no-op returning true while it really is playing.</summary>
    bool Start();

    void Stop();
}

/// <summary>The speaker output's volume and mute, as found before the siren.</summary>
public sealed record AudioOutputState(string DeviceId, float Volume, bool Muted);

public interface IAudioOutputControl
{
    /// <summary>Null when there is no output to control.</summary>
    AudioOutputState? CurrentState();

    /// <summary>Unmutes the speakers and sets them to full volume.</summary>
    /// <exception cref="Exception">The write failed, so the siren may be inaudible.</exception>
    void ForceMaxVolume();

    void Restore(AudioOutputState state);
}

/// <summary>
/// Forces the speakers to full volume and sounds the siren, restoring the
/// user's audio settings on reset.
/// </summary>
public sealed class SirenResponse(ISirenPlayer player, IAudioOutputControl audio, IAlarmClock clock) : IResponse
{
    public const string Id = "siren";

    /// <summary>
    /// How often the volume is taken back while the siren sounds. Short enough
    /// that a muted second is all a thief gets.
    /// </summary>
    public static readonly TimeSpan VolumeHoldInterval = TimeSpan.FromSeconds(1);

    private IScheduledWork? _volumeHold;
    /// <summary>Captured on the first fire only, so a repeat cannot save the already-forced state.</summary>
    private AudioOutputState? _savedState;
    private bool _firing;

    public string Identifier => Id;
    public bool IsAvailable => true;
    public bool IsEnabled { get; set; } = true;

    /// <summary>True if the siren is producing sound; false if it started but could not be made audible.</summary>
    public bool IsSounding { get; private set; }

    public Task FireAsync(AlarmContext context)
    {
        _firing = true;
        _savedState ??= audio.CurrentState();

        // Fail toward noise: start the player even if the volume could not be
        // forced, but do not claim the siren is sounding on a muted machine.
        var forced = true;
        try { audio.ForceMaxVolume(); }
        catch { forced = false; }
        var started = player.Start();
        IsSounding = forced && started;
        ScheduleVolumeHold();
        return Task.CompletedTask;
    }

    /// <summary>
    /// Forcing the volume once only beats a thief who does not think to press
    /// mute. So it is taken back every second for as long as the siren sounds.
    /// Re-arms itself rather than repeating, so there is exactly one piece of
    /// pending work to cancel and none can run after a disarm.
    /// </summary>
    private void ScheduleVolumeHold()
    {
        _volumeHold?.Cancel();
        _volumeHold = clock.Schedule(VolumeHoldInterval, () =>
        {
            if (!_firing) return;
            // A failure here is one attempt; the next is a second away.
            try { audio.ForceMaxVolume(); } catch { }
            // An audio device change (headphones in, a dock, the lid) stops the
            // stream underneath us. Start is a no-op while it really plays.
            player.Start();
            ScheduleVolumeHold();
        });
    }

    public Task ResetAsync()
    {
        RestoreAudioAndSilence();
        return Task.CompletedTask;
    }

    /// <summary>
    /// The single teardown path. Synchronous, because it must also run when the
    /// app exits mid-alarm, or the machine is left unmuted at full volume.
    /// </summary>
    public void RestoreAudioAndSilence()
    {
        // Before the restore, never after: a hold landing in between would put
        // the volume back to full with the alarm already over.
        _firing = false;
        _volumeHold?.Cancel();
        _volumeHold = null;
        player.Stop();
        IsSounding = false;
        if (_savedState is { } saved)
        {
            audio.Restore(saved);
            _savedState = null;
        }
    }
}
