using Yowl.Core.Engine;
using Timer = System.Windows.Forms.Timer;

namespace Yowl.Windows.Platform;

/// <summary>
/// Schedules work on the UI thread, which is the one thread everything in
/// Yowl.Core assumes. A WinForms timer ticks on the thread that created it, so
/// this must be created on the UI thread and only used from it.
/// </summary>
internal sealed class UiClock : IAlarmClock
{
    private sealed class Work : IScheduledWork
    {
        private Timer? _timer;

        public Work(TimeSpan after, Action body)
        {
            _timer = new Timer { Interval = Math.Max(1, (int)Math.Ceiling(after.TotalMilliseconds)) };
            _timer.Tick += (_, _) =>
            {
                // One-shot: stop and dispose before running, so a body that
                // schedules more work cannot be confused with this timer.
                Cancel();
                body();
            };
            _timer.Start();
        }

        public void Cancel()
        {
            _timer?.Stop();
            _timer?.Dispose();
            _timer = null;
        }
    }

    public DateTimeOffset Now => DateTimeOffset.Now;

    public IScheduledWork Schedule(TimeSpan after, Action body) => new Work(after, body);
}
