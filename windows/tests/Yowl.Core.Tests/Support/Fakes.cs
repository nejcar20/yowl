using Yowl.Core.Alerts;
using Yowl.Core.Engine;
using Yowl.Core.Evidence;
using Yowl.Core.Responses;
using Yowl.Core.Security;
using Yowl.Core.Settings;
using Yowl.Core.Triggers;
using Yowl.Core.Vision;

namespace Yowl.Core.Tests.Support;

/// <summary>A clock that only moves when told to, running due work in order.</summary>
public sealed class TestClock : IAlarmClock
{
    private sealed class Work(DateTimeOffset due, Action body, long order) : IScheduledWork
    {
        public DateTimeOffset Due { get; } = due;
        public Action Body { get; } = body;
        public long Order { get; } = order;
        public bool Cancelled { get; private set; }
        public void Cancel() => Cancelled = true;
    }

    private readonly List<Work> _pending = [];
    private long _sequence;

    public DateTimeOffset Now { get; private set; } = new(2026, 10, 16, 12, 0, 0, TimeSpan.Zero);

    public IScheduledWork Schedule(TimeSpan after, Action body)
    {
        var work = new Work(Now + after, body, _sequence++);
        _pending.Add(work);
        return work;
    }

    public int PendingCount => _pending.Count(w => !w.Cancelled);

    public void Advance(TimeSpan by)
    {
        var target = Now + by;
        while (true)
        {
            var next = _pending.Where(w => !w.Cancelled && w.Due <= target)
                               .OrderBy(w => w.Due).ThenBy(w => w.Order).FirstOrDefault();
            if (next is null) break;
            _pending.Remove(next);
            Now = next.Due;
            next.Body();
        }
        _pending.RemoveAll(w => w.Cancelled);
        Now = target;
    }
}

public sealed class FakePowerMonitor(bool onAc = true) : IPowerSourceMonitor
{
    private Action<bool>? _onChange;
    public bool IsOnAcPower { get; private set; } = onAc;
    public bool IsMonitoring => _onChange is not null;
    public void Start(Action<bool> onChange) => _onChange = onChange;
    public void Stop() => _onChange = null;

    public void Simulate(bool onAc)
    {
        IsOnAcPower = onAc;
        _onChange?.Invoke(onAc);
    }
}

public sealed class FakeCamera(bool available = true) : ICamera
{
    private Action<GrayscaleFrame>? _onFrame;
    public bool IsAvailable { get; set; } = available;
    public bool AccessGranted { get; set; } = true;
    public bool FailStart { get; set; }
    public bool IsRunning { get; private set; }
    public int StartCount { get; private set; }
    public bool IsHighRate { get; private set; }
    public bool RetainsStills { get; private set; }
    public byte[]? Still { get; set; } = [0xFF, 0xD8, 0xFF, 0xE0];
    public List<TimestampedStill> Buffered { get; set; } = [];
    public int CaptureCount { get; private set; }

    public void SetHighRate(bool high) => IsHighRate = high;
    public void SetRetainsStills(bool retain) => RetainsStills = retain;
    public Task<bool> RequestAccessAsync() => Task.FromResult(AccessGranted);

    public void Start(Action<GrayscaleFrame> onFrame)
    {
        if (!IsAvailable || FailStart) throw new FrameSourceException("no camera");
        StartCount++;
        _onFrame = onFrame;
        IsRunning = true;
    }

    public void Stop()
    {
        IsRunning = false;
        _onFrame = null;
    }

    public void Emit(GrayscaleFrame frame) => _onFrame?.Invoke(frame);

    public byte[]? CaptureStill()
    {
        CaptureCount++;
        return Still;
    }

    public IReadOnlyList<TimestampedStill> BufferedStills() => Buffered;
    public void ClearBufferedStills() => Buffered = [];
}

public sealed class FakeSiren : ISirenPlayer
{
    public bool IsPlaying { get; private set; }
    public int StartCount { get; private set; }
    public int StopCount { get; private set; }
    public bool FailStart { get; set; }

