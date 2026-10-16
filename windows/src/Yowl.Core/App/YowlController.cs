using Yowl.Core.Alerts;
using Yowl.Core.Engine;
using Yowl.Core.Evidence;
using Yowl.Core.Responses;
using Yowl.Core.Security;
using Yowl.Core.Settings;
using Yowl.Core.Triggers;
using Yowl.Core.Vision;

namespace Yowl.Core.App;

/// <summary>
/// The whole app minus its window: what the tray UI shows and every rule about
/// what it may change. The Windows counterpart of the Mac app's AppModel.
///
/// Single-threaded. Every public member must be called on the UI thread, and
/// <see cref="Changed"/> is raised there after anything the UI shows has moved.
/// </summary>
public sealed class YowlController
{
    /// <summary>The preference key for keeping the siren audible with the lid shut.</summary>
    public const string LidSleepKey = "lid-sleep";

    private readonly YowlDependencies _deps;
    private readonly AlarmEngine _engine;
    private readonly PowerTrigger _power;
    private readonly MotionTrigger _motion;
    private readonly SirenResponse _siren;
    private readonly ScreenLockResponse _screenLock;
    private readonly SnapshotResponse _snapshot;
    private readonly AlertResponse _alert;
    private IScheduledWork? _countdown;

    public YowlController(YowlDependencies deps)
    {
        _deps = deps;
        var prefs = deps.Preferences;

        _power = new PowerTrigger(deps.Power, prefs.Grace);
        // One camera shared by motion detection and photographs: two sessions on
        // one device conflict, and reusing the detector's frames gives a photo
        // from the exact moment the alarm fired.
        _motion = new MotionTrigger(deps.Camera, new EgoMotionDetector(prefs.MotionThreshold), prefs.Grace);
        _siren = new SirenResponse(deps.Siren, deps.Audio, deps.Clock);
        _screenLock = new ScreenLockResponse(deps.ScreenLocker);
        _snapshot = new SnapshotResponse(deps.Camera, deps.Evidence, deps.Clock);
        _alert = new AlertResponse(new NtfyTransport(deps.Topics.Read().Value, deps.Http), deps.Evidence);

        _engine = new AlarmEngine([_power, _motion], [_siren, _screenLock, _snapshot, _alert],
                                  deps.Clock, deps.Passcodes, deps.SleepAssertion);
        _engine.StateChanged += OnStateChanged;
        _engine.ResponsesFired += () =>
        {
            if (!State.IsFiring) return;
            IsSirenSounding = _siren.IsSounding;
            Notify();
        };

        // Stored preferences onto the live objects. Availability is the
        // machine's and is never overridden: an unavailable feature stays off
        // whatever the stored preference says.
        _siren.IsEnabled = _siren.IsAvailable && prefs.IsEnabled(_siren.Identifier);
        _screenLock.IsEnabled = _screenLock.IsAvailable && prefs.IsEnabled(_screenLock.Identifier);
        _power.IsEnabled = _power.IsAvailable && prefs.IsEnabled(_power.Identifier);
        // Off until asked for: motion holds the camera open and lights its LED.
        _motion.IsEnabled = _motion.IsAvailable && prefs.IsEnabled(_motion.Identifier, false);
        _snapshot.IsEnabled = _snapshot.IsAvailable && prefs.IsEnabled(_snapshot.Identifier, false);
        deps.Camera.SetRetainsStills(_snapshot.IsEnabled);
        _alert.IncludesPhotographs = _snapshot.IsActive();
        ApplyAlertStartupDecision();

        deps.LidSleep.RecoverFromCrash();
        LidSleepEnabled = deps.LidSleep.IsAvailable && prefs.IsEnabled(LidSleepKey, false);
        LidHold = prefs.LidHold;
        Grace = prefs.Grace;
        MotionSensitivityValue = MotionSensitivity.SensitivityFor(prefs.MotionThreshold);
        LaunchAtLogin = deps.LoginItem.IsEnabled;

        RefreshPasscodeRequirement();
        RefreshProtectionWarning();

        deps.ScreenUnlocks.Start(DisarmByScreenUnlock);
        deps.SystemSleep.Start(
            onWillSleep: () => { if (State.IsFiring) _ = _alert.SendSleepNoticeAsync(); },
            onDidWake: () => _engine.ResumeAfterWake());
    }

    /// <summary>Raised on the UI thread whenever anything below has changed.</summary>
    public event Action? Changed;

    private void Notify() => Changed?.Invoke();

    // MARK: - What the UI shows

