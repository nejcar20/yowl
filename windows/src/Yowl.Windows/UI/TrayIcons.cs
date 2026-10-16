using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace Yowl.Windows.UI;

/// <summary>
/// The three tray glyphs, drawn rather than shipped as files so they follow the
/// taskbar's light or dark theme: an outlined shield when disarmed, a filled one
/// when armed, and a red one when the alarm is going.
/// </summary>
internal static class TrayIcons
{
    public enum Kind { Disarmed, Armed, Firing }

    private static readonly Color Alarm = Color.FromArgb(0xE5, 0x39, 0x35);

    public static Icon Create(Kind kind, int size)
    {
        using var bitmap = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var ink = kind == Kind.Firing ? Alarm : (TaskbarIsLight() ? Color.Black : Color.White);
            using var shield = Shield(size);
            if (kind == Kind.Disarmed)
            {
                using var pen = new Pen(ink, Math.Max(1.5f, size / 12f)) { LineJoin = LineJoin.Round };
                g.DrawPath(pen, shield);
            }
            else
            {
                using var brush = new SolidBrush(ink);
                g.FillPath(brush, shield);
                if (kind == Kind.Firing) DrawExclamation(g, size);
            }
        }
        var handle = bitmap.GetHicon();
        // Cloned so the icon owns its memory and the GDI handle can be freed.
        using var temporary = Icon.FromHandle(handle);
        var icon = (Icon)temporary.Clone();
        DestroyIcon(handle);
        return icon;
    }

    private static GraphicsPath Shield(int size)
    {
        float s = size, m = s * 0.12f;
        float left = m, right = s - m, top = m * 0.8f, bottom = s - m * 0.6f, mid = s / 2;
        var path = new GraphicsPath();
        path.AddLine(mid, top, right, top + s * 0.14f);
        path.AddBezier(right, top + s * 0.14f, right, s * 0.62f, mid + s * 0.18f, s * 0.8f, mid, bottom);
        path.AddBezier(mid, bottom, mid - s * 0.18f, s * 0.8f, left, s * 0.62f, left, top + s * 0.14f);
        path.CloseFigure();
        return path;
    }

    private static void DrawExclamation(Graphics g, int size)
    {
        using var brush = new SolidBrush(Color.White);
        float s = size, w = s * 0.12f, x = s / 2 - w / 2;
        g.FillRectangle(brush, x, s * 0.24f, w, s * 0.32f);
        g.FillEllipse(brush, x, s * 0.62f, w, w);
    }

    private static bool TaskbarIsLight()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int value && value == 1;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}
