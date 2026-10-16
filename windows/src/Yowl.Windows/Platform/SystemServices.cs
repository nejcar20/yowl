using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Yowl.Core.Responses;
using Yowl.Core.Security;
using Yowl.Core.Triggers;
using Timer = System.Windows.Forms.Timer;

namespace Yowl.Windows.Platform;

internal static partial class NativeMethods
{
    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool LockWorkStation();

    [Flags]
    internal enum ExecutionState : uint
    {
        SystemRequired = 0x00000001,
        Continuous = 0x80000000,
    }

    [LibraryImport("kernel32.dll")]
    internal static partial ExecutionState SetThreadExecutionState(ExecutionState flags);
}

/// <summary>
/// Reports the charger being connected or disconnected. Windows announces power
/// status changes, and a slow poll backs that up: a missed notification would
/// mean a silent theft, and reading the status costs nothing.
/// </summary>
internal sealed class WindowsPowerMonitor : IPowerSourceMonitor, IDisposable
{
    private Action<bool>? _onChange;
    private Timer? _poll;

    /// <summary>"Unknown" counts as on AC: a desktop without a battery should not look unplugged.</summary>
    public bool IsOnAcPower => SystemInformation.PowerStatus.PowerLineStatus != PowerLineStatus.Offline;

    public void Start(Action<bool> onChange)
    {
        Stop();
        _onChange = onChange;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        _poll = new Timer { Interval = 1000 };
        _poll.Tick += (_, _) => _onChange?.Invoke(IsOnAcPower);
        _poll.Start();
    }

    // SystemEvents raises on its own thread unless the app's message loop owns
    // it; the poll timer is on the UI thread either way, so the event only
    // nudges an early check via the UI thread.
    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.StatusChange) UiThread.Post(() => _onChange?.Invoke(IsOnAcPower));
    }

    public void Stop()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _poll?.Stop();
        _poll?.Dispose();
        _poll = null;
        _onChange = null;
    }

    public void Dispose() => Stop();
}

internal sealed class WindowsScreenLocker : IScreenLocker
{
    public bool IsAvailable => true;
    public void Lock() => NativeMethods.LockWorkStation();
}

/// <summary>The user unlocking their session, which is what authenticates a disarm by unlock.</summary>
internal sealed class SessionUnlockObserver : IScreenUnlockObserver
{
    private Action? _onUnlock;

    public void Start(Action onUnlock)
    {
        Stop();
        _onUnlock = onUnlock;
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionUnlock) UiThread.Post(() => _onUnlock?.Invoke());
    }

    public void Stop()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        _onUnlock = null;
    }
}

internal sealed class SystemSleepObserver : ISystemSleepObserver
{
    private Action? _willSleep, _didWake;

    public void Start(Action onWillSleep, Action onDidWake)
    {
        Stop();
        _willSleep = onWillSleep;
        _didWake = onDidWake;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        switch (e.Mode)
        {
            // Posted like everything else: the controller is single-threaded.
            // Windows allows only a moment before suspending, so the notice is
            // best effort, as it is on the Mac.
            case PowerModes.Suspend: UiThread.Post(() => _willSleep?.Invoke()); break;
            case PowerModes.Resume: UiThread.Post(() => _didWake?.Invoke()); break;
        }
    }

    public void Stop()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _willSleep = _didWake = null;
    }
}

/// <summary>
/// Keeps Windows from idle-sleeping while armed. It cannot stop the lid
/// putting the laptop to sleep; that is the separate lid setting.
/// Must be called on the UI thread: the request belongs to the calling thread.
/// </summary>
internal sealed class ExecutionStateSleepAssertion : ISleepAssertion
{
    public void Acquire(string reason)
    {
        var previous = NativeMethods.SetThreadExecutionState(
            NativeMethods.ExecutionState.Continuous | NativeMethods.ExecutionState.SystemRequired);
        if (previous == 0) throw new InvalidOperationException("Windows refused the keep-awake request.");
    }

    public void Release() => NativeMethods.SetThreadExecutionState(NativeMethods.ExecutionState.Continuous);
}

/// <summary>Starts Yowl at login via the current user's Run key. No administrator rights needed.</summary>
internal sealed class RunKeyLoginItem : ILoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Yowl";

    private static string Command => $"\"{Environment.ProcessPath}\"";

    public bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value
                   && string.Equals(value, Command, StringComparison.OrdinalIgnoreCase);
        }
    }

    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled) key.SetValue(ValueName, Command);
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

/// <summary>
/// The clipboard, for values the user is told to treat as a password. Marked so
/// Windows keeps it out of clipboard history and cloud clipboard sync, the
/// counterpart of the Mac's concealed pasteboard type.
/// </summary>
internal sealed class WindowsClipboard : IClipboard
{
    public void WriteSecret(string text)
    {
        var data = new DataObject();
        data.SetText(text);
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
        data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        Clipboard.SetDataObject(data, copy: true);
    }
}

internal sealed class ExplorerShell : IShell
{
    public void OpenFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }
}

/// <summary>Posts work to the UI thread from SystemEvents and camera threads.</summary>
internal static class UiThread
{
    private static SynchronizationContext? _context;

    /// <summary>Called once, on the UI thread, before anything posts.</summary>
    public static void Capture() => _context = SynchronizationContext.Current
        ?? throw new InvalidOperationException("No UI synchronization context.");

    public static void Post(Action action) => _context?.Post(_ => action(), null);
}
