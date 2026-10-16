using NAudio.CoreAudioApi;
using NAudio.Wave;
using Yowl.Core.Responses;

namespace Yowl.Windows.Platform;

/// <summary>
/// Plays the siren on the laptop's own speakers and holds them at full volume.
///
/// Windows has no public way to change the default output, so instead of
/// switching it (as the Mac app does) the siren is rendered directly to the
/// speaker endpoint. Plugging in headphones or Bluetooth then cannot divert it.
///
/// Limitation: on laptops where the speakers and the headphone jack are one
/// endpoint, plugging headphones in switches that endpoint over to the jack,
/// and no app can route around that.
/// </summary>
internal sealed class SpeakerAudio : ISirenPlayer, IAudioOutputControl, IDisposable
{
    // EndpointFormFactor values from mmdeviceapi.h.
    private const uint FormFactorSpeakers = 1;

    private readonly MMDeviceEnumerator _enumerator = new();
    private WasapiOut? _output;
    /// <summary>The device the siren is playing on, kept alive for as long as the stream is.</summary>
    private MMDevice? _outputDevice;
    /// <summary>
    /// Set when the current stream stopped without being asked. Only that
    /// stream's event counts: NAudio posts PlaybackStopped late, and a stale
    /// one from an earlier stream would mark the new one dead, and every
    /// one-second restart would then post another.
    /// </summary>
    private volatile bool _stoppedUnderneath;

    /// <summary>
    /// The built-in speakers if they can be told apart, else the default output.
    /// Re-resolved on every call: devices come and go, and a stale handle to an
    /// unplugged one plays to nothing. The caller owns, and must dispose, the
    /// result; every other device enumerated is disposed here. Each MMDevice
    /// whose volume is touched registers a Windows callback that only Dispose
    /// removes, so leaking them leaks one registration per second of siren.
    /// </summary>
    private MMDevice? Target()
    {
        var candidates = new List<MMDevice>();
        try
        {
            candidates.AddRange(_enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active));
            var defaultId = _enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
                ? DefaultId()
                : null;
            var speakers = candidates.Where(IsSpeakers).ToList();
            // The default, if it is a speaker; otherwise the first speaker;
            // otherwise the default. Some noise somewhere beats choosing nothing.
            var chosen = speakers.FirstOrDefault(d => d.ID == defaultId)
                         ?? speakers.FirstOrDefault()
                         ?? candidates.FirstOrDefault(d => d.ID == defaultId);
            candidates.Remove(chosen!);
            return chosen;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            return null;
        }
        finally
        {
            foreach (var device in candidates) device.Dispose();
        }
    }

    private string DefaultId()
    {
        using var device = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        return device.ID;
    }

    private static bool IsSpeakers(MMDevice device)
    {
        try
        {
            var value = device.Properties[PropertyKeys.PKEY_AudioEndpoint_FormFactor]?.Value;
            return value is uint formFactor && formFactor == FormFactorSpeakers;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidCastException)
        {
            return false;
        }
    }

    /// <summary>For the self-test: every active output, and which one the siren would use.</summary>
    public IReadOnlyList<string> Describe()
    {
        using var target = Target();
        var lines = new List<string>();
        foreach (var device in _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device)
            {
                var mark = device.ID == target?.ID ? "->" : "  ";
                lines.Add($"{mark} {device.FriendlyName} [{(IsSpeakers(device) ? "speakers" : "other")}]"
                          + $" volume {device.AudioEndpointVolume.MasterVolumeLevelScalar:P0}"
                          + (device.AudioEndpointVolume.Mute ? " muted" : ""));
            }
        }
        if (target is null) lines.Add("   no output found");
        return lines;
    }

    // MARK: - IAudioOutputControl

    public AudioOutputState? CurrentState()
    {
        using var device = Target();
        if (device is null) return null;
        var volume = device.AudioEndpointVolume;
        return new AudioOutputState(device.ID, volume.MasterVolumeLevelScalar, volume.Mute);
    }

    public void ForceMaxVolume()
    {
        using var device = Target() ?? throw new InvalidOperationException("No audio output.");
        var volume = device.AudioEndpointVolume;
        volume.Mute = false;
        volume.MasterVolumeLevelScalar = 1f;
    }

    public void Restore(AudioOutputState state)
    {
        try
        {
            using var device = _enumerator.GetDevice(state.DeviceId);
            var volume = device.AudioEndpointVolume;
            volume.MasterVolumeLevelScalar = state.Volume;
            volume.Mute = state.Muted;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException)
        {
            // The device has gone (a dock unplugged). Nothing to put back.
        }
    }

    // MARK: - ISirenPlayer

    /// <summary>Read from the stream itself: a device change stops it without asking.</summary>
    public bool IsPlaying => _output is { PlaybackState: PlaybackState.Playing } && !_stoppedUnderneath;

    public bool Start()
    {
        if (IsPlaying) return true;
        Stop();

        var device = Target();
        if (device is null) return false;
        try
        {
            // Generated at the device's own mix rate and channel count, so the
            // shared-mode engine takes it as is. The Mac app played 9% off
            // pitch when its generator and its connection disagreed on rate.
            var mix = device.AudioClient.MixFormat;
            var siren = new SirenWave(mix.SampleRate, mix.Channels);
            var output = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 100);
            output.PlaybackStopped += (sender, _) =>
            {
                if (ReferenceEquals(sender, _output)) _stoppedUnderneath = true;
            };
            output.Init(siren);
            _stoppedUnderneath = false;
            _output = output;
            _outputDevice = device;
            output.Play();
            return true;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException
                                       or ArgumentException or NotSupportedException)
        {
            Stop();
            if (!ReferenceEquals(device, _outputDevice)) device.Dispose();
            return false;
        }
    }

    public void Stop()
    {
        var output = _output;
        var device = _outputDevice;
        // Cleared first, so the PlaybackStopped this causes is recognised as stale.
        _output = null;
        _outputDevice = null;
        if (output is not null)
        {
            try { output.Stop(); } catch (System.Runtime.InteropServices.COMException) { }
            output.Dispose();
        }
        device?.Dispose();
    }

    public void Dispose()
    {
        Stop();
        _enumerator.Dispose();
    }
}

/// <summary>
/// A two-tone siren, generated rather than recorded so there is no sample to
/// license: a triangle sweep between 700 and 1100 Hz, twice a second. The same
/// sound as the Mac app.
/// </summary>
internal sealed class SirenWave(int sampleRate, int channels) : ISampleProvider
{
    private const double LowHz = 700, HighHz = 1100, SweepSeconds = 0.5, Amplitude = 0.9;
    private double _phase, _elapsed;

    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, channels);

    public int Read(float[] buffer, int offset, int count)
    {
        var frames = count / channels;
        for (var frame = 0; frame < frames; frame++)
        {
            var position = _elapsed % (SweepSeconds * 2) / SweepSeconds;
            var ramp = position < 1 ? position : 2 - position;
            var frequency = LowHz + (HighHz - LowHz) * ramp;

            var sample = (float)(Math.Sin(_phase) * Amplitude);
            _phase += 2 * Math.PI * frequency / sampleRate;
            if (_phase > 2 * Math.PI) _phase -= 2 * Math.PI;
            _elapsed += 1.0 / sampleRate;

            for (var c = 0; c < channels; c++) buffer[offset + frame * channels + c] = sample;
        }
        return frames * channels;
    }
}