    public AlarmState State { get; private set; } = AlarmState.Disarmed;
    public bool IsArmed => State.IsArmed;
    public bool IsFiring => State.IsFiring;
    /// <summary>Settings are frozen while armed, or a thief could switch the alarm off from the tray.</summary>
    public bool SettingsLocked => IsArmed;

    public string? ErrorMessage { get; private set; }
    /// <summary>Armed, but with less cover than asked for.</summary>
    public string? WarningMessage { get; private set; }
    public string? SettingsMessage { get; private set; }
    /// <summary>Something had to be repaired or switched off at launch.</summary>
    public string? StartupMessage { get; private set; }
    /// <summary>Shown in the main panel: a configuration that cannot protect anything must be seen before walking away.</summary>
    public string? ProtectionWarning { get; private set; }
    public bool NothingEnabled { get; private set; }

    public bool NeedsPasscodeSetup { get; private set; }
    public bool HasPasscode { get; private set; }
    public bool IsSirenSounding { get; private set; }
    public int? GraceRemaining { get; private set; }

    public bool PowerEnabled => _power.IsActive();
    public bool MotionAvailable => _motion.IsAvailable;
    public bool MotionEnabled => _motion.IsActive();
    public double MotionSensitivityValue { get; private set; }
    public double? LiveMotionScore { get; private set; }
    public bool IsCalibrating { get; private set; }
    public double MotionThreshold => _motion.Detector.Threshold;

    public bool SirenEnabled => _siren.IsActive();
    public bool ScreenLockAvailable => _screenLock.IsAvailable;
    public bool ScreenLockEnabled => _screenLock.IsActive();
    public bool SnapshotAvailable => _snapshot.IsAvailable;
    public bool SnapshotEnabled => _snapshot.IsActive();
    public string EvidenceFolder => _deps.Evidence.DirectoryPath;
    public int SavedEvidenceCount => _deps.Evidence.AllItems().Count;

    public bool AlertEnabled => _alert.IsActive();
    public string AlertTopic { get; private set; } = "";
    public string AlertSubscribeUrl => AlertTopic.Length == 0 ? "" : new Uri(NtfyTransport.DefaultServer, AlertTopic).ToString();

    public TimeSpan Grace { get; private set; }
    public bool LidSleepAvailable => _deps.LidSleep.IsAvailable;
    public bool LidSleepEnabled { get; private set; }
    public TimeSpan LidHold { get; private set; }
    public bool LaunchAtLogin { get; private set; }

    public void DismissStartupMessage() { StartupMessage = null; Notify(); }

    // MARK: - Arming

    public void SetPasscode(string passcode)
    {
        if (SettingsLocked) return;
        try
        {
            _deps.Passcodes.SetPasscode(passcode);
            ErrorMessage = null;
        }
        catch (PasscodeException e)
        {
            ErrorMessage = e.Message;
        }
        RefreshPasscodeRequirement();
        RefreshProtectionWarning();
        Notify();
    }

    public void Arm()
    {
        StopCalibration();
        try
        {
            _engine.Arm();
            var photographsFailed = false;
            // Photographs without motion detection still need the camera running
            // to have a frame to save, and a run-up to save from.
            if (SnapshotEnabled && !MotionEnabled)
            {
                try { _deps.Camera.Start(_ => { }); }
                catch (FrameSourceException) { photographsFailed = true; }
            }
            ErrorMessage = null;
            var warnings = new List<string>();
            if (_engine.SleepAssertionFailed)
                warnings.Add("Windows refused the keep-awake request, so a sleeping laptop may not notice the charger being pulled.");
            if (_engine.FailedTriggers.Contains(_motion.Identifier))
                warnings.Add("The camera would not start, so movement is not being watched.");
            if (photographsFailed)
                warnings.Add("The camera would not start, so no photographs will be taken. Check camera access in Windows Settings › Privacy & security › Camera.");
            WarningMessage = warnings.Count == 0 ? null : "Armed, but: " + string.Join(" ", warnings);
        }
        catch (ArmRefusedException e)
        {
            WarningMessage = null;
            ErrorMessage = e.Reason switch
            {
                ArmRefusal.NoPasscodeSet => "Set a passcode before arming.",
                ArmRefusal.NoArmableTrigger => ProtectionStatus.From(AllTriggers).Warning
                                               ?? "Nothing can currently watch for a theft.",
                _ => "Nothing could start watching. If movement detection is on, check camera access in Windows Settings › Privacy & security › Camera.",
            };
            if (e.Reason == ArmRefusal.NoPasscodeSet) NeedsPasscodeSetup = true;
            RefreshProtectionWarning();
        }
        Notify();
    }

