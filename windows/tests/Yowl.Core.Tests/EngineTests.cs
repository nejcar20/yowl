using Yowl.Core.Engine;
using Yowl.Core.Responses;
using Yowl.Core.Tests.Support;

namespace Yowl.Core.Tests;

public class ReducerTests
{
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly TriggerId Power = TriggerId.Power;

    [Fact]
    public void ArmingFromDisarmedGoesToArmed() =>
        Assert.Equal(AlarmState.Armed, AlarmReducer.Reduce(AlarmState.Disarmed, AlarmEvent.Arm, Now));

    [Fact]
    public void ATriggerWithNoGraceFiresImmediately() =>
        Assert.Equal(new AlarmState.Firing(Power),
                     AlarmReducer.Reduce(AlarmState.Armed, new AlarmEvent.Triggered(Power, TimeSpan.Zero), Now));

    [Fact]
    public void ATriggerWithGraceStartsTheCountdown() =>
        Assert.Equal(new AlarmState.Grace(Now.AddSeconds(10), Power),
                     AlarmReducer.Reduce(AlarmState.Armed, new AlarmEvent.Triggered(Power, TimeSpan.FromSeconds(10)), Now));

    [Fact]
    public void GraceExpiryFires() =>
        Assert.Equal(new AlarmState.Firing(Power),
                     AlarmReducer.Reduce(new AlarmState.Grace(Now, Power), AlarmEvent.GraceExpired, Now));

    [Fact]
    public void DisarmWinsFromEveryState()
    {
        foreach (var state in new[] { AlarmState.Armed, new AlarmState.Grace(Now, Power), new AlarmState.Firing(Power) })
            Assert.Equal(AlarmState.Disarmed, AlarmReducer.Reduce(state, AlarmEvent.Disarm, Now));
    }

    [Fact]
    public void TriggersWhileDisarmedAreIgnored() =>
        Assert.Equal(AlarmState.Disarmed,
                     AlarmReducer.Reduce(AlarmState.Disarmed, new AlarmEvent.Triggered(Power, TimeSpan.Zero), Now));

    [Fact]
    public void AStaleGraceTimerAfterDisarmIsIgnored() =>
        Assert.Equal(AlarmState.Disarmed, AlarmReducer.Reduce(AlarmState.Disarmed, AlarmEvent.GraceExpired, Now));

    [Fact]
    public void ArmingMidAlarmDoesNotSilenceIt() =>
        Assert.Equal(new AlarmState.Firing(Power), AlarmReducer.Reduce(new AlarmState.Firing(Power), AlarmEvent.Arm, Now));
}

public class AlarmEngineTests
{
    private readonly TestClock _clock = new();
    private readonly InMemoryPasscodes _passcodes = new();
    private readonly FakeSleepAssertion _sleep = new();

    public AlarmEngineTests() => _passcodes.SetPasscode("1234");

    private AlarmEngine Engine(IEnumerable<ITrigger> triggers, params IResponse[] responses) =>
        new(triggers, responses, _clock, _passcodes, _sleep);

    [Fact]
    public void ArmingWithoutAPasscodeOrScreenLockIsRefused()
    {
        var passcodes = new InMemoryPasscodes();
        var engine = new AlarmEngine([new StubTrigger("t")], [], _clock, passcodes, _sleep);
        var refusal = Assert.Throws<ArmRefusedException>(engine.Arm);
        Assert.Equal(ArmRefusal.NoPasscodeSet, refusal.Reason);
    }

    [Fact]
    public void TheScreenLockStandsInForAPasscode()
    {
        var engine = new AlarmEngine([new StubTrigger("t")], [new ScreenLockResponse(new FakeLocker())],
                                     _clock, new InMemoryPasscodes(), _sleep);
        engine.Arm();
        Assert.Equal(AlarmState.Armed, engine.State);
    }

    [Fact]
    public void ArmingWithNothingAbleToFireIsRefusedWithNoSideEffects()
    {
        var engine = Engine([new StubTrigger("power", canFire: false)]);
        var refusal = Assert.Throws<ArmRefusedException>(engine.Arm);
        Assert.Equal(ArmRefusal.NoArmableTrigger, refusal.Reason);
        Assert.Equal(AlarmState.Disarmed, engine.State);
        Assert.False(_sleep.Held);
    }

