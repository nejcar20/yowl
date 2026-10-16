using Microsoft.Win32;
using Yowl.Core.App;

namespace Yowl.Windows.UI;

/// <summary>
/// The tray icon and its panel. Yowl has no main window: like the Mac menu bar
/// app, it lives in the notification area, and the icon shows the state.
/// </summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly YowlController _model;
    private readonly NotifyIcon _tray;
    private readonly PanelForm _panel;
    private readonly ToolStripMenuItem _quitItem;
    private TrayIcons.Kind? _shownKind;

    public TrayContext(YowlController model)
    {
        _model = model;
        _panel = new PanelForm(model);
        // Created now so its handle exists before the first show.
        _ = _panel.Handle;

        _quitItem = new ToolStripMenuItem("Quit Yowl", null, (_, _) => Application.Exit());
        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem("Open Yowl", null, (_, _) => _panel.ShowNearTray()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_quitItem);

        _tray = new NotifyIcon { ContextMenuStrip = menu, Visible = true };
        _tray.MouseClick += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            if (_panel.Visible) _panel.Hide();
            else if (DateTime.UtcNow - _panel.LastHidden > TimeSpan.FromMilliseconds(300)) _panel.ShowNearTray();
        };

        _model.Changed += Refresh;
        // The taskbar's theme decides black or white glyphs.
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        Refresh();

        if (_model.NeedsPasscodeSetup || _model.StartupMessage is not null)
        {
            // First run, or something was repaired at launch: say so rather
            // than sitting silently in the tray.
            _tray.ShowBalloonTip(5000, "Yowl", _model.NeedsPasscodeSetup
                ? "Yowl is in the notification area. Click the shield to set it up."
                : _model.StartupMessage ?? "", ToolTipIcon.Info);
        }
    }

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category == UserPreferenceCategory.General) Platform.UiThread.Post(() => { _shownKind = null; Refresh(); });
    }

    private void Refresh()
    {
        var kind = _model.IsFiring ? TrayIcons.Kind.Firing
                 : _model.IsArmed ? TrayIcons.Kind.Armed
                 : TrayIcons.Kind.Disarmed;
        if (kind != _shownKind)
        {
            var old = _tray.Icon;
            _tray.Icon = TrayIcons.Create(kind, SystemInformation.SmallIconSize.Width);
            old?.Dispose();
            _shownKind = kind;
        }
        _tray.Text = kind switch
        {
            TrayIcons.Kind.Firing => "Yowl — ALARM",
            TrayIcons.Kind.Armed => "Yowl — Armed",
            _ => "Yowl — Disarmed",
        };
        // Quitting while armed would be the easiest way to silence it.
        _quitItem.Enabled = !_model.IsArmed;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            _tray.Visible = false;
            _tray.Dispose();
            _panel.Dispose();
        }
        base.Dispose(disposing);
    }
}
