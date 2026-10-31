using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Yowl.Core.Security;
using Yowl.Core.Vision;
using Yowl.Windows.Platform;

namespace Yowl.Windows;

/// <summary>
/// <c>Yowl.exe --self-test</c>: checks each Windows-specific piece on the
/// machine it runs on and prints what it found. Changes nothing: no volume is
/// touched, no power setting is written, nothing is locked.
///
/// <c>--camera</c> also opens the camera for three seconds (the light comes on)
/// and saves one photo to the temp folder. <c>--siren</c> plays the siren for
/// two seconds at the current volume.
///
/// The report is printed and also written to %TEMP%\yowl-self-test.txt, so it
/// can be read even when started by double-clicking.
/// </summary>
internal static class SelfTest
{
    public static int Run(string[] args)
    {
        AttachConsole(-1);
        var report = new StringBuilder();
        var failures = 0;

        void Line(string text)
        {
            report.AppendLine(text);
            Console.WriteLine(text);
        }

        void Check(string name, Func<string> body)
        {
            try
            {
                Line($"[ok]   {name}: {body()}");
            }
            catch (Exception e)
            {
                failures++;
                Line($"[FAIL] {name}: {e.GetType().Name}: {e.Message}");
            }
        }

        Line($"Yowl {typeof(SelfTest).Assembly.GetName().Version} self-test");
        Line($"Windows {Environment.OSVersion.Version}, {RuntimeInformation.OSArchitecture}, .NET {Environment.Version}");
        Line("");

        Check("Install", () => AppPackage.IsPackaged
            ? $"Microsoft Store package, data in {AppPackage.DataDirectory}"
            : $"plain exe, data in {AppPackage.DataDirectory}");

        Check("Secret storage (DPAPI)", () =>
        {
            var directory = Path.Combine(Path.GetTempPath(), "yowl-self-test-" + Guid.NewGuid());
            try
            {
                var store = new DpapiSecretStore(directory);
                if (!store.Write("probe", [1, 2, 3])) throw new InvalidOperationException("write failed");
                if (store.Read("probe") is not SecretRead.Found { Value: [1, 2, 3] }) throw new InvalidOperationException("read back differs");
                if (File.ReadAllBytes(Path.Combine(directory, "probe.bin")).AsSpan().IndexOf((byte[])[1, 2, 3]) >= 0)
                    throw new InvalidOperationException("stored unencrypted");
                return "encrypts, decrypts, round-trips";
            }
            finally
            {
                Directory.Delete(directory, recursive: true);
            }
        });

        Check("Power", () =>
        {
            var status = SystemInformation.PowerStatus;
            return $"charger {status.PowerLineStatus}, battery {status.BatteryChargeStatus} {status.BatteryLifePercent:P0}";
        });

        Check("Keep awake", () =>
        {
            var assertion = new ExecutionStateSleepAssertion();
            assertion.Acquire("Yowl self-test");
            assertion.Release();
            return "requested and released";
        });

        Check("Lid", () => new LidActionSuppressor(Path.GetTempPath()).Describe());

        Check("Audio outputs", () =>
        {
            using var audio = new SpeakerAudio();
            return Environment.NewLine + string.Join(Environment.NewLine, audio.Describe().Select(d => "         " + d));
        });

        Check("Camera", () => new WinRtCamera().IsAvailable ? "present" : "none found");

        Check("Motion scoring speed", () =>
        {
            var detector = new EgoMotionDetector();
            var frames = Enumerable.Range(0, 16).Select(i => Scene(i * 3)).ToList();
            detector.Submit(frames[0]);
            var watch = Stopwatch.StartNew();
            foreach (var frame in frames.Skip(1)) detector.Submit(frame);
            var perFrame = watch.Elapsed.TotalMilliseconds / (frames.Count - 1);
            if (perFrame > 60) throw new InvalidOperationException($"{perFrame:F1} ms per frame is too slow for 15 fps");
            return $"{perFrame:F1} ms per frame (15 fps allows 66 ms)";
        });

        if (args.Contains("--camera")) Check("Camera capture", CameraCapture);
        if (args.Contains("--siren")) Check("Siren", () =>
        {
            using var audio = new SpeakerAudio();
            if (!audio.Start()) throw new InvalidOperationException("the siren would not start");
            Thread.Sleep(2000);
            var playing = audio.IsPlaying;
            audio.Stop();
            return playing ? "played for two seconds" : "started, then stopped by itself";
        });

        Line("");
        Line(failures == 0 ? "All checks passed." : $"{failures} check(s) failed.");
        try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "yowl-self-test.txt"), report.ToString()); }
        catch (IOException) { }
        return failures == 0 ? 0 : 1;
    }

    private static string CameraCapture()
    {
        // Frames are posted to a UI thread, so this needs a message loop.
        using var form = new Form();
        _ = form.Handle;
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        UiThread.Capture();

        using var camera = new WinRtCamera();
        camera.SetRetainsStills(true);
        var frames = 0;
        camera.Start(_ => frames++);
        var until = DateTime.UtcNow.AddSeconds(3);
        while (DateTime.UtcNow < until)
        {
            Application.DoEvents();
            Thread.Sleep(10);
        }
        var still = camera.CaptureStill();
        camera.Stop();
        if (frames == 0) throw new InvalidOperationException("the camera opened but sent no frames");
        var path = Path.Combine(Path.GetTempPath(), "yowl-self-test.jpg");
        if (still is not null) File.WriteAllBytes(path, still);
        return $"{frames} frames in 3 s" + (still is null ? ", no photo" : $", photo saved to {path}");
    }

    /// <summary>A textured scene shifted by <paramref name="dx"/>, to time the detector.</summary>
    private static GrayscaleFrame Scene(int dx)
    {
        const int width = 320, height = 240;
        var pixels = new byte[width * height];
        var random = new Random(42);
        Array.Fill(pixels, (byte)50);
        for (var i = 0; i < 120; i++)
        {
            int x = random.Next(width) + dx, y = random.Next(height), size = 6 + random.Next(22);
            var gray = (byte)(50 + random.Next(180));
            for (var row = Math.Max(0, y); row < Math.Min(height, y + size); row++)
            for (var col = Math.Max(0, x); col < Math.Min(width, x + size); col++)
                pixels[row * width + col] = gray;
        }
        return new GrayscaleFrame(width, height, pixels);
    }

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int processId);
}
