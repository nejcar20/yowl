using System.Text;
using Yowl.Core.Alerts;
using Yowl.Core.Engine;
using Yowl.Core.Evidence;
using Yowl.Core.Security;
using Yowl.Core.Settings;
using Yowl.Core.Tests.Support;

namespace Yowl.Core.Tests;

public class NtfyTransportTests
{
    [Fact]
    public async Task ItPostsTheMessageThenEachPhotograph()
    {
        var http = new FakeHttp();
        var transport = new NtfyTransport("abc123", http);
        await transport.SendAsync(new AlertPayload("Yowl", "The charger was unplugged.", AlertUrgency.Critical,
                                                   DateTimeOffset.Now, [[1], [2]]));
        Assert.Equal(3, http.Requests.Count);
        Assert.Equal("https://ntfy.sh/abc123", http.Requests[0].Url.ToString());
        Assert.Equal("POST", http.Requests[0].Method);
        Assert.Equal("5", http.Requests[0].Headers["Priority"]);
        Assert.Equal("The charger was unplugged.", Encoding.UTF8.GetString(http.Requests[0].Body!));
        Assert.Equal("PUT", http.Requests[1].Method);
        Assert.Equal("alarm-2.jpg", http.Requests[2].Headers["Filename"]);
    }

    [Fact]
    public async Task NoTopicMeansNotConfigured()
    {
        var transport = new NtfyTransport("", new FakeHttp());
        Assert.False(transport.IsConfigured);
        await Assert.ThrowsAsync<AlertTransportException>(() =>
            transport.SendAsync(new AlertPayload("t", "b", AlertUrgency.Normal, DateTimeOffset.Now, [])));
    }

    /// <summary>The topic is the only access control, so it must be long, random and anonymous.</summary>
    [Fact]
    public void GeneratedTopicsAre128RandomBitsWithNoPrefix()
    {
        var a = NtfyTransport.GenerateTopic();
        Assert.Matches("^[0-9a-f]{32}$", a);
        Assert.NotEqual(a, NtfyTransport.GenerateTopic());
    }
}

public class AlertResponseTests
{
    private readonly FakeHttp _http = new();
    private readonly InMemoryEvidence _evidence = new();

    [Fact]
    public async Task AnAlarmSendsACriticalMessageNamingTheTrigger()
    {
        var alert = new AlertResponse(new NtfyTransport("t", _http), _evidence) { IsEnabled = true };
        await alert.FireAsync(new AlarmContext(TriggerId.Motion, DateTimeOffset.Now));
        await alert.LastSend;
        Assert.Equal("The laptop was moved.", Encoding.UTF8.GetString(_http.Requests[0].Body!));
    }

    /// <summary>Turning photographs off must stop old ones being sent, as the privacy policy promises.</summary>
    [Fact]
    public async Task PhotographsAreAttachedOnlyWhenPhotographsAreOn()
    {
        _evidence.Save(new EvidenceItem([9], DateTimeOffset.Now, "power"));
        var alert = new AlertResponse(new NtfyTransport("t", _http), _evidence) { IsEnabled = true };
        await alert.FireAsync(new AlarmContext(TriggerId.Power, DateTimeOffset.Now));
        await alert.LastSend;
        Assert.Single(_http.Requests);

        alert.IncludesPhotographs = true;
        await alert.FireAsync(new AlarmContext(TriggerId.Power, DateTimeOffset.Now));
        await alert.LastSend;
        Assert.Equal(3, _http.Requests.Count);
    }

    [Fact]
    public async Task ANetworkFailureNeverReachesTheEngine()
    {
        _http.Fail = true;
        var alert = new AlertResponse(new NtfyTransport("t", _http), _evidence) { IsEnabled = true };
        await alert.FireAsync(new AlarmContext(TriggerId.Power, DateTimeOffset.Now));
        await alert.LastSend;
        Assert.False(await alert.SendTestAsync());
    }
}

public class TopicStoreTests
{
    [Fact]
    public void ATopicIsCreatedOnceAndThenReused()
    {
        var store = new TopicStore(new InMemorySecretStore());
        var first = store.TopicCreatingIfNeeded();
        Assert.NotNull(first);
        Assert.Equal(first, store.TopicCreatingIfNeeded());
        Assert.Equal(new TopicRead.Found(first!), store.Read());
    }

    /// <summary>An unreadable topic may be a working link; replacing it strands the phone.</summary>
    [Fact]
    public void AnUnreadableTopicIsNeverReplaced()
    {
        var secrets = new InMemorySecretStore();
        secrets.Write("ntfy-topic", "live"u8.ToArray());
        secrets.Unreadable.Add("ntfy-topic");
        var store = new TopicStore(secrets);
        Assert.IsType<TopicRead.Unreadable>(store.Read());
        Assert.Null(store.TopicCreatingIfNeeded());
        secrets.Unreadable.Clear();
        Assert.Equal(new TopicRead.Found("live"), store.Read());
    }

