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
/// Everything the controller needs from the outside world. The Mac app learned
/// that every serious defect lived in the model, and none was catchable while it
/// built real cameras and audio devices itself; so here nothing is built inside.
/// </summary>
public sealed record YowlDependencies(
    IPasscodeStore Passcodes,
    IPreferenceStore Preferences,
    ITopicStore Topics,
    ICamera Camera,
    IPowerSourceMonitor Power,
    IAudioOutputControl Audio,
    ISirenPlayer Siren,
    IScreenLocker ScreenLocker,
    ISleepAssertion SleepAssertion,
    IEvidenceStore Evidence,
    IHttpPoster Http,
    IAlarmClock Clock,
    IClipboard Clipboard,
    IShell Shell,
    IScreenUnlockObserver ScreenUnlocks,
    ISystemSleepObserver SystemSleep,
    ILidSleepSuppressor LidSleep,
    ILoginItem LoginItem);