    public bool Start()
    {
        StartCount++;
        if (FailStart) return false;
        IsPlaying = true;
        return true;
    }

    public void Stop()
    {
        StopCount++;
        IsPlaying = false;
    }

    /// <summary>The audio stream stopped underneath the app, as a device change does.</summary>
    public void SimulateStreamLost() => IsPlaying = false;
}

public sealed class FakeAudio : IAudioOutputControl
{
    public AudioOutputState State { get; set; } = new("speakers", 0.3f, true);
    public bool FailForce { get; set; }
    public int ForceCount { get; private set; }
    public List<AudioOutputState> Restored { get; } = [];

    public AudioOutputState? CurrentState() => State;

    public void ForceMaxVolume()
    {
        ForceCount++;
        if (FailForce) throw new InvalidOperationException("write failed");
        State = State with { Volume = 1, Muted = false };
    }

    public void Restore(AudioOutputState state)
    {
        Restored.Add(state);
        State = state;
    }
}

public sealed class FakeLocker(bool available = true) : IScreenLocker
{
    public bool IsAvailable { get; } = available;
    public int LockCount { get; private set; }
    public void Lock() => LockCount++;
}

public sealed class FakeSleepAssertion : ISleepAssertion
{
    public bool Fail { get; set; }
    public bool Held { get; private set; }
    public void Acquire(string reason)
    {
        if (Fail) throw new InvalidOperationException("refused");
        Held = true;
    }
    public void Release() => Held = false;
}

public sealed class InMemoryPasscodes : IPasscodeStore
{
    private readonly PasscodeStore _inner = new(new InMemorySecretStore());
    public bool HasPasscode => _inner.HasPasscode;
    public void SetPasscode(string passcode) => _inner.SetPasscode(passcode);
    public bool Verify(string passcode) => _inner.Verify(passcode);
}

public sealed class InMemoryPreferences : IPreferenceStore
{
    private readonly Dictionary<string, bool> _enabled = [];
    private TimeSpan _grace = GraceLimits.DefaultValue;
    private TimeSpan _lidHold = LidSleepLimits.DefaultHold;
    private double _threshold = MotionSensitivity.DefaultValue;

    public bool IsEnabled(string identifier, bool defaultValue = true) =>
        _enabled.TryGetValue(identifier, out var v) ? v : defaultValue;
    public void SetEnabled(string identifier, bool enabled) => _enabled[identifier] = enabled;
    public TimeSpan Grace { get => _grace; set => _grace = GraceLimits.Clamp(value); }
    public TimeSpan LidHold { get => _lidHold; set => _lidHold = LidSleepLimits.Clamp(value); }
    public double MotionThreshold { get => _threshold; set => _threshold = MotionSensitivity.Clamp(value); }
}

public sealed class InMemoryEvidence : IEvidenceStore
{
    public List<EvidenceItem> Saved { get; } = [];
    public string? Save(EvidenceItem item) { Saved.Add(item); return $"memory://{Saved.Count}"; }
    public IReadOnlyList<string> AllItems() => Saved.Select((_, i) => $"memory://{i}").ToList();
    public IReadOnlyList<byte[]> RecentJpegs(int limit) => Saved.AsEnumerable().Reverse().Take(limit).Select(i => i.Jpeg).ToList();
    public string DirectoryPath => Path.GetTempPath();
}

public sealed class FakeHttp : IHttpPoster
{
    public List<HttpRequest> Requests { get; } = [];
    public bool Fail { get; set; }
    public Task SendAsync(HttpRequest request)
    {
        lock (Requests) Requests.Add(request);
        if (Fail) throw new AlertTransportException("down");
        return Task.CompletedTask;
    }
}

public sealed class FakeTopics : ITopicStore
{
    public TopicRead Stored { get; set; } = new TopicRead.NotFound();
    public string? MintResult { get; set; } = "minted-topic";
    public bool ResetResult { get; set; } = true;
    public int MintCount { get; private set; }

