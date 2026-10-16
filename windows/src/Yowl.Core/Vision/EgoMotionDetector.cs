namespace Yowl.Core.Vision;

/// <summary>One frame pair's verdict.</summary>
/// <param name="Shift">Global displacement in pixels.</param>
/// <param name="Explained">
/// How much of the frame-to-frame change the global shift explains: about 1 when
/// the camera moved, at or below 0 when something moved within a still frame.
/// </param>
/// <param name="Value"><c>Shift / width * Explained</c>. Positive only for genuine camera motion.</param>
public readonly record struct MotionScore(double Shift, double Explained, double Value);

/// <summary>
/// Distinguishes the camera moving from the world moving in front of it.
///
/// Naive frame differencing is useless where this app is meant for: in a café,
/// people walk past constantly. The discriminator is whether one global shift
/// explains the change between frames. A shift alone is not enough, because a
/// person walking past can produce a spurious one; what rejects it is that
/// warping by that shift makes the picture match worse, not better.
///
/// Known limitation, shared with the Mac app: periodic backgrounds (blinds,
/// tiles, brick) make the shift ambiguous, and a passer-by can then score as
/// movement. It fails toward noise, and the live sensitivity readout lets a
/// user find out in ten seconds whether their table is one of the bad ones.
/// </summary>
public sealed class EgoMotionDetector
{
    /// <summary>
    /// Below this much frame-to-frame variation a scene carries nothing to
    /// register on (a dark room, a part-closed lid), and dividing by a near-zero
    /// residual turns sensor noise into a siren.
    /// </summary>
    internal const double MinimumSceneActivity = 0.75;

    /// <summary>Settable so the sensitivity slider applies without rebuilding.</summary>
    public double Threshold { get; set; }
    public int HitsRequired { get; }
    public int Window { get; }
    public MotionScore? LastScore { get; private set; }

    private GrayscaleFrame? _previous;
    /// <summary>
    /// The last Window verdicts, oldest first. A ring of booleans rather than a
    /// counter, because a counter cannot forgive one dip without also forgiving
    /// hits minutes apart.
    /// </summary>
    private readonly Queue<bool> _recent = new();

    /// <summary>
    /// Three hits within five frames at 15 fps is ~200-330 ms: fast enough that
    /// the siren starts while the machine is still being picked up, and two
    /// independent frames away from firing on one noisy reading. A real grab is
    /// jerky, so requiring strictly consecutive hits made it slow to notice.
    /// </summary>
    public EgoMotionDetector(double threshold = 0.005, int hitsRequired = 3, int window = 5)
    {
        Threshold = threshold;
        HitsRequired = Math.Max(1, hitsRequired);
        Window = Math.Max(HitsRequired, window);
    }

    public void Reset()
    {
        _previous = null;
        _recent.Clear();
        LastScore = null;
    }

    /// <summary>Feeds one frame. True once HitsRequired of the last Window frames scored above the threshold.</summary>
    public bool Submit(GrayscaleFrame frame)
    {
        var previous = _previous;
        _previous = frame;
        if (previous is null) return false;

        if (Score(previous, frame) is not { } score)
        {
            // An unscorable pair is not evidence of movement. Leaving the run
            // intact would let a stalled sequence complete on one hit later.
            _recent.Clear();
            LastScore = null;
            return false;
        }

        LastScore = score;
        _recent.Enqueue(score.Value > Threshold);
        while (_recent.Count > Window) _recent.Dequeue();
        return _recent.Count(hit => hit) >= HitsRequired;
    }

    public MotionScore? Score(GrayscaleFrame previous, GrayscaleFrame current)
    {
        if (previous.Width != current.Width || previous.Height != current.Height) return null;
        int width = previous.Width, height = previous.Height;

        var (dx, dy) = TranslationalRegistration.Estimate(previous, current);
        var shift = Math.Sqrt(dx * dx + dy * dy);

        // Both residuals are measured over the same overlap. Comparing a warped
        // residual over a shrinking window with a raw one over the whole frame
        // biases "explained" upward exactly as the shift grows.
        var residualRaw = MeanAbsoluteDifference(previous.Pixels, current.Pixels, width, height, 0, 0, (dx, dy));
        if (residualRaw < MinimumSceneActivity) return new MotionScore(shift, 0, 0);

        var residualWarped = MeanAbsoluteDifference(previous.Pixels, current.Pixels, width, height, dx, dy, (dx, dy));
        var explained = 1 - residualWarped / residualRaw;
        return new MotionScore(shift, explained, shift / width * explained);
    }

    /// <summary>
    /// Mean |a(x+dx, y+dy) - b(x, y)|, measured over the region a shift of
    /// <paramref name="region"/> leaves overlapping, so raw and warped residuals
    /// cover the same pixels and are comparable.
    /// </summary>
    internal static double MeanAbsoluteDifference(byte[] a, byte[] b, int width, int height,
                                                  int dx, int dy, (int Dx, int Dy) region)
    {
        int xLower = Math.Max(0, -region.Dx), xUpper = Math.Min(width, width - region.Dx);
        int yLower = Math.Max(0, -region.Dy), yUpper = Math.Min(height, height - region.Dy);
        if (xLower >= xUpper || yLower >= yUpper) return 255;

        long total = 0, counted = 0;
        for (var y = yLower; y < yUpper; y++)
        {
            var sy = y + dy;
            if (sy < 0 || sy >= height) continue;
            for (var x = xLower; x < xUpper; x++)
            {
                var sx = x + dx;
                if (sx < 0 || sx >= width) continue;
                total += Math.Abs(a[sy * width + sx] - b[y * width + x]);
                counted++;
            }
        }
        return counted > 0 ? (double)total / counted : 255;
    }
}
