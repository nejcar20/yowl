using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Yowl.Core.Security;

namespace Yowl.Windows.Platform;

/// <summary>
/// Keeps the siren audible with the lid shut by setting the active power
/// plan's lid close action to "Do nothing", for a bounded time, then putting
/// the user's own setting back.
///
/// No administrator rights: a user can change their own power plan. Three
/// layers make sure the setting always comes back, because a laptop that cannot
/// sleep, shut in a bag with the camera running, is a fire risk:
///   1. Release restores it the moment the alarm ends.
///   2. A hidden watchdog process restores it when the hold runs out, even if
///      Yowl is killed or crashes. The Mac app uses the same design.
///   3. The original values are written to disk first, and restored at the next
///      launch if both of the above somehow failed.
/// </summary>
internal sealed partial class LidActionSuppressor(string stateDirectory) : ILidSleepSuppressor
{
    private static readonly Guid SubButtons = new("4f971e89-eebd-4455-a8de-9e59040e7347");
    private static readonly Guid LidAction = new("5ca83367-6e45-459f-a27b-476b1d01c936");
    private const uint DoNothing = 0;

    private sealed record Original(Guid Scheme, uint Ac, uint Dc);

    private string RestorePath => Path.Combine(stateDirectory, "lid-restore.json");
    private Process? _watchdog;

    public bool IsAvailable { get; } = LidPresent();

    /// <summary>For the self-test: the current lid action, read but never changed.</summary>
    public string Describe()
    {
        if (ReadCurrent() is not { } current) return "could not read the power plan";
        static string Name(uint value) => value switch { 0 => "do nothing", 1 => "sleep", 2 => "hibernate", 3 => "shut down", _ => $"#{value}" };
        var pending = File.Exists(RestorePath) ? " (a restore is pending from an earlier run)" : "";
        return $"lid present: {IsAvailable}; plugged in: {Name(current.Ac)}, on battery: {Name(current.Dc)}{pending}";
    }

    public Task<bool> HoldAsync(TimeSpan duration)
    {
        if (!IsAvailable) return Task.FromResult(false);
        var hold = LidSleepLimits.Clamp(duration);
        try
        {
            // A hold already in place keeps the values saved before it, never
            // the "Do nothing" it set itself.
            var original = LoadOriginal() ?? ReadCurrent();
            if (original is null) return Task.FromResult(false);
            Directory.CreateDirectory(stateDirectory);
            File.WriteAllText(RestorePath, JsonSerializer.Serialize(original));

            StartWatchdog(original, hold);
            if (!Write(original.Scheme, DoNothing, DoNothing))
            {
                Restore(original);
                return Task.FromResult(false);
            }
            return Task.FromResult(true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            return Task.FromResult(false);
        }
    }

    public Task ReleaseAsync()
    {
        StopWatchdog();
        if (LoadOriginal() is { } original) Restore(original);
        return Task.CompletedTask;
    }

    public void RecoverFromCrash()
    {
        if (LoadOriginal() is { } original) Restore(original);
    }

    private void Restore(Original original)
    {
        if (Write(original.Scheme, original.Ac, original.Dc))
        {
            try { File.Delete(RestorePath); } catch (IOException) { }
        }
    }

    private Original? LoadOriginal()
    {
        try
        {
            return File.Exists(RestorePath) ? JsonSerializer.Deserialize<Original>(File.ReadAllText(RestorePath)) : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// A detached cmd.exe that waits out the hold and then puts the setting
    /// back. It outlives Yowl on purpose. `ping` is the wait because `timeout`
    /// refuses to run without a console to read from.
    /// </summary>
    private void StartWatchdog(Original original, TimeSpan hold)
    {
        StopWatchdog();
        var scheme = original.Scheme.ToString("D");
        var seconds = (int)Math.Ceiling(hold.TotalSeconds) + 1;
        var script = $"ping -n {seconds} 127.0.0.1 >nul"
                   + $" & powercfg /setacvalueindex {scheme} SUB_BUTTONS LIDACTION {original.Ac}"
                   + $" & powercfg /setdcvalueindex {scheme} SUB_BUTTONS LIDACTION {original.Dc}"
                   + $" & powercfg /setactive {scheme}"
                   + $" & del /q \"{RestorePath}\"";
        _watchdog = Process.Start(new ProcessStartInfo("cmd.exe", $"/d /c \"{script}\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
        });
    }

    private void StopWatchdog()
    {
        try
        {
            if (_watchdog is { HasExited: false }) _watchdog.Kill(entireProcessTree: true);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
        _watchdog?.Dispose();
        _watchdog = null;
    }

    // MARK: - Power plan

    private static Original? ReadCurrent()
    {
        if (PowerGetActiveScheme(IntPtr.Zero, out var schemePointer) != 0) return null;
        try
        {
            var scheme = Marshal.PtrToStructure<Guid>(schemePointer);
            var sub = SubButtons;
            var setting = LidAction;
            if (PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, out var ac) != 0) return null;
            if (PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, out var dc) != 0) return null;
            return new Original(scheme, ac, dc);
        }
        finally
        {
            LocalFree(schemePointer);
        }
    }

    private static bool Write(Guid scheme, uint ac, uint dc)
    {
        var sub = SubButtons;
        var setting = LidAction;
        return PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, ac) == 0
               && PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, dc) == 0
               // Writing changes the stored plan; activating applies it.
               && PowerSetActiveScheme(IntPtr.Zero, ref scheme) == 0;
    }

    /// <summary>SYSTEM_POWER_CAPABILITIES starts with three BOOLEANs; LidPresent is the third.</summary>
    private static bool LidPresent()
    {
        var buffer = Marshal.AllocHGlobal(256);
        try
        {
            for (var i = 0; i < 256; i++) Marshal.WriteByte(buffer, i, 0);
            return GetPwrCapabilities(buffer) && Marshal.ReadByte(buffer, 2) != 0;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [LibraryImport("powrprof.dll")]
    private static partial uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [LibraryImport("powrprof.dll")]
    private static partial uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
                                                      ref Guid settingGuid, out uint value);

    [LibraryImport("powrprof.dll")]
    private static partial uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
                                                      ref Guid settingGuid, out uint value);

    [LibraryImport("powrprof.dll")]
    private static partial uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
                                                       ref Guid settingGuid, uint value);

    [LibraryImport("powrprof.dll")]
    private static partial uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
                                                       ref Guid settingGuid, uint value);

    [LibraryImport("powrprof.dll")]
    private static partial uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid schemeGuid);

    [LibraryImport("powrprof.dll")]
    [return: MarshalAs(UnmanagedType.U1)]
    private static partial bool GetPwrCapabilities(IntPtr capabilities);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr memory);
}