    [Fact]
    public void ATopicThatCannotBeStoredIsNotHandedOut()
    {
        var store = new TopicStore(new InMemorySecretStore { FailWrites = true });
        Assert.Null(store.TopicCreatingIfNeeded());
    }

    [Theory]
    [InlineData(false, "found", typeof(AlertStartupDecision.LeaveOff))]
    [InlineData(true, "found", typeof(AlertStartupDecision.Use))]
    [InlineData(true, "missing", typeof(AlertStartupDecision.Mint))]
    [InlineData(true, "unreadable", typeof(AlertStartupDecision.PauseUnreadable))]
    public void StartupDecisions(bool enabled, string read, Type expected)
    {
        TopicRead topic = read switch
        {
            "found" => new TopicRead.Found("t"),
            "missing" => new TopicRead.NotFound(),
            _ => new TopicRead.Unreadable(),
        };
        Assert.IsType(expected, AlertStartupDecision.Decide(enabled, topic));
    }
}

public class PasscodeTests
{
    [Fact]
    public void ASetPasscodeVerifiesAndOthersDoNot()
    {
        var store = new PasscodeStore(new InMemorySecretStore());
        Assert.False(store.HasPasscode);
        store.SetPasscode("4711");
        Assert.True(store.HasPasscode);
        Assert.True(store.Verify("4711"));
        Assert.False(store.Verify("4712"));
        Assert.False(store.Verify(""));
    }

    [Fact]
    public void AnEmptyPasscodeIsRefused() =>
        Assert.Throws<PasscodeException>(() => new PasscodeStore(new InMemorySecretStore()).SetPasscode(""));

    /// <summary>Only a salted hash is stored, never the passcode.</summary>
    [Fact]
    public void ThePasscodeIsNotStoredInPlaintext()
    {
        var secrets = new InMemorySecretStore();
        new PasscodeStore(secrets).SetPasscode("4711");
        var stored = Assert.IsType<SecretRead.Found>(secrets.Read("disarm-passcode")).Value;
        Assert.Equal(PasscodeHasher.SaltBytes + PasscodeHasher.HashBytes, stored.Length);
        Assert.DoesNotContain("4711", Encoding.UTF8.GetString(stored));
    }

    [Fact]
    public void AFailedWriteKeepsTheOldPasscode()
    {
        var secrets = new InMemorySecretStore();
        var store = new PasscodeStore(secrets);
        store.SetPasscode("1111");
        secrets.FailWrites = true;
        Assert.Throws<PasscodeException>(() => store.SetPasscode("2222"));
        Assert.True(store.Verify("1111"));
    }
}

public class PreferencesTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"yowl-prefs-{Guid.NewGuid()}.json");

    public void Dispose() => File.Delete(_path);

    [Fact]
    public void ValuesSurviveARestart()
    {
        var prefs = new JsonPreferenceStore(_path);
        prefs.SetEnabled("motion", true);
        prefs.Grace = TimeSpan.FromSeconds(10);
        prefs.MotionThreshold = 0.01;

        var reopened = new JsonPreferenceStore(_path);
        Assert.True(reopened.IsEnabled("motion", false));
        Assert.Equal(TimeSpan.FromSeconds(10), reopened.Grace);
        Assert.Equal(0.01, reopened.MotionThreshold);
    }

    [Fact]
    public void DefaultsAreTheProtectiveOnes()
    {
        var prefs = new JsonPreferenceStore(_path);
        Assert.True(prefs.IsEnabled("power"));
        Assert.Equal(TimeSpan.Zero, prefs.Grace);
        Assert.Equal(LidSleepLimits.DefaultHold, prefs.LidHold);
    }

    /// <summary>A hand-edited file must not keep a bagged laptop awake for an hour.</summary>
    [Fact]
    public void HandEditedValuesAreClampedOnRead()
    {
        File.WriteAllText(_path, """{"GraceSeconds": 9999, "LidHoldSeconds": 3600, "MotionThreshold": 0}""");
        var prefs = new JsonPreferenceStore(_path);
        Assert.Equal(GraceLimits.Maximum, prefs.Grace);
        Assert.Equal(TimeSpan.FromMinutes(5), prefs.LidHold);
        Assert.Equal(MotionSensitivity.Minimum, prefs.MotionThreshold);
    }

    [Fact]
    public void ADamagedFileFallsBackToDefaults()
    {
        File.WriteAllText(_path, "{ not json");
        Assert.True(new JsonPreferenceStore(_path).IsEnabled("power"));
    }

    [Fact]
    public void SensitivityAndThresholdRoundTrip()
    {
        foreach (var s in new[] { 0.0, 0.25, 0.5, 1.0 })
            Assert.Equal(s, MotionSensitivity.SensitivityFor(MotionSensitivity.ThresholdFor(s)), 6);
        Assert.True(MotionSensitivity.ThresholdFor(1) < MotionSensitivity.ThresholdFor(0), "more sensitive is a lower bar");
    }
}
