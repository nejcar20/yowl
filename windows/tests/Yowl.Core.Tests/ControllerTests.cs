using Yowl.Core.Alerts;
using Yowl.Core.App;
using Yowl.Core.Engine;
using Yowl.Core.Security;
using Yowl.Core.Tests.Support;

namespace Yowl.Core.Tests;

public class ControllerTests
{
    private readonly TestClock _clock = new();
    private readonly InMemoryPasscodes _passcodes = new();
    private readonly InMemoryPreferences _prefs = new();
    private readonly FakeTopics _topics = new();
    private readonly FakeCamera _camera = new();
    private readonly FakePowerMonitor _power = new(onAc: true);
    private readonly FakeAudio _audio = new();
    private readonly FakeSiren _siren = new();
    private readonly FakeLocker _locker = new();
    private readonly FakeSleepAssertion _sleep = new();
    private readonly InMemoryEvidence _evidence = new();
    private readonly FakeHttp _http = new();
    private readonly FakeClipboard _clipboard = new();
    private readonly FakeShell _shell = new();
    private readonly FakeUnlocks _unlocks = new();
    private readonly FakeSystemSleep _systemSleep = new();
    private readonly FakeLidSleep _lidSleep = new();
    private readonly FakeLoginItem _login = new();

    private YowlController Controller() => new(new YowlDependencies(
        _passcodes, _prefs, _topics, _camera, _power, _audio, _siren, _locker, _sleep, _evidence,
        _http, _clock, _clipboard, _shell, _unlocks, _systemSleep, _lidSleep, _login));

    private YowlController ArmedController()
    {
        _passcodes.SetPasscode("1234");
        var controller = Controller();
        controller.Arm();
        Assert.True(controller.IsArmed, controller.ErrorMessage);
        return controller;
    }

    [Fact]
    public void WithTheScreenLockOnNoPasscodeIsNeeded() =>
        Assert.False(Controller().NeedsPasscodeSetup);

    [Fact]
    public void WithoutTheScreenLockAPasscodeMustBeChosen()
    {
        _prefs.SetEnabled("screen-lock", false);
        Assert.True(Controller().NeedsPasscodeSetup);
    }

    [Fact]
    public void TurningTheScreenLockOffWithNoPasscodeAsksForOne()
    {
        var controller = Controller();
        controller.SetScreenLockEnabled(false);
        Assert.True(controller.NeedsPasscodeSetup);
    }

    [Fact]
    public async Task UnpluggingWhileArmedSoundsTheSirenAndLocksTheScreen()
    {
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        await controller.Engine.PendingFire;
        Assert.True(controller.IsFiring);
        Assert.True(_siren.IsPlaying);
        Assert.True(controller.IsSirenSounding);
        Assert.Equal(1, _locker.LockCount);
    }

    [Fact]
    public async Task TheRightPasscodeSilencesItAndRestoresTheAudio()
    {
        var original = _audio.State;
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        await controller.Engine.PendingFire;
        Assert.True(controller.Disarm("1234"));
        Assert.False(_siren.IsPlaying);
        Assert.Equal(original, _audio.State);
        Assert.False(controller.IsSirenSounding);
    }

    [Fact]
    public void AWrongPasscodeSaysSo()
    {
        var controller = ArmedController();
        Assert.False(controller.Disarm("9999"));
        Assert.Equal("Wrong passcode.", controller.ErrorMessage);
        Assert.True(controller.IsArmed);
    }

    [Fact]
    public async Task UnlockingWindowsDisarms()
    {
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        await controller.Engine.PendingFire;
        _unlocks.SimulateUnlock();
        Assert.False(controller.IsArmed);
    }

    [Fact]
    public void ArmingOnBatterySaysToPlugIn()
    {
        _passcodes.SetPasscode("1234");
        _power.Simulate(onAc: false);
        var controller = Controller();
        controller.Arm();
        Assert.False(controller.IsArmed);
        Assert.StartsWith("Plug the charger in", controller.ErrorMessage);
    }