    public bool Disarm(string passcode)
    {
        if (_engine.Disarm(passcode))
        {
            AfterDisarm();
            return true;
        }
        ErrorMessage = "Wrong passcode.";
        Notify();
        return false;
    }

    private void DisarmByScreenUnlock()
    {
        if (_engine.DisarmByScreenUnlock()) AfterDisarm();
    }

    private void AfterDisarm()
    {
        if (SnapshotEnabled && !MotionEnabled) _deps.Camera.Stop();
        ErrorMessage = null;
        WarningMessage = null;
        Notify();
    }

    /// <summary>Restores audio when the app exits mid-alarm. Must be synchronous.</summary>
    public void Shutdown()
    {
        _siren.RestoreAudioAndSilence();
        _ = _deps.LidSleep.ReleaseAsync();
    }

    private IEnumerable<ITrigger> AllTriggers => [_power, _motion];

    private void OnStateChanged(AlarmState state)
    {
        State = state;
        UpdateCountdown(state);
        UpdateLidSleepHold(state);
        // Cleared here, not on the next fire, so a stale "sounding" cannot survive a disarm.
        if (!state.IsFiring) IsSirenSounding = false;
        RefreshProtectionWarning();
        Notify();
    }

    private void UpdateCountdown(AlarmState state)
    {
        _countdown?.Cancel();
        _countdown = null;
        if (state is not AlarmState.Grace grace)
        {
            GraceRemaining = null;
            return;
        }
        GraceRemaining = SecondsUntil(grace.Until);
        void Tick()
        {
            if (State is not AlarmState.Grace current) return;
            var remaining = SecondsUntil(current.Until);
            if (remaining != GraceRemaining) { GraceRemaining = remaining; Notify(); }
            _countdown = _deps.Clock.Schedule(TimeSpan.FromMilliseconds(250), Tick);
        }
        _countdown = _deps.Clock.Schedule(TimeSpan.FromMilliseconds(250), Tick);
    }

    private int SecondsUntil(DateTimeOffset deadline) =>
        Math.Max(0, (int)Math.Ceiling((deadline - _deps.Clock.Now).TotalSeconds));

    /// <summary>
    /// Holds sleep off with the lid shut while the siren sounds, once, for a
    /// bounded time. Releasing is the safe default; holding must be earned.
    /// </summary>
    private void UpdateLidSleepHold(AlarmState state)
    {
        if (state.IsFiring && LidSleepEnabled) _ = _deps.LidSleep.HoldAsync(LidHold);
        else _ = _deps.LidSleep.ReleaseAsync();
    }

    private void RefreshPasscodeRequirement()
    {
        HasPasscode = _deps.Passcodes.HasPasscode;
        NeedsPasscodeSetup = !HasPasscode && !_screenLock.IsActive();
    }

    private void RefreshProtectionWarning()
    {
        var status = ProtectionStatus.From(AllTriggers);
        // Every warning sends the user to Settings, which is hidden until a
        // passcode exists; during setup it is an instruction they cannot follow.
        ProtectionWarning = NeedsPasscodeSetup ? null : status.Warning;
        NothingEnabled = status is ProtectionStatus.NothingEnabled;
    }

    // MARK: - Settings

    public void SetPowerEnabled(bool enabled)
    {
        if (SettingsLocked) return;
        _power.IsEnabled = enabled && _power.IsAvailable;
        _deps.Preferences.SetEnabled(_power.Identifier, _power.IsEnabled);
        RefreshProtectionWarning();
        Notify();
    }

    public async Task SetMotionEnabledAsync(bool enabled)
    {
        if (SettingsLocked) return;
        if (!enabled)
        {
            _motion.IsEnabled = false;
            _deps.Preferences.SetEnabled(_motion.Identifier, false);
            StopCalibration();
            RefreshProtectionWarning();
            Notify();
            return;
        }
        var granted = await _motion.RequestAccessAsync();
        _motion.IsEnabled = granted && _motion.IsAvailable;
        _deps.Preferences.SetEnabled(_motion.Identifier, _motion.IsEnabled);
        SettingsMessage = _motion.IsEnabled ? null
            : "Yowl needs the camera for this. Allow it in Windows Settings › Privacy & security › Camera, under \"Let desktop apps access your camera\".";
        RefreshProtectionWarning();
        Notify();
    }

