using System.Runtime.InteropServices;
using QRCoder;
using Yowl.Core.App;
using Yowl.Core.Engine;
using Yowl.Core.Security;
using Yowl.Core.Settings;

namespace Yowl.Windows.UI;

/// <summary>
/// The window that opens from the tray icon: the Windows counterpart of the Mac
/// menu bar panel. Built once; <see cref="Render"/> copies the controller's
/// state onto the controls whenever it changes. Wording matches the Mac app.
/// </summary>
internal sealed class PanelForm : Form
{
    private const int ContentWidth = 320;
    private static readonly Color Warning = Color.FromArgb(0xE0, 0x7B, 0x00);
    private static readonly Color Error = Color.FromArgb(0xD3, 0x2F, 0x2F);

    private readonly YowlController _model;
    private readonly FlowLayoutPanel _stack;
    /// <summary>True while Render writes to controls, so their change events are not taken as the user's.</summary>
    private bool _rendering;
    private bool _settingsOpen;
    private string _qrPayload = "";

    // Main
    private readonly Label _status, _sirenStatus, _protection, _startup, _error, _warning;
    private readonly FlowLayoutPanel _setupGroup, _disarmGroup;
    private readonly Label _disarmHint;
    private readonly TextBox _newPasscode, _disarmPasscode;
    private readonly Button _savePasscode, _disarm, _arm, _settingsToggle, _quit;
    private readonly Label _quitHint;

    // Settings
    private readonly FlowLayoutPanel _settings;
    private readonly Label _locked, _nothingEnabled, _settingsMessage, _graceValue, _score, _changeLabel;
    private readonly CheckBox _power, _motion, _siren, _lock, _snapshot, _alert, _lid, _login;
    private readonly FlowLayoutPanel _motionGroup, _snapshotGroup, _alertGroup, _lidGroup;
    private readonly TrackBar _sensitivity, _grace;
    private readonly Button _test, _openPhotos, _changePasscode;
    private readonly RadioButton _iphone, _android;
    private readonly PictureBox _qr;
    private readonly Label _pairingHint;
    private readonly TextBox _topic;
    private readonly ComboBox _lidHold;
    private readonly TextBox _changePasscodeText;

    public PanelForm(YowlController model)
    {
        _model = model;
        Text = "Yowl";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        Font = new Font("Segoe UI", 9f);
        KeyPreview = true;
        Padding = new Padding(14, 12, 14, 12);
        // Vertical scrolling only. The content has a fixed width, and a
        // horizontal bar appeared whenever the vertical one took its room.
        HorizontalScroll.Enabled = false;
        HorizontalScroll.Visible = false;
        HorizontalScroll.Maximum = 0;
        AutoScroll = true;

        _stack = Column();
        _stack.Padding = Padding.Empty;
        Controls.Add(_stack);

        _status = Add(new Label { AutoSize = true, Font = new Font("Segoe UI Semibold", 13f), Margin = new Padding(0, 0, 0, 4) });
        _sirenStatus = Add(Caption(""));

        _setupGroup = Add(Column());
        _setupGroup.Controls.Add(Caption("Choose a passcode to disarm the alarm."));
        _newPasscode = Password("Passcode");
        _setupGroup.Controls.Add(_newPasscode);
        _savePasscode = Action("Save", (_, _) => { _model.SetPasscode(_newPasscode.Text); _newPasscode.Clear(); });
        _setupGroup.Controls.Add(_savePasscode);
        _newPasscode.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { _savePasscode.PerformClick(); e.SuppressKeyPress = true; } };

