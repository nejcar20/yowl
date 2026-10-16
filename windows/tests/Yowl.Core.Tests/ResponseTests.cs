using Yowl.Core.Engine;
using Yowl.Core.Evidence;
using Yowl.Core.Responses;
using Yowl.Core.Tests.Support;
using Yowl.Core.Triggers;
using Yowl.Core.Vision;

namespace Yowl.Core.Tests;

public class PowerTriggerTests
{
    [Fact]
    public void UnpluggingTheChargerFires()
    {
        var monitor = new FakePowerMonitor(onAc: true);
        var trigger = new PowerTrigger(monitor, TimeSpan.Zero);
        TriggerId? fired = null;
        trigger.Start(id => fired = id);
        monitor.Simulate(onAc: false);
        Assert.Equal(TriggerId.Power, fired);
    }

    /// <summary>Windows reports status changes for battery level too; only the AC-to-battery edge counts.</summary>
    [Fact]
    public void RepeatedBatteryReportsFireOnlyOnce()
    {
        var monitor = new FakePowerMonitor(onAc: true);
        var trigger = new PowerTrigger(monitor, TimeSpan.Zero);
        var count = 0;
        trigger.Start(_ => count++);
        monitor.Simulate(onAc: true);
        monitor.Simulate(onAc: false);
        monitor.Simulate(onAc: false);
        Assert.Equal(1, count);
    }

    [Fact]
    public void ItCannotFireWhenAlreadyOnBattery() =>
        Assert.False(new PowerTrigger(new FakePowerMonitor(onAc: false), TimeSpan.Zero).CanFireNow);

    [Fact]
    public void StoppingStopsListening()
    {
        var monitor = new FakePowerMonitor();
        var trigger = new PowerTrigger(monitor, TimeSpan.Zero);
        var fired = false;
        trigger.Start(_ => fired = true);
        trigger.Stop();
        Assert.False(monitor.IsMonitoring);
        monitor.Simulate(onAc: false);
        Assert.False(fired);
    }
}

public class SirenResponseTests
{
    private readonly TestClock _clock = new();
    private readonly FakeSiren _player = new();
    private readonly FakeAudio _audio = new();
    private static readonly AlarmContext Context = new(TriggerId.Power, DateTimeOffset.Now);

    private SirenResponse Siren() => new(_player, _audio, _clock);

    [Fact]
    public async Task FiringForcesTheVolumeAndStartsTheSiren()
    {
        var siren = Siren();
        await siren.FireAsync(Context);
        Assert.True(_player.IsPlaying);
        Assert.Equal(1f, _audio.State.Volume);
        Assert.False(_audio.State.Muted);
        Assert.True(siren.IsSounding);
    }

    [Fact]
    public async Task ResetRestoresTheUsersOriginalSettings()
    {
        var original = _audio.State;
        var siren = Siren();
        await siren.FireAsync(Context);
        await siren.FireAsync(Context); // a repeat must not save the forced state
        await siren.ResetAsync();
        Assert.Equal([original], _audio.Restored);
        Assert.False(_player.IsPlaying);
    }

    /// <summary>A thief who presses mute gets one second of quiet.</summary>
    [Fact]
    public async Task MutingIsUndoneEverySecond()
    {
        var siren = Siren();
        await siren.FireAsync(Context);
        _audio.State = _audio.State with { Muted = true, Volume = 0 };
        _clock.Advance(TimeSpan.FromSeconds(1));
        Assert.False(_audio.State.Muted);
        Assert.Equal(1f, _audio.State.Volume);
    }

    [Fact]
    public async Task ALostAudioStreamIsRestarted()
    {
        await Siren().FireAsync(Context);
        _player.SimulateStreamLost();
        _clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(_player.IsPlaying);
    }

