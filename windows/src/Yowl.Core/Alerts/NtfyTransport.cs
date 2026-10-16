using System.Security.Cryptography;
using System.Text;
using Yowl.Core.Security;

namespace Yowl.Core.Alerts;

/// <summary>
/// Pushes an alert to a phone via ntfy.
///
/// The topic name is the access control: on ntfy.sh anyone who knows a topic
/// can read it, so it is 128 random bits per install. Pushed photographs are
/// not storage either; ntfy.sh deletes them after a few hours. The durable copy
/// is the one on this machine.
/// </summary>
public sealed class NtfyTransport(string topic, IHttpPoster http, Uri? server = null) : IAlertTransport
{
    public static readonly Uri DefaultServer = new("https://ntfy.sh/");

    private readonly Uri _server = server ?? DefaultServer;

    public bool IsConfigured => !string.IsNullOrEmpty(topic);

    /// <summary>
    /// 128 bits, hex, no identifying prefix: a name like "yowl-..." would tell
    /// anyone who saw it which app it belongs to and what the photos are of.
    /// </summary>
    public static string GenerateTopic() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    public async Task SendAsync(AlertPayload payload)
    {
        if (!IsConfigured) throw new AlertTransportException("No alert link is set up.");
        var endpoint = new Uri(_server, topic);

        await http.SendAsync(new HttpRequest(endpoint, "POST", new Dictionary<string, string>
        {
            ["Title"] = payload.Title,
            ["Priority"] = Priority(payload.Urgency),
            ["Tags"] = "rotating_light",
        }, Encoding.UTF8.GetBytes(payload.Body)));

        // One request per photograph: ntfy takes one attachment per message.
        for (var i = 0; i < payload.Images.Count; i++)
        {
            await http.SendAsync(new HttpRequest(endpoint, "PUT", new Dictionary<string, string>
            {
                ["Filename"] = $"alarm-{i + 1}.jpg",
            }, payload.Images[i]));
        }
    }

    private static string Priority(AlertUrgency urgency) => urgency switch
    {
        AlertUrgency.Normal => "3",
        AlertUrgency.High => "4",
        _ => "5",
    };
}

/// <summary>
/// Where the ntfy topic lives. It is a secret (anyone holding it can read the
/// photographs), so it sits beside the passcode, not in the preferences file.
/// </summary>
public interface ITopicStore
{
    TopicRead Read();

    /// <summary>
    /// The existing topic, or a newly created one. Null rather than a topic it
    /// could not store: one that the next launch would not remember leaves the
    /// phone subscribed to a dead link while the UI shows everything working.
    /// </summary>
    string? TopicCreatingIfNeeded();

    /// <summary>Forgets the topic. False if it could not be removed.</summary>
    bool Reset();
}

public abstract record TopicRead
{
    public sealed record Found(string Topic) : TopicRead;
    public sealed record NotFound : TopicRead;
    public sealed record Unreadable : TopicRead;

    public string Value => this is Found f ? f.Topic : "";
}

public sealed class TopicStore(ISecretStore secrets) : ITopicStore
{
    private const string Name = "ntfy-topic";

    public TopicRead Read() => secrets.Read(Name) switch
    {
        SecretRead.Found { Value.Length: > 0 } found => new TopicRead.Found(Encoding.UTF8.GetString(found.Value)),
        SecretRead.NotFound => new TopicRead.NotFound(),
        _ => new TopicRead.Unreadable(),
    };

    public string? TopicCreatingIfNeeded()
    {
        switch (Read())
        {
            case TopicRead.Found found:
                return found.Topic;
            case TopicRead.Unreadable:
                // Never overwrite what could not be read: it may be a working
                // link the phone is subscribed to.
                return null;
        }
        var generated = NtfyTransport.GenerateTopic();
        return secrets.Write(Name, Encoding.UTF8.GetBytes(generated)) ? generated : null;
    }

    public bool Reset() => secrets.Delete(Name);
}

/// <summary>
/// What to do about phone alerts at launch. A pure function because the rule is
/// dangerous: treating "could not read" as "not there" replaces a working link,
/// and a login item starts exactly when storage is least likely to be readable.
/// </summary>
public abstract record AlertStartupDecision
{
    public sealed record Use(string Topic) : AlertStartupDecision;
    public sealed record Mint : AlertStartupDecision;
    /// <summary>Leave the stored preference alone and try again later. Never deletes.</summary>
    public sealed record PauseUnreadable : AlertStartupDecision;
    public sealed record LeaveOff : AlertStartupDecision;

    public static AlertStartupDecision Decide(bool preferenceEnabled, TopicRead read)
    {
        if (!preferenceEnabled) return new LeaveOff();
        return read switch
        {
            TopicRead.Found found => new Use(found.Topic),
            TopicRead.NotFound => new Mint(),
            _ => new PauseUnreadable(),
        };
    }
}
