namespace Yowl.Core.Security;

/// <summary>Keeps the machine from idle-sleeping while armed.</summary>
public interface ISleepAssertion
{
    /// <exception cref="Exception">Windows refused the request.</exception>
    void Acquire(string reason);
    void Release();
}

/// <summary>Reports the user unlocking their Windows session.</summary>
public interface IScreenUnlockObserver
{
    void Start(Action onUnlock);
    void Stop();
}

/// <summary>Reports the machine going to sleep and waking.</summary>
public interface ISystemSleepObserver
{
    void Start(Action onWillSleep, Action onDidWake);
    void Stop();
}

/// <summary>Starts the app when the user logs in.</summary>
public interface ILoginItem
{
    bool IsEnabled { get; }
    /// <exception cref="Exception">The setting could not be changed.</exception>
    void SetEnabled(bool enabled);
}

/// <summary>Writes a value the user is told to treat as a password.</summary>
public interface IClipboard
{
    void WriteSecret(string text);
}

/// <summary>Opens folders for the user.</summary>
public interface IShell
{
    void OpenFolder(string path);
}
