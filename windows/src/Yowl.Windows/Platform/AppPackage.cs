using System.Runtime.InteropServices;
using Windows.ApplicationModel;

namespace Yowl.Windows.Platform;

/// <summary>
/// Whether Yowl is running from its Microsoft Store (MSIX) package or as the
/// plain exe. A few things must differ: a packaged app's writes to its own
/// AppData folder and to the Run key are redirected into the package, so
/// Explorer and Windows would not see them where the plain exe puts them.
/// </summary>
internal static partial class AppPackage
{
    private const int AppModelErrorNoPackage = 15700;

    public static bool IsPackaged { get; } = DetectPackaged();

    private static bool DetectPackaged()
    {
        uint length = 0;
        return GetCurrentPackageFullName(ref length, IntPtr.Zero) != AppModelErrorNoPackage;
    }

    /// <summary>Where settings, secrets, photos and the lid restore file live.</summary>
    public static string DataDirectory => IsPackaged
        ? global::Windows.Storage.ApplicationData.Current.LocalFolder.Path
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Yowl");

    [LibraryImport("kernel32.dll")]
    private static partial int GetCurrentPackageFullName(ref uint length, IntPtr name);
}

/// <summary>
/// Start at login for the Store build: the package's startup task, declared in
/// Package.appxmanifest. The Run key cannot be used there, because a packaged
/// app's registry writes stay inside its package.
/// </summary>
internal sealed class StartupTaskLoginItem : Yowl.Core.Security.ILoginItem
{
    private const string TaskId = "YowlStartup";

    // The WinRT calls complete off the UI thread, so waiting on them here does
    // not deadlock; they are quick, and enabling shows no prompt for a desktop app.
    private static StartupTask Task => StartupTask.GetAsync(TaskId).AsTask().GetAwaiter().GetResult();

    public bool IsEnabled => Task.State is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;

    public void SetEnabled(bool enabled)
    {
        var task = Task;
        if (!enabled)
        {
            task.Disable();
            return;
        }
        var state = task.RequestEnableAsync().AsTask().GetAwaiter().GetResult();
        if (state is StartupTaskState.DisabledByUser)
            throw new InvalidOperationException(
                "Start at login was turned off in Windows Settings › Apps › Startup. Turn Yowl on there.");
        if (state is StartupTaskState.DisabledByPolicy)
            throw new InvalidOperationException("Your organisation's policy does not allow Yowl to start at login.");
    }
}