    [Fact]
    public void ADisabledTriggerDoesNotCountAsProtection()
    {
        var engine = Engine([new StubTrigger("t") { IsEnabled = false }]);
        Assert.Equal(ArmRefusal.NoArmableTrigger, Assert.Throws<ArmRefusedException>(engine.Arm).Reason);
    }

    [Fact]
    public void WhenNoTriggerStartsTheArmIsUndone()
    {
        var engine = Engine([new StubTrigger("motion") { FailStart = true }]);
        Assert.Equal(ArmRefusal.NoTriggerStarted, Assert.Throws<ArmRefusedException>(engine.Arm).Reason);
        Assert.Equal(AlarmState.Disarmed, engine.State);
        Assert.False(_sleep.Held);
    }

    [Fact]
    public void ATriggerThatFailsWhileAnotherStartsIsReported()
    {
        var engine = Engine([new StubTrigger("power"), new StubTrigger("motion") { FailStart = true }]);
        engine.Arm();
        Assert.Equal(AlarmState.Armed, engine.State);
        Assert.Equal(["motion"], engine.FailedTriggers);
    }

    [Fact]
    public void ARefusedSleepAssertionWarnsButStillArms()
    {
        _sleep.Fail = true;
        var engine = Engine([new StubTrigger("t")]);
        engine.Arm();
        Assert.Equal(AlarmState.Armed, engine.State);
        Assert.True(engine.SleepAssertionFailed);
    }

    [Fact]
    public async Task AFiredTriggerRunsEveryActiveResponse()
    {
        var trigger = new StubTrigger("power");
        var on = new StubResponse("a");
        var off = new StubResponse("b") { IsEnabled = false };
        var engine = Engine([trigger], on, off);
        engine.Arm();
        trigger.Fire();
        await engine.PendingFire;
        Assert.Single(on.Fired);
        Assert.Empty(off.Fired);
        Assert.Equal(new AlarmState.Firing(trigger.Id), engine.State);
    }

    [Fact]
    public async Task GraceDelaysTheResponsesUntilItRunsOut()
    {
        var trigger = new StubTrigger("power") { Grace = TimeSpan.FromSeconds(10) };
        var siren = new StubResponse("siren");
        var engine = Engine([trigger], siren);
        engine.Arm();
        trigger.Fire();
        Assert.IsType<AlarmState.Grace>(engine.State);
        _clock.Advance(TimeSpan.FromSeconds(9));
        Assert.Empty(siren.Fired);
        _clock.Advance(TimeSpan.FromSeconds(1));
        await engine.PendingFire;
        Assert.Single(siren.Fired);
    }

    [Fact]
    public void DisarmingDuringGraceCancelsTheSiren()
    {
        var trigger = new StubTrigger("power") { Grace = TimeSpan.FromSeconds(10) };
        var siren = new StubResponse("siren");
        var engine = Engine([trigger], siren);
        engine.Arm();
        trigger.Fire();
        Assert.True(engine.Disarm("1234"));
        _clock.Advance(TimeSpan.FromSeconds(30));
        Assert.Empty(siren.Fired);
        Assert.Equal(AlarmState.Disarmed, engine.State);
    }

    [Fact]
    public void AWrongPasscodeDoesNotDisarm()
    {
        var trigger = new StubTrigger("power");
        var engine = Engine([trigger]);
        engine.Arm();
        trigger.Fire();
        Assert.False(engine.Disarm("0000"));
        Assert.True(engine.State.IsFiring);
    }

    [Fact]
    public void DisarmingStopsTriggersResetsResponsesAndReleasesSleep()
    {
        var trigger = new StubTrigger("power");
        var siren = new StubResponse("siren");
        var engine = Engine([trigger], siren);
        engine.Arm();
        Assert.True(_sleep.Held);
        trigger.Fire();
        engine.Disarm("1234");
        Assert.False(trigger.IsRunning);
        Assert.Equal(1, siren.ResetCount);
        Assert.False(_sleep.Held);
    }

