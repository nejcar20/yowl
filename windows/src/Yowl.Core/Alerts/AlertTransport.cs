using System.Net.Http.Headers;

namespace Yowl.Core.Alerts;

public enum AlertUrgency { Normal, High, Critical }

/// <summary>What happened, in terms no provider owns.</summary>
public sealed record AlertPayload(string Title, string Body, AlertUrgency Urgency,
                                  DateTimeOffset OccurredAt, IReadOnlyList<byte[]> Images);

public sealed class AlertTransportException(string message) : Exception(message);

public interface IAlertTransport
{
    bool IsConfigured { get; }

    /// <exception cref="AlertTransportException">Not configured, network failure, or rejected.</exception>
    Task SendAsync(AlertPayload payload);
}

public sealed record HttpRequest(Uri Url, string Method, IReadOnlyDictionary<string, string> Headers, byte[]? Body);

public interface IHttpPoster
{
    /// <exception cref="AlertTransportException">Network failure or a non-2xx status.</exception>
    Task SendAsync(HttpRequest request);
}

/// <summary>The only place in the app that touches the network.</summary>
public sealed class HttpClientPoster : IHttpPoster
{
    // Never let a notification outlive the alarm it is about.
    private readonly HttpClient _client = new() { Timeout = TimeSpan.FromSeconds(15) };

    public async Task SendAsync(HttpRequest request)
    {
        using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url);
        if (request.Body is { } body)
        {
            message.Content = new ByteArrayContent(body);
            message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        }
        foreach (var (key, value) in request.Headers)
            message.Headers.TryAddWithoutValidation(key, value);

        HttpResponseMessage response;
        try
        {
            response = await _client.SendAsync(message);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            throw new AlertTransportException("Could not reach the alert server.");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
                throw new AlertTransportException($"The alert server refused the message ({(int)response.StatusCode}).");
        }
    }
}
