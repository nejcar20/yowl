namespace Yowl.Core.Vision;

public sealed class FrameSourceException(string message) : Exception(message);

/// <summary>A JPEG with the moment it was taken.</summary>
public sealed record TimestampedStill(byte[] Jpeg, DateTimeOffset CapturedAt);

/// <summary>The camera, as the motion trigger sees it.</summary>
public interface IFrameSource
{
    /// <summary>Whether this machine has a camera at all. Fixed for the process.</summary>
    bool IsAvailable { get; }

    /// <summary>Raises the frame rate while the user watches the live readout.</summary>
    void SetHighRate(bool high);

    /// <summary>Keeps the latest full-resolution frame and a short run-up, for photographs.</summary>
    void SetRetainsStills(bool retain);

    /// <summary>
    /// Whether the camera may be used. Asked when a feature is switched on, so
    /// the answer is known before anything depends on it.
    /// </summary>
    Task<bool> RequestAccessAsync();

    /// <summary>
    /// Starts delivering frames on the app's thread. Replaces any existing
    /// handler; restarting must never stack handlers.
    /// </summary>
    /// <exception cref="FrameSourceException">The camera would not open.</exception>
    void Start(Action<GrayscaleFrame> onFrame);

    void Stop();
}

/// <summary>Something that can produce photographs from the camera.</summary>
public interface IStillCapture
{
    bool IsAvailable { get; }

    /// <summary>The latest frame as JPEG, or null if there is none.</summary>
    byte[]? CaptureStill();

    /// <summary>
    /// Frames from the seconds before now, oldest first. The most useful
    /// photograph is often from before the alarm: the thief walking up and
    /// looking at the machine, not the back of their head as they leave.
    /// </summary>
    IReadOnlyList<TimestampedStill> BufferedStills();

    /// <summary>Drops the run-up so a second alarm does not re-save the first one's.</summary>
    void ClearBufferedStills();
}

/// <summary>The one camera, shared by motion detection and photographs.</summary>
public interface ICamera : IFrameSource, IStillCapture
{
    new bool IsAvailable { get; }
    bool IFrameSource.IsAvailable => IsAvailable;
    bool IStillCapture.IsAvailable => IsAvailable;
}