        _disarmGroup = Add(Column());
        _disarmHint = Caption("");
        _disarmGroup.Controls.Add(_disarmHint);
        _disarmPasscode = Password("Passcode");
        _disarmGroup.Controls.Add(_disarmPasscode);
        _disarm = Action("Disarm", (_, _) => DoDisarm());
        _disarmGroup.Controls.Add(_disarm);
        _disarmPasscode.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { DoDisarm(); e.SuppressKeyPress = true; } };

        _arm = Add(Action("Arm", (_, _) => _model.Arm()));
        _arm.Font = new Font("Segoe UI Semibold", 10f);
        _arm.Height = 34;

        _protection = Add(Caption("", Warning));
        _startup = Add(Caption("", Warning));
        _startup.Cursor = Cursors.Hand;
        _startup.Click += (_, _) => _model.DismissStartupMessage();
        _error = Add(Caption("", Error));
        _warning = Add(Caption("", Warning));

        Add(Rule());
        _settingsToggle = Add(new Button
        {
            Text = "Settings", TextAlign = ContentAlignment.MiddleLeft, FlatStyle = FlatStyle.Flat,
            Width = ContentWidth, Height = 28, Margin = Padding.Empty,
        });
        _settingsToggle.FlatAppearance.BorderSize = 0;
        _settingsToggle.Click += (_, _) => { _settingsOpen = !_settingsOpen; Render(); };

        _settings = Add(Column());
        _locked = Into(_settings, Caption("Disarm to change settings."));

        Into(_settings, Heading("What triggers the alarm"));
        _power = Into(_settings, Check("Charger unplugged", (_, on) => _model.SetPowerEnabled(on)));
        _motion = Into(_settings, Check("Laptop is moved (uses the camera)", async (_, on) => await _model.SetMotionEnabledAsync(on)));
        _motionGroup = Into(_settings, Indented());
        _motionGroup.Controls.Add(Caption("The camera light stays on while armed. Video never leaves this PC and is never recorded."));
        _score = Caption("");
        _motionGroup.Controls.Add(_score);
        _motionGroup.Controls.Add(Caption("Sensitivity"));
        _sensitivity = new TrackBar { Minimum = 0, Maximum = 100, TickFrequency = 10, Width = ContentWidth - 20, Margin = Padding.Empty };
        _sensitivity.ValueChanged += (_, _) => { if (!_rendering) _model.SetMotionSensitivity(_sensitivity.Value / 100.0); };
        _motionGroup.Controls.Add(_sensitivity);
        _motionGroup.Controls.Add(Caption("Right for more sensitive. The alarm fires when the number above crosses this one."));
        _test = Action("Test sensitivity", (_, _) =>
        {
            if (_model.IsCalibrating) _model.StopCalibration();
            else _model.StartCalibration();
        });
        _motionGroup.Controls.Add(_test);
        _motionGroup.Controls.Add(Caption("Nudge the laptop: the number should jump. Wave a hand in front of it: the number should not. If waving DOES move it, your background is too repetitive for this — blinds, tiles and brick confuse it."));
        _nothingEnabled = Into(_settings, Caption("Nothing is set to watch for anything — arming will refuse.", Warning));

        Into(_settings, Heading("When the alarm fires"));
        _siren = Into(_settings, Check("Sound the siren", (_, on) => _model.SetSirenEnabled(on)));
        _lock = Into(_settings, Check("Lock the screen", (_, on) => _model.SetScreenLockEnabled(on)));
        _snapshot = Into(_settings, Check("Photograph whoever is there", async (_, on) => await _model.SetSnapshotEnabledAsync(on)));
        _snapshotGroup = Into(_settings, Indented());
        _snapshotGroup.Controls.Add(Caption("Saved on this PC. The camera light stays on while armed."));
        _openPhotos = Action("Show saved photos", (_, _) => _model.OpenEvidenceFolder());
        _snapshotGroup.Controls.Add(_openPhotos);

        _graceValue = Into(_settings, Caption(""));
        _grace = Into(_settings, new TrackBar { Minimum = 0, Maximum = 60, TickFrequency = 10, SmallChange = 1, LargeChange = 5, Width = ContentWidth, Margin = Padding.Empty });
        _grace.ValueChanged += (_, _) => { if (!_rendering) _model.SetGrace(TimeSpan.FromSeconds(_grace.Value)); };

        _alert = Into(_settings, Check("Send an alert to my phone", (_, on) => _model.SetAlertEnabled(on)));
        _alertGroup = Into(_settings, Indented());
        _alertGroup.Controls.Add(Caption("Sent through ntfy.sh, photos included. Install the free ntfy app on your phone, then pair it below."));
        var phones = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = Padding.Empty };
        _iphone = new RadioButton { Text = "iPhone", AutoSize = true, Checked = true };
        _android = new RadioButton { Text = "Android", AutoSize = true };
        _iphone.CheckedChanged += (_, _) => Render();
        phones.Controls.AddRange([_iphone, _android]);
        _alertGroup.Controls.Add(phones);
        // Android scans the code straight into the ntfy app. iOS cannot open
        // the app from a code, so an iPhone gets the topic to type instead.
        _qr = new PictureBox { Size = new Size(150, 150), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 4, 0, 4) };
        new ToolTip().SetToolTip(_qr, "Code that pairs your phone with this PC");
        _alertGroup.Controls.Add(_qr);
        _pairingHint = Caption("");
        _alertGroup.Controls.Add(_pairingHint);
        _topic = new TextBox
        {
            ReadOnly = true, BorderStyle = BorderStyle.None, Multiline = true, WordWrap = true,
            Font = new Font("Consolas", 11f), Width = ContentWidth - 20, Height = 44,
            BackColor = BackColor, TabStop = false, Margin = new Padding(0, 2, 0, 6),
        };
        _alertGroup.Controls.Add(_topic);
        var alertButtons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, MaximumSize = new Size(ContentWidth - 20, 0), Margin = Padding.Empty };
        alertButtons.Controls.AddRange([
            Small("Copy link", (_, _) => _model.CopyAlertLink()),
            Small("Copy topic", (_, _) => _model.CopyAlertTopic()),
            Small("Send test", async (_, _) => await _model.SendTestAlertAsync()),
        ]);
        _alertGroup.Controls.Add(alertButtons);
        _alertGroup.Controls.Add(Caption("Keep the topic private — anyone who has it can see your alerts and photos. Photos are deleted from ntfy after a few hours; the copies on this PC are the ones that last."));
        _alertGroup.Controls.Add(Small("Create a new topic", (_, _) => _model.RegenerateAlertTopic()));

        _lid = Into(_settings, Check("Keep screaming with the lid closed", (_, on) => _model.SetLidSleepEnabled(on)));
        _lidGroup = Into(_settings, Indented());
        _lidGroup.Controls.Add(Caption("Closing the lid normally puts the laptop to sleep and silences the siren. While the alarm is going, this sets the lid to do nothing, then puts your setting back."));
        _lidGroup.Controls.Add(Caption("Keep it awake for"));
        _lidHold = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 140 };
        foreach (var choice in LidSleepLimits.HoldChoices) _lidHold.Items.Add(LidSleepLimits.Label(choice));
        _lidHold.SelectedIndexChanged += (_, _) =>
        {
            if (!_rendering && _lidHold.SelectedIndex >= 0) _model.SetLidHold(LidSleepLimits.HoldChoices[_lidHold.SelectedIndex]);
        };
        _lidGroup.Controls.Add(_lidHold);
        _lidGroup.Controls.Add(Caption("It holds sleep off only while the siren is sounding, then lets go on its own — so a laptop shut in a bag always gets to sleep. Longer is not better: every extra minute is another minute it cannot."));

        _login = Into(_settings, Check("Start at login", (_, on) => _model.SetLaunchAtLogin(on)));

        _changeLabel = Into(_settings, Caption(""));
        var changeRow = Into(_settings, new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = Padding.Empty });
        _changePasscodeText = Password("New passcode");
        _changePasscodeText.Width = 180;
        _changePasscode = Small("Change", (_, _) => { _model.ChangePasscode(_changePasscodeText.Text); _changePasscodeText.Clear(); });
        changeRow.Controls.AddRange([_changePasscodeText, _changePasscode]);
        _settingsMessage = Into(_settings, Caption(""));

        Add(Rule());
        _quit = Add(Action("Quit", (_, _) => Application.Exit()));
        _quitHint = Add(Caption("Disarm to quit."));

        _model.Changed += Render;
        Deactivate += (_, _) => { LastHidden = DateTime.UtcNow; Hide(); };
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) Hide(); };
        Render();
    }

    // MARK: - Showing

    /// <summary>
    /// When the panel last closed by losing focus. Clicking the tray icon to
    /// close it first takes the focus away, which hides it, and the click then
    /// lands on a hidden panel and would open it again.
    /// </summary>
    public DateTime LastHidden { get; private set; }

    /// <summary>Where the panel was opened from, so it stays anchored there as it grows and shrinks.</summary>
    private Point _anchor;

    /// <summary>Opens beside the tray, inside the screen the cursor is on.</summary>
    public void ShowNearTray()
    {
        _anchor = Cursor.Position;
        Render();
        Place();
        Show();
        Activate();
        if (_disarmGroup.Visible && _disarmPasscode.Visible) _disarmPasscode.Focus();
        else if (_setupGroup.Visible) _newPasscode.Focus();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            const int DropShadow = 0x00020000;
            var cp = base.CreateParams;
            cp.ClassStyle |= DropShadow;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        // Rounded corners like the system flyouts on Windows 11; ignored on 10.
        var round = 2;
        _ = DwmSetWindowAttribute(Handle, 33, ref round, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void DoDisarm()
    {
        if (_disarmPasscode.Text.Length == 0) return;
        _model.Disarm(_disarmPasscode.Text);
        _disarmPasscode.Clear();
    }

    // MARK: - Rendering

    private void Render()
    {
        if (IsDisposed) return;
        _rendering = true;
        SuspendLayout();
        try
        {
            var m = _model;
            _status.Text = m.State switch
            {
                AlarmState.DisarmedState => "Disarmed",
                AlarmState.ArmedState => "Armed",
                AlarmState.Grace => m.GraceRemaining is { } s ? $"Triggered — {s}s to disarm" : "Triggered — disarm now",
                _ => "ALARM",
            };
            _status.ForeColor = m.IsFiring ? Error : ForeColor;
            Show(_sirenStatus, m.IsFiring, m.IsSirenSounding ? "Siren sounding" : "Siren silent — check audio output");
            _sirenStatus.ForeColor = m.IsSirenSounding ? SystemColors.GrayText : Error;

            _setupGroup.Visible = m.NeedsPasscodeSetup;
            _savePasscode.Enabled = true;
            _disarmGroup.Visible = !m.NeedsPasscodeSetup && m.IsArmed;
            Show(_disarmHint, m.ScreenLockEnabled,
                 m.HasPasscode ? "Unlock Windows to disarm, or enter your passcode." : "Unlock Windows to disarm.");
            _disarmPasscode.Visible = _disarm.Visible = m.HasPasscode;
            _arm.Visible = !m.NeedsPasscodeSetup && !m.IsArmed;

            Show(_protection, !m.IsArmed && m.ProtectionWarning is not null, m.ProtectionWarning);
            Show(_startup, m.StartupMessage is not null, m.StartupMessage + " (click to dismiss)");
            Show(_error, m.ErrorMessage is not null, m.ErrorMessage);
            Show(_warning, m.WarningMessage is not null, m.WarningMessage);

            _settingsToggle.Visible = !m.NeedsPasscodeSetup;
            _settingsToggle.Text = (_settingsOpen ? "▾  " : "▸  ") + "Settings";
            _settings.Visible = _settingsOpen && !m.NeedsPasscodeSetup;
            RenderSettings(m);

            _quit.Enabled = !m.IsArmed;
            _quitHint.Visible = m.IsArmed;
        }
        finally
        {
            ResumeLayout(true);
            _rendering = false;
        }
        if (Visible) Place();
    }

    /// <summary>
    /// Sizes the panel to its content and keeps it against the tray edge.
    /// Re-run after every change: opening Settings grows the panel, and keeping
    /// the old position pushed its bottom under the taskbar.
    /// </summary>
    private void Place()
    {
        var area = Screen.FromPoint(_anchor).WorkingArea;
        var wanted = _stack.PreferredSize.Height + Padding.Vertical;
        var height = Math.Min(wanted, area.Height - 24);
        // The scroll bar's width at this monitor's scale, plus a little slack:
        // the system-wide figure is for 100% and left the content clipped.
        var scrollBar = wanted > height ? SystemInformation.GetVerticalScrollBarWidthForDpi(DeviceDpi) + 4 : 0;
        var width = _stack.PreferredSize.Width + Padding.Horizontal + scrollBar;
        var x = Math.Clamp(_anchor.X - width / 2, area.Left + 12, area.Right - width - 12);
        // Taskbar at the bottom (the default) keeps the bottom edge fixed;
        // at the top, the top edge.
        var y = _anchor.Y > area.Top + area.Height / 2 ? area.Bottom - height - 12 : area.Top + 12;
        Bounds = new Rectangle(x, y, width, height);
    }

    private void RenderSettings(YowlController m)
    {
        var unlocked = !m.SettingsLocked;
        _locked.Visible = m.SettingsLocked;
        foreach (Control c in _settings.Controls)
            if (c != _locked && c != _settingsMessage) c.Enabled = unlocked;

        _power.Checked = m.PowerEnabled;
        _motion.Visible = m.MotionAvailable;
        _motion.Checked = m.MotionEnabled;
        _motionGroup.Visible = m.MotionAvailable && m.MotionEnabled;
        _sensitivity.Value = (int)Math.Round(m.MotionSensitivityValue * 100);
        _test.Text = m.IsCalibrating ? "Stop test" : "Test sensitivity";
        _score.Text = m.IsCalibrating
            ? $"Movement {m.LiveMotionScore ?? 0:0.0000}   fires above {m.MotionThreshold:0.0000}"
            : $"Fires above {m.MotionThreshold:0.0000}";
        _nothingEnabled.Visible = m.NothingEnabled;

        _siren.Checked = m.SirenEnabled;
        _lock.Visible = m.ScreenLockAvailable;
        _lock.Checked = m.ScreenLockEnabled;
        _snapshot.Visible = m.SnapshotAvailable;
        _snapshot.Checked = m.SnapshotEnabled;
        _snapshotGroup.Visible = m.SnapshotAvailable && m.SnapshotEnabled;
        var count = m.SavedEvidenceCount;
        _openPhotos.Text = $"Show {count} saved photo{(count == 1 ? "" : "s")}";

        var grace = (int)m.Grace.TotalSeconds;
        _graceValue.Text = "Grace period: " + (grace == 0 ? "None" : $"{grace}s");
        _grace.Value = Math.Clamp(grace, _grace.Minimum, _grace.Maximum);

        _alert.Checked = m.AlertEnabled;
        _alertGroup.Visible = m.AlertEnabled;
        var payload = m.AlertTopic.Length == 0 || !_android.Checked ? "" : $"ntfy://ntfy.sh/{m.AlertTopic}";
        _qr.Visible = payload.Length > 0;
        _pairingHint.Text = _android.Checked
            ? "Scan to open the ntfy app and subscribe. Or enter the topic by hand:"
            : "In the ntfy app tap +, leave the server as ntfy.sh, and enter this topic:";
        if (_topic.Text != m.AlertTopic) _topic.Text = m.AlertTopic;
        if (payload != _qrPayload)
        {
            _qrPayload = payload;
            _qr.Image?.Dispose();
            _qr.Image = payload.Length == 0 ? null : QrImage(payload);
        }

        _lid.Visible = m.LidSleepAvailable;
        _lid.Checked = m.LidSleepEnabled;
        _lidGroup.Visible = m.LidSleepAvailable && m.LidSleepEnabled;
        _lidHold.SelectedIndex = LidSleepLimits.HoldChoices.ToList().IndexOf(m.LidHold);

        _login.Checked = m.LaunchAtLogin;
        _changeLabel.Text = m.HasPasscode ? "Change passcode" : "Set a passcode (optional — unlocking Windows already disarms)";
        _changePasscode.Text = m.HasPasscode ? "Change" : "Set";
        Show(_settingsMessage, m.SettingsMessage is not null, m.SettingsMessage);
    }

    private static Image QrImage(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8);
        return Image.FromStream(new MemoryStream(png));
    }

    private static void Show(Label label, bool visible, string? text)
    {
        label.Visible = visible;
        if (visible) label.Text = text;
    }

    // MARK: - Building blocks

    private T Add<T>(T control) where T : Control
    {
        _stack.Controls.Add(control);
        return control;
    }

    private static T Into<T>(Control parent, T control) where T : Control
    {
        parent.Controls.Add(control);
        return control;
    }

    private static FlowLayoutPanel Column() => new()
    {
        FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty,
    };

    private static FlowLayoutPanel Indented()
    {
        var panel = Column();
        panel.Padding = new Padding(20, 0, 0, 6);
        return panel;
    }

    private static Label Caption(string text, Color? color = null) => new()
    {
        Text = text, AutoSize = true, MaximumSize = new Size(ContentWidth - 20, 0),
        ForeColor = color ?? SystemColors.GrayText, Margin = new Padding(0, 2, 0, 4),
    };

    private static Label Heading(string text) => new()
    {
        Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 9f),
        Margin = new Padding(0, 10, 0, 2),
    };

    private static Label Rule() => new()
    {
        AutoSize = false, Height = 1, Width = ContentWidth, BorderStyle = BorderStyle.Fixed3D,
        Margin = new Padding(0, 8, 0, 8),
    };

    private static TextBox Password(string placeholder) => new()
    {
        UseSystemPasswordChar = true, PlaceholderText = placeholder, Width = ContentWidth,
        Margin = new Padding(0, 2, 0, 4),
    };

    private static Button Action(string text, EventHandler onClick)
    {
        var button = new Button { Text = text, Width = ContentWidth, Height = 30, Margin = new Padding(0, 2, 0, 4) };
        button.Click += onClick;
        return button;
    }

    private static Button Small(string text, EventHandler onClick)
    {
        var button = new Button { Text = text, AutoSize = true, Margin = new Padding(0, 2, 6, 2) };
        button.Click += onClick;
        return button;
    }

    private CheckBox Check(string text, Action<CheckBox, bool> onChange)
    {
        var box = new CheckBox { Text = text, AutoSize = true, MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(0, 4, 0, 2) };
        box.CheckedChanged += (_, _) =>
        {
            if (_rendering) return;
            onChange(box, box.Checked);
            // The controller may refuse (no camera access, settings locked);
            // show what it actually kept, not what was clicked.
            Render();
        };
        return box;
    }
}