    public void SetMotionSensitivity(double sensitivity)
    {
        if (SettingsLocked) return;
        _deps.Preferences.MotionThreshold = MotionSensitivity.ThresholdFor(sensitivity);
        // Read back rather than echoed: the store clamps.
        var applied = _deps.Preferences.MotionThreshold;
        _motion.Detector.Threshold = applied;
        MotionSensitivityValue = MotionSensitivity.SensitivityFor(applied);
        Notify();
    }

    public void StartCalibration()
    {
        if (SettingsLocked || !_motion.IsAvailable || IsCalibrating) return;
        try
        {
            _motion.StartCalibration(score => { LiveMotionScore = score.Value; Notify(); });
            IsCalibrating = true;
            SettingsMessage = null;
        }
        catch (FrameSourceException)
        {
            SettingsMessage = "Could not open the camera. Allow camera access in Windows Settings › Privacy & security › Camera.";
        }
        Notify();
    }

    public void StopCalibration()
    {
        if (!IsCalibrating) return;
        _motion.StopCalibration();
        IsCalibrating = false;
        LiveMotionScore = null;
        Notify();
    }

    public void SetSirenEnabled(bool enabled)
    {
        if (SettingsLocked) return;
        _siren.IsEnabled = enabled && _siren.IsAvailable;
        _deps.Preferences.SetEnabled(_siren.Identifier, _siren.IsEnabled);
        WarnIfNoResponsesLeft();
        Notify();
    }

    public void SetScreenLockEnabled(bool enabled)
    {
        if (SettingsLocked) return;
        _screenLock.IsEnabled = enabled && _screenLock.IsAvailable;
        _deps.Preferences.SetEnabled(_screenLock.Identifier, _screenLock.IsEnabled);
        RefreshPasscodeRequirement();
        RefreshProtectionWarning();
        WarnIfNoResponsesLeft();
        Notify();
    }

    private void WarnIfNoResponsesLeft()
    {
        if (!_siren.IsActive() && !_screenLock.IsActive())
            SettingsMessage = "Nothing will happen when the alarm fires. It will still detect the theft — it just won't react.";
        else if (SettingsMessage?.StartsWith("Nothing will happen", StringComparison.Ordinal) == true)
            SettingsMessage = null;
    }

    public async Task SetSnapshotEnabledAsync(bool enabled)
    {
        if (SettingsLocked) return;
        if (!enabled)
        {
            _snapshot.IsEnabled = false;
            _deps.Preferences.SetEnabled(_snapshot.Identifier, false);
            _deps.Camera.SetRetainsStills(false);
            _alert.IncludesPhotographs = false;
            Notify();
            return;
        }
        var granted = await _deps.Camera.RequestAccessAsync();
        _snapshot.IsEnabled = granted && _snapshot.IsAvailable;
        _deps.Preferences.SetEnabled(_snapshot.Identifier, _snapshot.IsEnabled);
        _deps.Camera.SetRetainsStills(_snapshot.IsEnabled);
        _alert.IncludesPhotographs = _snapshot.IsEnabled;
        SettingsMessage = _snapshot.IsEnabled ? null
            : "Yowl needs the camera to photograph a thief. Allow it in Windows Settings › Privacy & security › Camera, under \"Let desktop apps access your camera\".";
        Notify();
    }

    public void OpenEvidenceFolder() => _deps.Shell.OpenFolder(_deps.Evidence.DirectoryPath);

    public void SetGrace(TimeSpan grace)
    {
        if (SettingsLocked) return;
        _deps.Preferences.Grace = grace;
        Grace = _deps.Preferences.Grace;
        foreach (var trigger in AllTriggers) trigger.Grace = Grace;
        Notify();
    }

    public void SetLidSleepEnabled(bool enabled)
    {
        if (SettingsLocked) return;
        LidSleepEnabled = enabled && _deps.LidSleep.IsAvailable;
        _deps.Preferences.SetEnabled(LidSleepKey, LidSleepEnabled);
        Notify();
    }

    public void SetLidHold(TimeSpan hold)
    {
        if (SettingsLocked) return;
        _deps.Preferences.LidHold = hold;
        LidHold = _deps.Preferences.LidHold;
        Notify();
    }

    public void SetLaunchAtLogin(bool enabled)
    {
        if (SettingsLocked) return;
        try
        {
            _deps.LoginItem.SetEnabled(enabled);
        }
        catch (Exception)
        {
            SettingsMessage = "Could not change whether Yowl starts at login.";
        }
        LaunchAtLogin = _deps.LoginItem.IsEnabled;
        Notify();
    }

