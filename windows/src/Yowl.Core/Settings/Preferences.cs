using System.Text.Json;
using Yowl.Core.Security;

namespace Yowl.Core.Settings;

/// <summary>
/// User preferences. A separate axis from <c>ICapability.IsAvailable</c>: that
/// answers "can this run here?", this answers "does the user want it on?".
/// </summary>
public interface IPreferenceStore
{
    /// <summary>
    /// Most features default on: a user who never opens settings gets the most
    /// protection. Motion, photographs and alerts pass false, because they hold
    /// the camera open or send data off the machine.
    /// </summary>
    bool IsEnabled(string identifier, bool defaultValue = true);
    void SetEnabled(string identifier, bool enabled);
    TimeSpan Grace { get; set; }
    TimeSpan LidHold { get; set; }
    double MotionThreshold { get; set; }
}

/// <summary>The firing threshold, and the sensitivity slider that sets it.</summary>
public static class MotionSensitivity
{
    // From measurement on the Mac: a 3 px camera move scores ~0.009, a 12 px
    // move ~0.037, and sensor noise in a dark room ~0.0014. Below 0.001 fires
    // on noise; above 0.05 only a large deliberate movement registers.
    public const double Minimum = 0.001;
    public const double Maximum = 0.05;
    public const double DefaultValue = 0.005;

    public static double Clamp(double value) => Math.Clamp(value, Minimum, Maximum);

    /// <summary>
    /// More sensitive means a lower bar. Logarithmic, because the useful values
    /// bunch at the low end and a linear slider would spend most of its travel
    /// where nothing changes.
    /// </summary>
    public static double ThresholdFor(double sensitivity)
    {
        var clamped = Math.Clamp(sensitivity, 0, 1);
        double logMin = Math.Log(Minimum), logMax = Math.Log(Maximum);
        return Math.Exp(logMax + (logMin - logMax) * clamped);
    }

    public static double SensitivityFor(double threshold)
    {
        double logMin = Math.Log(Minimum), logMax = Math.Log(Maximum);
        return Math.Clamp((logMax - Math.Log(Clamp(threshold))) / (logMax - logMin), 0, 1);
    }
}

public static class GraceLimits
{
    public static readonly TimeSpan Minimum = TimeSpan.Zero;
    public static readonly TimeSpan Maximum = TimeSpan.FromSeconds(60);

    /// <summary>
    /// Zero by default: the siren fires the instant the charger goes, leaving
    /// no window for a thief to find the app and quit it.
    /// </summary>
    public static readonly TimeSpan DefaultValue = TimeSpan.Zero;

    public static TimeSpan Clamp(TimeSpan value) =>
        value < Minimum ? Minimum : value > Maximum ? Maximum : value;
}

/// <summary>Preferences in a JSON file. Values are clamped on read as well as write.</summary>
public sealed class JsonPreferenceStore : IPreferenceStore
{
    private sealed class Data
    {
        public Dictionary<string, bool> Enabled { get; set; } = [];
        public double? GraceSeconds { get; set; }
        public double? LidHoldSeconds { get; set; }
        public double? MotionThreshold { get; set; }
    }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    private readonly string _path;
    private readonly Data _data;

    public JsonPreferenceStore(string path)
    {
        _path = path;
        _data = Load(path);
    }

    private static Data Load(string path)
    {
        try
        {
            return File.Exists(path)
                ? JsonSerializer.Deserialize<Data>(File.ReadAllText(path)) ?? new Data()
                : new Data();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // A damaged file falls back to defaults, which are the protective
            // ones, rather than stopping the app from starting.
            return new Data();
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_data, Options));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Kept in memory for this session; nothing else to be done.
        }
    }

    public bool IsEnabled(string identifier, bool defaultValue = true) =>
        _data.Enabled.TryGetValue(identifier, out var value) ? value : defaultValue;

    public void SetEnabled(string identifier, bool enabled)
    {
        _data.Enabled[identifier] = enabled;
        Save();
    }

    public TimeSpan Grace
    {
        get => _data.GraceSeconds is { } s ? GraceLimits.Clamp(TimeSpan.FromSeconds(s)) : GraceLimits.DefaultValue;
        set { _data.GraceSeconds = GraceLimits.Clamp(value).TotalSeconds; Save(); }
    }

    public TimeSpan LidHold
    {
        // Clamped on read too: a hand-edited file must not be able to keep a
        // bagged laptop awake for an hour.
        get => _data.LidHoldSeconds is { } s ? LidSleepLimits.Clamp(TimeSpan.FromSeconds(s)) : LidSleepLimits.DefaultHold;
        set { _data.LidHoldSeconds = LidSleepLimits.Clamp(value).TotalSeconds; Save(); }
    }

    public double MotionThreshold
    {
        get => _data.MotionThreshold is { } t ? MotionSensitivity.Clamp(t) : MotionSensitivity.DefaultValue;
        set { _data.MotionThreshold = MotionSensitivity.Clamp(value); Save(); }
    }
}