    public TopicRead Read() => Stored;

    public string? TopicCreatingIfNeeded()
    {
        if (Stored is TopicRead.Found found) return found.Topic;
        MintCount++;
        if (MintResult is { } minted) Stored = new TopicRead.Found(minted);
        return MintResult;
    }

    public bool Reset()
    {
        if (ResetResult) Stored = new TopicRead.NotFound();
        return ResetResult;
    }
}

public sealed class FakeUnlocks : IScreenUnlockObserver
{
    private Action? _onUnlock;
    public void Start(Action onUnlock) => _onUnlock = onUnlock;
    public void Stop() => _onUnlock = null;
    public void SimulateUnlock() => _onUnlock?.Invoke();
}

public sealed class FakeSystemSleep : ISystemSleepObserver
{
    private Action? _willSleep, _didWake;
    public void Start(Action onWillSleep, Action onDidWake) { _willSleep = onWillSleep; _didWake = onDidWake; }
    public void Stop() { _willSleep = null; _didWake = null; }
    public void SimulateSleep() => _willSleep?.Invoke();
    public void SimulateWake() => _didWake?.Invoke();
}

public sealed class FakeLidSleep(bool available = true) : ILidSleepSuppressor
{
    public bool IsAvailable { get; } = available;
    public List<TimeSpan> Holds { get; } = [];
    public int ReleaseCount { get; private set; }
    public int RecoverCount { get; private set; }
    public bool IsHeld { get; private set; }

    public Task<bool> HoldAsync(TimeSpan duration)
    {
        Holds.Add(duration);
        IsHeld = true;
        return Task.FromResult(true);
    }

    public Task ReleaseAsync()
    {
        ReleaseCount++;
        IsHeld = false;
        return Task.CompletedTask;
    }

    public void RecoverFromCrash() => RecoverCount++;
}

public sealed class FakeLoginItem : ILoginItem
{
    public bool IsEnabled { get; private set; }
    public bool Fail { get; set; }
    public void SetEnabled(bool enabled)
    {
        if (Fail) throw new UnauthorizedAccessException();
        IsEnabled = enabled;
    }
}

public sealed class FakeClipboard : IClipboard
{
    public string? Last { get; private set; }
    public bool Fail { get; set; }
    public void WriteSecret(string text)
    {
        if (Fail) throw new InvalidOperationException("The clipboard is in use by another app. Try again.");
        Last = text;
    }
}

public sealed class FakeShell : IShell
{
    public string? Opened { get; private set; }
    public void OpenFolder(string path) => Opened = path;
}

/// <summary>A trigger whose every property a test can set.</summary>
public sealed class StubTrigger(string id, bool available = true, bool canFire = true) : ITrigger
{
    private Action<TriggerId>? _onFire;
    public TriggerId Id { get; } = new(id);
    public string Identifier => Id.Value;
    public bool IsAvailable { get; } = available;
    public bool IsEnabled { get; set; } = true;
    public TimeSpan Grace { get; set; }
    public bool CanFireNow { get; set; } = canFire;
    public bool FailStart { get; set; }
    public bool IsRunning => _onFire is not null;
    public int StopCount { get; private set; }

    public void Start(Action<TriggerId> onFire)
    {
        if (FailStart) throw new InvalidOperationException("would not start");
        _onFire = onFire;
    }

    public void Stop()
    {
        StopCount++;
        _onFire = null;
    }

    public void Fire() => _onFire?.Invoke(Id);
}

/// <summary>A response that records what it was asked to do.</summary>
public sealed class StubResponse(string id, bool available = true) : IResponse
{
    public string Identifier { get; } = id;
    public bool IsAvailable { get; } = available;
    public bool IsEnabled { get; set; } = true;
    public List<AlarmContext> Fired { get; } = [];
    public int ResetCount { get; private set; }

    public Task FireAsync(AlarmContext context) { Fired.Add(context); return Task.CompletedTask; }
    public Task ResetAsync() { ResetCount++; return Task.CompletedTask; }
}
