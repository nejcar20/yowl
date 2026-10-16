using Yowl.Core.Engine;
using Yowl.Core.Tests.Support;
using Yowl.Core.Triggers;
using Yowl.Core.Vision;

namespace Yowl.Core.Tests;

public class RegistrationTests
{
    [Theory]
    [InlineData(3, 0)]
    [InlineData(12, 0)]
    [InlineData(0, 7)]
    [InlineData(-25, 10)]
    [InlineData(80, -30)]
    public void AMovedSceneIsFoundAtItsShift(int dx, int dy)
    {
        var (foundX, foundY) = TranslationalRegistration.Estimate(SyntheticFrames.Scene(), SyntheticFrames.Scene(dx, dy));
        // current(x) = previous(x - dx) for a scene drawn dx further along.
        Assert.Equal((-dx, -dy), (foundX, foundY));
    }

    [Fact]
    public void IdenticalFramesHaveNoShift() =>
        Assert.Equal((0, 0), TranslationalRegistration.Estimate(SyntheticFrames.Scene(), SyntheticFrames.Scene()));
}

/// <summary>
/// Held to the same scenarios as the Mac detector. The Mac's numbers came from
/// Apple's Vision framework; these come from Yowl's own registration, so the
/// behaviour, not the internals, is what is shared.
/// </summary>
public class EgoMotionDetectorTests
{
    private readonly EgoMotionDetector _detector = new();

    [Fact]
    public void AMovedCameraScoresPositive()
    {
        var score = _detector.Score(SyntheticFrames.Scene(), SyntheticFrames.Scene(dx: 12))!.Value;
        Assert.True(score.Value > 0.01, $"value {score.Value}");
        Assert.True(score.Explained > 0.8, $"explained {score.Explained}");
    }

    /// <summary>
    /// The test that matters in a café. A detector that fires on this is
    /// useless where the app is meant to be used.
    /// </summary>
    [Fact]
    public void APersonWalkingPastDoesNotScoreAsMovement()
    {
        var score = _detector.Score(SyntheticFrames.Scene(occluderAt: 40), SyntheticFrames.Scene(occluderAt: 150))!.Value;
        Assert.True(score.Value <= 0, $"value {score.Value}, shift {score.Shift}, explained {score.Explained}");
    }

    [Fact]
    public void AGlobalLightingChangeIsNotExplainedByAnyShift()
    {
        var score = _detector.Score(SyntheticFrames.Scene(), SyntheticFrames.Scene(brightness: 0.18))!.Value;
        Assert.True(Math.Abs(score.Value) < 0.001, $"value {score.Value}");
    }

    [Fact]
    public void IdenticalFramesScoreZero()
    {
        var frame = SyntheticFrames.Scene();
        Assert.True(Math.Abs(_detector.Score(frame, frame)!.Value.Value) < 0.001);
    }

    /// <summary>A 3 px nudge must clear the firing threshold, not merely score above zero.</summary>
    [Fact]
    public void ASmallCameraMovementClearsTheFiringThreshold()
    {
        var score = _detector.Score(SyntheticFrames.Scene(), SyntheticFrames.Scene(dx: 3))!.Value;
        Assert.True(score.Value > _detector.Threshold, $"value {score.Value}");
    }

    /// <summary>A snatch moves the view a long way between frames; it must fire, not be dismissed.</summary>
    [Fact]
    public void FastMotionStillScores()
    {
        var score = _detector.Score(SyntheticFrames.Scene(), SyntheticFrames.Scene(dx: 100, dy: 20))!.Value;
        Assert.True(score.Value > _detector.Threshold, $"value {score.Value}");
    }

    [Fact]
    public void ADarkNoisySceneDoesNotFire()
    {
        var detector = new EgoMotionDetector(hitsRequired: 3, window: 3);
        for (ulong seed = 1; seed <= 10; seed++)
            Assert.False(detector.Submit(SyntheticFrames.Flat(seed: seed)));
    }

    [Fact]
    public void OneMovedFrameDoesNotFire()
    {
        var detector = new EgoMotionDetector(0.005, 3, 3);
        Assert.False(detector.Submit(SyntheticFrames.Scene()));
        Assert.False(detector.Submit(SyntheticFrames.Scene(dx: 12)));
    }

    [Fact]
    public void ThreeConsecutiveMovedFramesFire()
    {
        var detector = new EgoMotionDetector(0.005, 3, 3);
        detector.Submit(SyntheticFrames.Scene());
        Assert.False(detector.Submit(SyntheticFrames.Scene(dx: 12)));
        Assert.False(detector.Submit(SyntheticFrames.Scene(dx: 24)));
        Assert.True(detector.Submit(SyntheticFrames.Scene(dx: 36)));
    }

