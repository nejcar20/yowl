using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Devices.Enumeration;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Yowl.Core.Vision;

namespace Yowl.Windows.Platform;

/// <summary>
/// The built-in camera, through Windows.Media.Capture. Feeds the motion
/// detector downscaled grayscale frames and keeps recent full-resolution frames
/// for photographs. The camera light is on for as long as this runs; that is
/// enforced by the hardware, which is why motion is opt-in.
///
/// Frames arrive on a worker thread. Only finished GrayscaleFrame values cross
/// to the UI thread; everything the worker touches is guarded by <see cref="_lock"/>.
/// </summary>
internal sealed class WinRtCamera : ICamera, IDisposable
{
    private const int TargetWidth = 320, TargetHeight = 240;
    /// <summary>Ten seconds of run-up at one frame a second covers someone walking up.</summary>
    private const int BufferedStillCount = 10;
    private static readonly TimeSpan BufferInterval = TimeSpan.FromSeconds(1);

    private readonly TimeSpan _normalInterval = TimeSpan.FromSeconds(1.0 / 15);
    private readonly TimeSpan _calibrationInterval = TimeSpan.FromSeconds(1.0 / 20);
    private readonly object _lock = new();

    private MediaCapture? _capture;
    private MediaFrameReader? _reader;
    private Action<GrayscaleFrame>? _onFrame;
    private volatile int _session;

    /// <summary>
    /// Restarts a camera that failed or went quiet. Another app taking it, a
    /// USB camera unplugged, a driver that stops after sleep: each would
    /// otherwise leave "Armed" over a dead camera. Runs on the UI thread.
    /// </summary>
    private System.Windows.Forms.Timer? _watchdog;
    private DateTime _lastFrameUtc;
    private volatile bool _failed;
    private static readonly TimeSpan StallLimit = TimeSpan.FromSeconds(4);
    /// <summary>Reused for frames that are not kept, so 15 fps does not allocate 15 buffers a second.</summary>
    private byte[]? _scratch;

    // Guarded by _lock.
    private bool _highRate;
    private bool _retainStills;
    private DateTime _lastDelivery = DateTime.MinValue;
    private DateTime _lastBuffered = DateTime.MinValue;
    private (byte[] Pixels, int Width, int Height)? _latest;
    private readonly List<TimestampedStill> _buffer = [];