    public void ChangePasscode(string passcode)
    {
        if (SettingsLocked) return;
        try
        {
            _deps.Passcodes.SetPasscode(passcode);
            SettingsMessage = "Passcode changed.";
        }
        catch (PasscodeException e)
        {
            SettingsMessage = e.Message;
        }
        RefreshPasscodeRequirement();
        Notify();
    }

    // MARK: - Phone alerts

    private void ApplyAlertStartupDecision()
    {
        var decision = AlertStartupDecision.Decide(
            _deps.Preferences.IsEnabled(_alert.Identifier, false), _deps.Topics.Read());
        switch (decision)
        {
            case AlertStartupDecision.Use use:
                _alert.IsEnabled = true;
                AlertTopic = use.Topic;
                break;
            case AlertStartupDecision.Mint:
                if (_deps.Topics.TopicCreatingIfNeeded() is { } minted)
                {
                    _alert.IsEnabled = true;
                    AlertTopic = minted;
                    RebuildAlertTransport();
                    StartupMessage = "Your alert link was missing, so a new one was created. Pair your phone again.";
                }
                else
                {
                    _alert.IsEnabled = false;
                    _deps.Preferences.SetEnabled(_alert.Identifier, false);
                    StartupMessage = "Phone alerts are off: a new alert link could not be created.";
                }
                break;
            case AlertStartupDecision.PauseUnreadable:
                _alert.IsEnabled = false;
                StartupMessage = "Phone alerts are paused: the alert link could not be read. Your existing link is intact; switch alerts off and on to try again.";
                break;
        }
    }

    public void SetAlertEnabled(bool enabled)
    {
        if (SettingsLocked) return;
        StartupMessage = null;
        if (!enabled)
        {
            _alert.IsEnabled = false;
            _deps.Preferences.SetEnabled(_alert.Identifier, false);
            Notify();
            return;
        }
        if (_deps.Topics.TopicCreatingIfNeeded() is not { } topic)
        {
            _alert.IsEnabled = false;
            _deps.Preferences.SetEnabled(_alert.Identifier, false);
            SettingsMessage = "Could not create a private alert link. Try again.";
            Notify();
            return;
        }
        AlertTopic = topic;
        RebuildAlertTransport();
        _alert.IsEnabled = true;
        _deps.Preferences.SetEnabled(_alert.Identifier, true);
        Notify();
    }

    public void RegenerateAlertTopic()
    {
        if (SettingsLocked) return;
        StartupMessage = null;
        if (!_deps.Topics.Reset())
        {
            SettingsMessage = "Could not remove the old link, so a new one was not created. The old link still works; try again.";
            Notify();
            return;
        }
        if (_deps.Topics.TopicCreatingIfNeeded() is not { } topic)
        {
            SettingsMessage = "Could not create a new link. The old one is no longer in use, so alerts are off until this succeeds.";
            _alert.IsEnabled = false;
            _deps.Preferences.SetEnabled(_alert.Identifier, false);
            AlertTopic = "";
            Notify();
            return;
        }
        AlertTopic = topic;
        RebuildAlertTransport();
        SettingsMessage = "New link created. Pair your phone again; the old link no longer receives alerts from this laptop.";
        Notify();
    }

    public void CopyAlertLink()
    {
        if (AlertSubscribeUrl.Length == 0) return;
        SettingsMessage = TryCopy(AlertSubscribeUrl) ?? "Link copied. Open it in a browser on your phone.";
        Notify();
    }

    public void CopyAlertTopic()
    {
        if (AlertTopic.Length == 0) return;
        SettingsMessage = TryCopy(AlertTopic) ?? "Topic copied. In the ntfy app tap +, leave the server as ntfy.sh, and paste it.";
        Notify();
    }

    /// <summary>Copies, returning why it failed, or null. Another app holding the clipboard is common.</summary>
    private string? TryCopy(string text)
    {
        try
        {
            _deps.Clipboard.WriteSecret(text);
            return null;
        }
        catch (Exception e)
        {
            return "Could not copy: " + e.Message;
        }
    }

    public async Task SendTestAlertAsync()
    {
        var ok = await _alert.SendTestAsync();
        SettingsMessage = ok ? "Test alert sent. It should be on your phone now."
            : AlertTopic.Length == 0 ? "There is no alert link yet. Switch phone alerts off and on again to create one."
            : "Could not reach ntfy.sh. Check the network and try again.";
        Notify();
    }

    private void RebuildAlertTransport() => _alert.ReplaceTransport(new NtfyTransport(AlertTopic, _deps.Http));

    /// <summary>For tests: the engine, to await the responses it fired.</summary>
    internal AlarmEngine Engine => _engine;
}