    [Fact]
    public async Task NoVolumeHoldSurvivesAReset()
    {
        var siren = Siren();
        await siren.FireAsync(Context);
        await siren.ResetAsync();
        var forces = _audio.ForceCount;
        _clock.Advance(TimeSpan.FromSeconds(5));
        Assert.Equal(forces, _audio.ForceCount);
        Assert.Equal(0, _clock.PendingCount);
    }

    [Fact]
    public async Task AFailedVolumeWriteIsNotReportedAsSounding()
    {
        _audio.FailForce = true;
        var siren = Siren();
        await siren.FireAsync(Context);
        Assert.True(_player.IsPlaying, "fail toward noise: the siren still starts");
        Assert.False(siren.IsSounding);
    }
}

public class SnapshotResponseTests
{
    private readonly TestClock _clock = new();
    private readonly FakeCamera _camera = new();
    private readonly InMemoryEvidence _store = new();
    private static readonly AlarmContext Context = new(TriggerId.Power, DateTimeOffset.Now);

    [Fact]
    public async Task ItSavesTheRunUpThenThreeShotsTwoSecondsApart()
    {
        _camera.Buffered = [new TimestampedStill([1], _clock.Now.AddSeconds(-2)), new TimestampedStill([2], _clock.Now.AddSeconds(-1))];
        var snapshot = new SnapshotResponse(_camera, _store, _clock) { IsEnabled = true };
        await snapshot.FireAsync(Context);
        Assert.Equal(3, _store.Saved.Count);
        _clock.Advance(TimeSpan.FromSeconds(4));
        Assert.Equal(5, _store.Saved.Count);
        Assert.Empty(_camera.Buffered);
    }

    /// <summary>Each shot carries its own time, so no two share a filename.</summary>
    [Fact]
    public async Task EveryShotHasItsOwnTimestamp()
    {
        var snapshot = new SnapshotResponse(_camera, _store, _clock) { IsEnabled = true };
        await snapshot.FireAsync(Context);
        _clock.Advance(TimeSpan.FromSeconds(4));
        Assert.Equal(3, _store.Saved.Select(i => i.CapturedAt).Distinct().Count());
    }

    [Fact]
    public async Task DisarmingStopsThePendingShots()
    {
        var snapshot = new SnapshotResponse(_camera, _store, _clock) { IsEnabled = true };
        await snapshot.FireAsync(Context);
        await snapshot.ResetAsync();
        _clock.Advance(TimeSpan.FromSeconds(10));
        Assert.Single(_store.Saved);
    }

    [Fact]
    public async Task NoImageMeansNothingSavedAndNoFailure()
    {
        _camera.Still = null;
        var snapshot = new SnapshotResponse(_camera, _store, _clock) { IsEnabled = true };
        await snapshot.FireAsync(Context);
        Assert.Empty(_store.Saved);
    }
}

public class ScreenLockResponseTests
{
    [Fact]
    public async Task FiringLocksTheScreen()
    {
        var locker = new FakeLocker();
        await new ScreenLockResponse(locker).FireAsync(new AlarmContext(TriggerId.Power, DateTimeOffset.Now));
        Assert.Equal(1, locker.LockCount);
    }
}

public class FileEvidenceStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "yowl-tests-" + Guid.NewGuid());

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public void ItKeepsOnlyTheNewest()
    {
        var store = new FileEvidenceStore(_directory, keepingMostRecent: 3);
        var start = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        for (var i = 0; i < 5; i++) store.Save(new EvidenceItem([(byte)i], start.AddSeconds(i), "power"));
        Assert.Equal(3, store.AllItems().Count);
        Assert.Equal([[4], [3]], store.RecentJpegs(2));
    }

    /// <summary>Two shots in the same second must not overwrite each other.</summary>
    [Fact]
    public void ShotsMillisecondsApartAreBothKept()
    {
        var store = new FileEvidenceStore(_directory);
        var start = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        store.Save(new EvidenceItem([1], start, "power"));
        store.Save(new EvidenceItem([2], start.AddMilliseconds(400), "power"));
        Assert.Equal(2, store.AllItems().Count);
    }
}