    public WinRtCamera()
    {
        // Hardware only, sampled once. Asked off the UI thread: blocking an STA
        // thread on a WinRT operation can deadlock.
        IsAvailable = Task.Run(async () =>
        {
            try { return (await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture)).Count > 0; }
            catch (Exception) { return false; }
        }).GetAwaiter().GetResult();
    }

    public bool IsAvailable { get; }

    public void SetHighRate(bool high)
    {
        lock (_lock) _highRate = high;
    }

    public void SetRetainsStills(bool retain)
    {
        lock (_lock)
        {
            _retainStills = retain;
            if (retain) return;
            // Switching photographs off must not leave a picture of the user in memory.
            _latest = null;
            _buffer.Clear();
        }
    }

    public async Task<bool> RequestAccessAsync()
    {
        if (!IsAvailable) return false;
        if (_capture is not null) return true;
        // Windows prompts, or refuses, on the first initialisation. There is
        // no separate permission query for desktop apps.
        try
        {
            using var probe = new MediaCapture();
            await probe.InitializeAsync(new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = StreamingCaptureMode.Video,
                SharingMode = MediaCaptureSharingMode.SharedReadOnly,
            });
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        catch (Exception)
        {
            // In use or misbehaving, but not refused: let arming report it.
            return true;
        }
    }

    public void Start(Action<GrayscaleFrame> onFrame)
    {
        Stop();
        Open(onFrame);
        _lastFrameUtc = DateTime.UtcNow;
        _watchdog = new System.Windows.Forms.Timer { Interval = 2000 };
        _watchdog.Tick += (_, _) => CheckHealth();
        _watchdog.Start();
    }

    private void CheckHealth()
    {
        var handler = _onFrame;
        if (handler is null) return;
        if (!_failed && DateTime.UtcNow - _lastFrameUtc < StallLimit) return;
        Debug.WriteLine("Yowl: camera failed or stalled; restarting it.");
        CloseCapture();
        try
        {
            Open(handler);
        }
        catch (FrameSourceException)
        {
            // Still gone. Kept as the handler so the next tick tries again.
            _onFrame = handler;
        }
        _lastFrameUtc = DateTime.UtcNow;
    }

    private void Open(Action<GrayscaleFrame> onFrame)
    {
        bool wantsStills;
        lock (_lock) wantsStills = _retainStills;
        _failed = false;
        if (!IsAvailable) throw new FrameSourceException("This PC has no camera.");

        var session = ++_session;
        lock (_lock)
        {
            _lastDelivery = DateTime.MinValue;
            _lastBuffered = DateTime.MinValue;
            _latest = null;
            _buffer.Clear();
        }
        try
        {
            // Blocking, deliberately: the engine needs to know now whether the
            // camera opened, so "Armed" never covers a camera that did not.
            (_capture, _reader) = Task.Run(() => OpenAsync(wantsStills, session)).GetAwaiter().GetResult();
        }
        catch (UnauthorizedAccessException)
        {
            throw new FrameSourceException("Camera access is turned off for desktop apps.");
        }
        catch (Exception e) when (e is not FrameSourceException)
        {
            throw new FrameSourceException("The camera would not start: " + e.Message);
        }
        _onFrame = onFrame;
    }

    private async Task<(MediaCapture, MediaFrameReader)> OpenAsync(bool wantsStills, int session)
    {
        var capture = new MediaCapture();
        capture.Failed += (_, _) => { if (session == _session) _failed = true; };
        try
        {
            try
            {
                await capture.InitializeAsync(Settings(MediaCaptureSharingMode.ExclusiveControl));
            }
            catch (Exception e) when (e is not UnauthorizedAccessException)
            {
                // Another app has the camera. Watching alongside it beats not watching.
                capture.Dispose();
                capture = new MediaCapture();
                capture.Failed += (_, _) => { if (session == _session) _failed = true; };
                await capture.InitializeAsync(Settings(MediaCaptureSharingMode.SharedReadOnly));
            }

            var source = capture.FrameSources.Values.FirstOrDefault(s =>
                             s.Info.SourceKind == MediaFrameSourceKind.Color && s.Info.MediaStreamType == global::Windows.Media.Capture.MediaStreamType.VideoPreview)
                         ?? capture.FrameSources.Values.FirstOrDefault(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
                         ?? throw new FrameSourceException("The camera offers no colour stream.");

            await TrySetFormatAsync(source, wantsStills);

            var reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            reader.FrameArrived += (r, _) => OnFrameArrived(r, session);
            var status = await reader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success)
            {
                reader.Dispose();
                throw new FrameSourceException($"The camera would not start ({status}).");
            }
            return (capture, reader);
        }
        catch
        {
            capture.Dispose();
            throw;
        }

        static MediaCaptureInitializationSettings Settings(MediaCaptureSharingMode mode) => new()
        {
            StreamingCaptureMode = StreamingCaptureMode.Video,
            MemoryPreference = MediaCaptureMemoryPreference.Cpu,
            SharingMode = mode,
        };
    }

    /// <summary>
    /// Motion needs only 320x240, so a small format costs least; a photograph
    /// from one is useless as evidence, so stills ask for up to 1280 wide.
    /// </summary>
    private static async Task TrySetFormatAsync(MediaFrameSource source, bool wantsStills)
    {
        try
        {
            var formats = source.SupportedFormats.Where(f => f.VideoFormat.Width >= TargetWidth).ToList();
            var chosen = wantsStills
                ? formats.Where(f => f.VideoFormat.Width <= 1280).OrderByDescending(f => f.VideoFormat.Width).FirstOrDefault()
                : formats.OrderBy(f => f.VideoFormat.Width).FirstOrDefault();
            if (chosen is not null) await source.SetFormatAsync(chosen);
        }
        catch (Exception)
        {
            // Shared mode cannot change the format, and some drivers refuse;
            // whatever the camera is already doing will do.
        }
    }

    /// <summary>
    /// Runs on a camera worker thread. An exception escaping here would end the
    /// process, alarm and all, so one bad frame is dropped instead.
    /// </summary>
    private void OnFrameArrived(MediaFrameReader reader, int session)
    {
        try
        {
            ProcessFrame(reader, session);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Debug.WriteLine($"Yowl: dropped a camera frame: {e.Message}");
        }
    }

    private void ProcessFrame(MediaFrameReader reader, int session)
    {
        using var frame = reader.TryAcquireLatestFrame();
        var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
        if (bitmap is null) return;

        var now = DateTime.UtcNow;
        bool retain;
        lock (_lock)
        {
            // Pacing lives here rather than in the camera: scoring is the cost,
            // not capture, and this works whatever rate the hardware offers.
            var interval = _highRate ? _calibrationInterval : _normalInterval;
            if (session != _session || now - _lastDelivery < interval) return;
            _lastDelivery = now;
            retain = _retainStills;
        }

        // The reader was asked for BGRA, so conversion is the rare case.
        using var converted = bitmap.BitmapPixelFormat == BitmapPixelFormat.Bgra8
            ? null
            : SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8);
        var bgra = converted ?? bitmap;
        int width = bgra.PixelWidth, height = bgra.PixelHeight;
        var size = width * height * 4;
        // A kept frame needs its own buffer; one only scored can reuse the last.
        var pixels = retain ? new byte[size] : Interlocked.Exchange(ref _scratch, null) is { Length: var n } reused && n == size ? reused : new byte[size];
        bgra.CopyToBuffer(pixels.AsBuffer());

        if (retain)
        {
            byte[]? jpegForBuffer = null;
            bool bufferDue;
            lock (_lock) bufferDue = now - _lastBuffered >= BufferInterval;
            if (bufferDue) jpegForBuffer = Jpeg.Encode(pixels, width, height);
            lock (_lock)
            {
                // Re-checked: switching photographs off during the encode must
                // not leave a photograph of the user behind.
                if (_retainStills && session == _session)
                {
                    _latest = (pixels, width, height);
                    if (jpegForBuffer is not null)
                    {
                        _lastBuffered = now;
                        _buffer.Add(new TimestampedStill(jpegForBuffer, DateTimeOffset.Now));
                        if (_buffer.Count > BufferedStillCount) _buffer.RemoveRange(0, _buffer.Count - BufferedStillCount);
                    }
                }
            }
        }

        var gray = GrayscaleFrame.FromBgra(pixels, width, height, width * 4, TargetWidth, TargetHeight);
        if (!retain) _scratch = pixels;
        UiThread.Post(() =>
        {
            if (session != _session) return;
            _lastFrameUtc = DateTime.UtcNow;
            _onFrame?.Invoke(gray);
        });
    }

    public byte[]? CaptureStill()
    {
        (byte[] Pixels, int Width, int Height)? latest;
        lock (_lock) latest = _latest;
        return latest is { } l ? Jpeg.Encode(l.Pixels, l.Width, l.Height) : null;
    }

    public IReadOnlyList<TimestampedStill> BufferedStills()
    {
        lock (_lock) return [.. _buffer];
    }

    public void ClearBufferedStills()
    {
        lock (_lock) _buffer.Clear();
    }

    public void Stop()
    {
        _watchdog?.Stop();
        _watchdog?.Dispose();
        _watchdog = null;
        CloseCapture();
    }

    private void CloseCapture()
    {
        _session++;
        _onFrame = null;
        var reader = _reader;
        var capture = _capture;
        _reader = null;
        _capture = null;
        if (reader is null && capture is null) return;
        try
        {
            Task.Run(async () =>
            {
                // Disposed whatever StopAsync does: after a device loss it is
                // likely to throw, and skipping the disposal would hold the
                // camera, light on, until the app exits.
                try
                {
                    if (reader is not null) await reader.StopAsync();
                }
                finally
                {
                    reader?.Dispose();
                    capture?.Dispose();
                }
            }).Wait(TimeSpan.FromSeconds(3));
        }
        catch (AggregateException)
        {
            // Disposed above; the stop itself failing changes nothing.
        }
    }

    public void Dispose() => Stop();
}

internal static class Jpeg
{
    private static readonly ImageCodecInfo Encoder =
        ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    public static byte[] Encode(byte[] bgra, int width, int height, long quality = 80)
    {
        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppRgb);
        var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
        try
        {
            for (var y = 0; y < height; y++)
                System.Runtime.InteropServices.Marshal.Copy(bgra, y * width * 4, data.Scan0 + y * data.Stride, width * 4);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
        using var stream = new MemoryStream();
        bitmap.Save(stream, Encoder, parameters);
        return stream.ToArray();
    }
}