    [Fact]
    public void AnUnlockDisarmsOnlyWhenTheScreenLockWillFire()
    {
        var lockResponse = new ScreenLockResponse(new FakeLocker()) { IsEnabled = false };
        var trigger = new StubTrigger("power");
        var engine = Engine([trigger], lockResponse);
        engine.Arm();
        trigger.Fire();
        Assert.False(engine.DisarmByScreenUnlock());
        Assert.True(engine.State.IsFiring);

        lockResponse.IsEnabled = true;
        Assert.True(engine.DisarmByScreenUnlock());
        Assert.Equal(AlarmState.Disarmed, engine.State);
    }

    [Fact]
    public async Task WakingWhileStillFiringStartsTheResponsesAgain()
    {
        var trigger = new StubTrigger("power");
        var siren = new StubResponse("siren");
        var engine = Engine([trigger], siren);
        engine.Arm();
        trigger.Fire();
        await engine.PendingFire;
        engine.ResumeAfterWake();
        await engine.PendingFire;
        Assert.Equal(2, siren.Fired.Count);
    }

    [Fact]
    public void WakingAfterADisarmStaysSilent()
    {
        var trigger = new StubTrigger("power");
        var siren = new StubResponse("siren");
        var engine = Engine([trigger], siren);
        engine.Arm();
        engine.Disarm("1234");
        engine.ResumeAfterWake();
        Assert.Empty(siren.Fired);
    }

    [Fact]
    public void UnavailableTriggersAreDroppedAtConstruction()
    {
        var missing = new StubTrigger("motion", available: false);
        var engine = Engine([missing]);
        Assert.Equal(ArmRefusal.NoArmableTrigger, Assert.Throws<ArmRefusedException>(engine.Arm).Reason);
    }

    /// <summary>
    /// A disarm landing while an earlier response is still awaiting must stop
    /// the later ones; a siren started after the reset would be unstoppable.
    /// </summary>
    [Fact]
    public async Task ADisarmMidFireStopsTheRemainingResponses()
    {
        var trigger = new StubTrigger("power");
        var gate = new TaskCompletionSource();
        var slow = new GatedResponse("slow", gate.Task);
        var later = new StubResponse("later");
        var engine = Engine([trigger], slow, later);
        engine.Arm();
        trigger.Fire();
        engine.Disarm("1234");
        gate.SetResult();
        await engine.PendingFire;
        Assert.Empty(later.Fired);
    }

    private sealed class GatedResponse(string id, Task gate) : IResponse
    {
        public string Identifier => id;
        public bool IsAvailable => true;
        public bool IsEnabled { get; set; } = true;
        public Task FireAsync(AlarmContext context) => gate;
        public Task ResetAsync() => Task.CompletedTask;
    }
}

public class ProtectionStatusTests
{
    [Fact]
    public void AnEnabledTriggerThatCanFireIsProtected() =>
        Assert.Null(ProtectionStatus.From([new StubTrigger("power")]).Warning);

    [Fact]
    public void NoEnabledTriggerIsReportedAsNothingWatching()
    {
        var status = ProtectionStatus.From([new StubTrigger("power") { IsEnabled = false }]);
        Assert.IsType<ProtectionStatus.NothingEnabled>(status);
        Assert.Contains("Nothing is watching", status.Warning);
    }

    [Fact]
    public void AnUnpluggedChargerSaysToPlugItIn()
    {
        var status = ProtectionStatus.From([new StubTrigger("power", canFire: false)]);
        Assert.StartsWith("Plug the charger in", status.Warning);
    }

    [Fact]
    public void ASwitchedOffTriggerIsNotBlamed()
    {
        var status = ProtectionStatus.From([
            new StubTrigger("power") { IsEnabled = false, CanFireNow = false },
            new StubTrigger("other", canFire: false),
        ]);
        var blocked = Assert.IsType<ProtectionStatus.NothingCanFireNow>(status).Blocked;
        Assert.DoesNotContain(TriggerId.Power, blocked);
    }
}