    /// <summary>Settings are frozen while armed, or a thief could switch the alarm off from the tray.</summary>
    [Fact]
    public async Task SettingsCannotBeChangedWhileArmed()
    {
        var controller = ArmedController();
        controller.SetSirenEnabled(false);
        controller.SetPowerEnabled(false);
        controller.SetScreenLockEnabled(false);
        await controller.SetMotionEnabledAsync(true);
        Assert.True(controller.SirenEnabled);
        Assert.True(controller.PowerEnabled);
        Assert.True(controller.ScreenLockEnabled);
        Assert.False(controller.MotionEnabled);
    }

    [Fact]
    public void SwitchingTheOnlyTriggerOffShowsAWarningBeforeWalkingAway()
    {
        _passcodes.SetPasscode("1234");
        var controller = Controller();
        Assert.Null(controller.ProtectionWarning);
        controller.SetPowerEnabled(false);
        Assert.Contains("Nothing is watching", controller.ProtectionWarning);
        Assert.True(controller.NothingEnabled);
    }

    [Fact]
    public async Task MotionNeedsCameraPermission()
    {
        _camera.AccessGranted = false;
        var controller = Controller();
        await controller.SetMotionEnabledAsync(true);
        Assert.False(controller.MotionEnabled);
        Assert.Contains("camera", controller.SettingsMessage);
    }

    [Fact]
    public async Task MotionIsOffByDefaultAndPersistsOnceOn()
    {
        var controller = Controller();
        Assert.False(controller.MotionEnabled);
        await controller.SetMotionEnabledAsync(true);
        Assert.True(controller.MotionEnabled);
        Assert.True(Controller().MotionEnabled);
    }

    [Fact]
    public async Task PhotographsWithoutMotionStillRunTheCameraWhileArmed()
    {
        _passcodes.SetPasscode("1234");
        var controller = Controller();
        await controller.SetSnapshotEnabledAsync(true);
        controller.Arm();
        Assert.True(_camera.IsRunning);
        Assert.True(_camera.RetainsStills);
        controller.Disarm("1234");
        Assert.False(_camera.IsRunning);
    }

    [Fact]
    public async Task ACameraThatWillNotStartIsAWarningNotAFailure()
    {
        _passcodes.SetPasscode("1234");
        var controller = Controller();
        await controller.SetSnapshotEnabledAsync(true);
        _camera.FailStart = true;
        controller.Arm();
        Assert.True(controller.IsArmed);
        Assert.Contains("no photographs", controller.WarningMessage);
    }

    [Fact]
    public void GraceCountsDownInWholeSeconds()
    {
        _prefs.Grace = TimeSpan.FromSeconds(5);
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        Assert.Equal(5, controller.GraceRemaining);
        _clock.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal(3, controller.GraceRemaining);
        _clock.Advance(TimeSpan.FromSeconds(3));
        Assert.True(controller.IsFiring);
        Assert.Null(controller.GraceRemaining);
    }

    [Fact]
    public async Task TheLidHoldIsTakenOnlyWhileFiringAndOnlyIfEnabled()
    {
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        await controller.Engine.PendingFire;
        Assert.Empty(_lidSleep.Holds);
        controller.Disarm("1234");

        controller.SetLidSleepEnabled(true);
        controller.SetLidHold(TimeSpan.FromMinutes(2));
        _power.Simulate(onAc: true);
        controller.Arm();
        _power.Simulate(onAc: false);
        Assert.Equal([TimeSpan.FromMinutes(2)], _lidSleep.Holds);
        controller.Disarm("1234");
        Assert.False(_lidSleep.IsHeld);
    }

    [Fact]
    public void ACrashedHoldIsRecoveredAtStartup()
    {
        Controller();
        Assert.Equal(1, _lidSleep.RecoverCount);
    }

