using Microsoft.Win32;
using Yowl.Core.Alerts;
using Yowl.Core.App;
using Yowl.Core.Evidence;
using Yowl.Core.Security;
using Yowl.Core.Settings;
using Yowl.Windows.Platform;
using Yowl.Windows.UI;

namespace Yowl.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--self-test"))
        {
            ApplicationConfiguration.Initialize();
            return SelfTest.Run(args);
        }

        // One Yowl per user: two would fight over the camera and the speakers.
        using var instance = new Mutex(initiallyOwned: true, @"Local\com.jernejkocica.yowl", out var first);
        if (!first) return 0;

        ApplicationConfiguration.Initialize();
        Application.SetColorMode(SystemColorMode.System);
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        UiThread.Capture();

        var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Yowl");
        var secrets = new DpapiSecretStore(Path.Combine(dataDirectory, "Secrets"));
        var audio = new SpeakerAudio();
        var camera = new WinRtCamera();

        // The only place the concrete Windows types are named.
        var controller = new YowlController(new YowlDependencies(
            Passcodes: new PasscodeStore(secrets),
            Preferences: new JsonPreferenceStore(Path.Combine(dataDirectory, "settings.json")),
            Topics: new TopicStore(secrets),
            Camera: camera,
            Power: new WindowsPowerMonitor(),
            Audio: audio,
            Siren: audio,
            ScreenLocker: new WindowsScreenLocker(),
            SleepAssertion: new ExecutionStateSleepAssertion(),
            Evidence: new FileEvidenceStore(Path.Combine(dataDirectory, "Evidence")),
            Http: new HttpClientPoster(),
            Clock: new UiClock(),
            Clipboard: new WindowsClipboard(),
            Shell: new ExplorerShell(),
            ScreenUnlocks: new SessionUnlockObserver(),
            SystemSleep: new SystemSleepObserver(),
            LidSleep: new LidActionSuppressor(dataDirectory),
            LoginItem: new RunKeyLoginItem()));

        // Every way out puts the user's audio and lid setting back. SessionEnded,
        // not SessionEnding: Ending fires while Windows is still asking, so a
        // thief clicking Restart and the restart then being cancelled would
        // leave the alarm silenced and still showing ALARM. A kill from Task
        // Manager reaches neither, which is what the lid watchdog and the
        // startup recovery are for.
        Application.ApplicationExit += (_, _) => controller.Shutdown();
        SystemEvents.SessionEnded += (_, _) => controller.Shutdown();

        using var context = new TrayContext(controller);
        Application.Run(context);

        camera.Dispose();
        audio.Dispose();
        return 0;
    }
}
