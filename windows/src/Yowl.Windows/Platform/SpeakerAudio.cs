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
    private volatile bool _stoppedUnderneath;

    /// <summary>
    /// The built-in speakers if they can be told apart, else the default output.
    /// Re-resolved on every call: devices come and go, and a stale handle to an
    /// unplugged one plays to nothing.
    /// </summary>
    private MMDevice? Target()
    {
        try
        {
            var active = _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active).ToList();
            var speakers = active.Where(IsSpeakers).ToList();
            var defaultDevice = _enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
                ? _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
                : null;
            // The default, if it is a speaker; otherwise the first speaker;
            // otherwise whatever is the default. Making some noise somewhere
            // beats choosing nothing.
            return speakers.FirstOrDefault(d => d.ID == defaultDevice?.ID)
                   ?? speakers.FirstOrDefault()
                   ?? defaultDevice;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            return null;
        }
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
    public IEnumerable<string> Describe()
    {
        var target = Target();
        foreach (var device in _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            var mark = device.ID == target?.ID ? "->" : "  ";
            yield return $"{mark} {device.FriendlyName} [{(IsSpeakers(device) ? "speakers" : "other")}]"
                       + $" volume {device.AudioEndpointVolume.MasterVolumeLevelScalar:P0}"
                       + (device.AudioEndpointVolume.Mute ? " muted" : "");
        }
        if (target is null) yield return "   no output found";
    }

    // MARK: - IAudioOutputControl

    public AudioOutputState? CurrentState()
    {
        var device = Target();
        if (device is null) return null;
        var volume = device.AudioEndpointVolume;
        return new AudioOutputState(device.ID, volume.MasterVolumeLevelScalar, volume.Mute);
    }

    public void ForceMaxVolume()
    {
        var device = Target() ?? throw new InvalidOperationException("No audio output.");
        var volume = device.AudioEndpointVolume;
        volume.Mute = false;
        volume.MasterVolumeLevelScalar = 1f;
    }

    public void Restore(AudioOutputState state)
    {
        try
        {
            var volume = _enumerator.GetDevice(state.DeviceId).AudioEndpointVolume;
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
            output.PlaybackStopped += (_, _) => _stoppedUnderneath = true;
            output.Init(siren);
            _stoppedUnderneath = false;
            output.Play();
            _output = output;
            return true;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException
                                       or ArgumentException or NotSupportedException)
        {
            Stop();
            return false;
        }
    }

    public void Stop()
    {
        var output = _output;
        _output = null;
        if (output is null) return;
        try { output.Stop(); } catch (System.Runtime.InteropServices.COMException) { }
        output.Dispose();
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