    [Fact]
    public async Task SleepingMidAlarmSendsANoticeAndWakingResumesTheSiren()
    {
        _topics.Stored = new TopicRead.Found("t");
        _prefs.SetEnabled("alert", true);
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        await controller.Engine.PendingFire;
        _siren.SimulateStreamLost();
        _systemSleep.SimulateSleep();
        _systemSleep.SimulateWake();
        await controller.Engine.PendingFire;
        Assert.True(_siren.IsPlaying);
        await Task.Delay(50);
        lock (_http.Requests)
            Assert.Contains(_http.Requests, r => System.Text.Encoding.UTF8.GetString(r.Body ?? []).Contains("went to sleep"));
    }

    [Fact]
    public void EnablingAlertsCreatesALink()
    {
        var controller = Controller();
        controller.SetAlertEnabled(true);
        Assert.True(controller.AlertEnabled);
        Assert.Equal("https://ntfy.sh/minted-topic", controller.AlertSubscribeUrl);
        controller.CopyAlertLink();
        Assert.Equal("https://ntfy.sh/minted-topic", _clipboard.Last);
    }

    [Fact]
    public void AnUnreadableLinkAtStartupPausesAlertsWithoutReplacingIt()
    {
        _prefs.SetEnabled("alert", true);
        _topics.Stored = new TopicRead.Unreadable();
        var controller = Controller();
        Assert.False(controller.AlertEnabled);
        Assert.Equal(0, _topics.MintCount);
        Assert.Contains("paused", controller.StartupMessage);
        Assert.True(_prefs.IsEnabled("alert", false), "the preference is left alone to retry later");
    }

    [Fact]
    public void AMissingLinkAtStartupIsRecreatedAndTheUserTold()
    {
        _prefs.SetEnabled("alert", true);
        var controller = Controller();
        Assert.True(controller.AlertEnabled);
        Assert.Contains("Pair your phone again", controller.StartupMessage);
    }

    [Fact]
    public void ANewLinkReplacesTheOld()
    {
        _topics.Stored = new TopicRead.Found("old");
        _prefs.SetEnabled("alert", true);
        var controller = Controller();
        _topics.MintResult = "new";
        controller.RegenerateAlertTopic();
        Assert.Equal("new", controller.AlertTopic);
    }

    [Fact]
    public async Task ATestAlertReportsWhetherItArrived()
    {
        var controller = Controller();
        controller.SetAlertEnabled(true);
        await controller.SendTestAlertAsync();
        Assert.StartsWith("Test alert sent", controller.SettingsMessage);
        _http.Fail = true;
        await controller.SendTestAlertAsync();
        Assert.StartsWith("Could not reach", controller.SettingsMessage);
    }

    [Fact]
    public void TurningOffBothResponsesWarnsThatNothingWillHappen()
    {
        _passcodes.SetPasscode("1234");
        var controller = Controller();
        controller.SetSirenEnabled(false);
        controller.SetScreenLockEnabled(false);
        Assert.StartsWith("Nothing will happen", controller.SettingsMessage);
        controller.SetSirenEnabled(true);
        Assert.Null(controller.SettingsMessage);
    }

    [Fact]
    public void ExitingMidAlarmRestoresTheAudio()
    {
        var original = _audio.State;
        var controller = ArmedController();
        _power.Simulate(onAc: false);
        controller.Shutdown();
        Assert.Equal(original, _audio.State);
        Assert.False(_siren.IsPlaying);
    }

    [Fact]
    public void GraceIsClampedAndAppliedToEveryTrigger()
    {
        var controller = Controller();
        controller.SetGrace(TimeSpan.FromMinutes(10));
        Assert.Equal(TimeSpan.FromSeconds(60), controller.Grace);
    }

    [Fact]
    public void ChangesAreAnnounced()
    {
        var controller = Controller();
        var changes = 0;
        controller.Changed += () => changes++;
        controller.SetPowerEnabled(false);
        Assert.True(changes > 0);
    }
}