    /// <summary>A real grab is jerky: one still frame in the middle must not reset everything.</summary>
    [Fact]
    public void AJerkyGrabWithOnePauseStillFires()
    {
        var detector = new EgoMotionDetector();
        detector.Submit(SyntheticFrames.Scene());
        detector.Submit(SyntheticFrames.Scene(dx: 12));
        detector.Submit(SyntheticFrames.Scene(dx: 12));
        detector.Submit(SyntheticFrames.Scene(dx: 24));
        Assert.True(detector.Submit(SyntheticFrames.Scene(dx: 36)));
    }

    [Fact]
    public void PeopleWalkingPastNeverFireHoweverManyFrames()
    {
        var detector = new EgoMotionDetector();
        for (var x = 0; x <= 250; x += 25)
            Assert.False(detector.Submit(SyntheticFrames.Scene(occluderAt: x)), $"fired with the occluder at {x}");
    }

    [Fact]
    public void ResetClearsTheRunAndTheLastScore()
    {
        var detector = new EgoMotionDetector(0.005, 3, 3);
        detector.Submit(SyntheticFrames.Scene());
        detector.Submit(SyntheticFrames.Scene(dx: 12));
        detector.Submit(SyntheticFrames.Scene(dx: 24));
        detector.Reset();
        Assert.Null(detector.LastScore);
        Assert.False(detector.Submit(SyntheticFrames.Scene(dx: 36)));
    }

    [Fact]
    public void MismatchedFramesAreUnscorable()
    {
        var small = new GrayscaleFrame(4, 4, new byte[16]);
        Assert.Null(_detector.Score(SyntheticFrames.Scene(), small));
    }
}

public class MotionTriggerTests
{
    private readonly FakeCamera _camera = new();

    private MotionTrigger Trigger() => new(_camera, new EgoMotionDetector(0.005, 3, 3), TimeSpan.Zero) { IsEnabled = true };

    [Fact]
    public void SustainedCameraMotionFires()
    {
        var trigger = Trigger();
        TriggerId? fired = null;
        trigger.Start(id => fired = id);
        foreach (var dx in new[] { 0, 12, 24, 36 }) _camera.Emit(SyntheticFrames.Scene(dx: dx));
        Assert.Equal(TriggerId.Motion, fired);
    }

    [Fact]
    public void StoppingReleasesTheCameraAndPreventsFiring()
    {
        var trigger = Trigger();
        var fired = false;
        trigger.Start(_ => fired = true);
        trigger.Stop();
        Assert.False(_camera.IsRunning);
        foreach (var dx in new[] { 0, 12, 24, 36 }) _camera.Emit(SyntheticFrames.Scene(dx: dx));
        Assert.False(fired);
    }

    [Fact]
    public void AMachineWithNoCameraHasNoMotionTrigger() =>
        Assert.False(new MotionTrigger(new FakeCamera(available: false), new EgoMotionDetector(), TimeSpan.Zero).IsAvailable);

    [Fact]
    public void AvailabilityIsCapturedAtConstruction()
    {
        var camera = new FakeCamera(available: false);
        var trigger = new MotionTrigger(camera, new EgoMotionDetector(), TimeSpan.Zero);
        camera.IsAvailable = true;
        Assert.False(trigger.IsAvailable);
    }

    [Fact]
    public void CalibrationDeliversScoresAndRaisesTheRate()
    {
        var trigger = Trigger();
        var scores = new List<MotionScore>();
        trigger.StartCalibration(scores.Add);
        Assert.True(_camera.IsHighRate);
        _camera.Emit(SyntheticFrames.Scene());
        _camera.Emit(SyntheticFrames.Scene(dx: 12));
        Assert.Single(scores);
        trigger.StopCalibration();
        Assert.False(_camera.IsHighRate);
        Assert.False(_camera.IsRunning);
    }

    [Fact]
    public void CalibrationIsRefusedWhileArmed()
    {
        var trigger = Trigger();
        trigger.Start(_ => { });
        Assert.Throws<InvalidOperationException>(() => trigger.StartCalibration(_ => { }));
    }
}

public class DetectorCostTests
{
    /// <summary>
    /// The camera delivers 15 frames a second for as long as the alarm is armed.
    /// Scoring has to stay a small fraction of one core, or an armed laptop
    /// runs hot in a bag. Generous bound: CI machines are slow.
    /// </summary>
    [Fact]
    public void ScoringAFrameStaysWellUnderTheFrameInterval()
    {
        var detector = new EgoMotionDetector();
        var frames = Enumerable.Range(0, 30).Select(i => SyntheticFrames.Scene(dx: i % 7, occluderAt: i * 8)).ToList();
        detector.Submit(frames[0]);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        foreach (var frame in frames.Skip(1)) detector.Submit(frame);
        var perFrame = watch.Elapsed.TotalMilliseconds / (frames.Count - 1);
        Assert.True(perFrame < 30, $"{perFrame:F1} ms per frame");
    }
}
