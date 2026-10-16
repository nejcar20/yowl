namespace Yowl.Core.Vision;

/// <summary>
/// Finds the single translation that best lines one frame up with the next.
///
/// Stands in for Apple's VNTranslationalImageRegistrationRequest, which the Mac
/// app uses and Windows has no equivalent of. Coarse-to-fine block matching: an
/// exhaustive search on a 40x30 thumbnail finds large shifts (a laptop being
/// snatched moves the view by half its width between frames), then each finer
/// level refines within two pixels of twice the coarser answer.
///
/// Convention: the returned (dx, dy) satisfies <c>current(x, y) ≈ previous(x + dx, y + dy)</c>.
/// </summary>
public static class TranslationalRegistration
{
    /// <summary>Coarsest level's width. 320 halves to 40 in three steps.</summary>
    private const int CoarsestWidth = 40;

    /// <summary>
    /// Shifts that leave less than this much of the frame overlapping are not
    /// considered at the coarse level: a sliver of overlap can match by chance
    /// and would turn noise into a large, confident-looking shift.
    /// </summary>
    private const double MinimumOverlap = 0.35;

    private const int RefineRadius = 2;

    public static (int Dx, int Dy) Estimate(GrayscaleFrame previous, GrayscaleFrame current)
    {
        if (previous.Width != current.Width || previous.Height != current.Height)
            throw new ArgumentException("Frames must be the same size.");

        var pyramid = new List<(GrayscaleFrame Previous, GrayscaleFrame Current)> { (previous, current) };
        while (pyramid[^1].Previous.Width / 2 >= CoarsestWidth && pyramid[^1].Previous.Height / 2 >= 8)
        {
            var (p, c) = pyramid[^1];
            pyramid.Add((p.Halved(), c.Halved()));
        }

        var (coarsePrevious, coarseCurrent) = pyramid[^1];
        var (dx, dy) = ExhaustiveSearch(coarsePrevious, coarseCurrent);

        for (var level = pyramid.Count - 2; level >= 0; level--)
        {
            var (p, c) = pyramid[level];
            (dx, dy) = LocalSearch(p, c, dx * 2, dy * 2, RefineRadius);
        }
        return (dx, dy);
    }

    private static (int, int) ExhaustiveSearch(GrayscaleFrame previous, GrayscaleFrame current)
    {
        int w = previous.Width, h = previous.Height;
        var best = (dx: 0, dy: 0);
        var bestCost = Cost(previous, current, 0, 0);
        for (var dy = -(h - 1); dy < h; dy++)
        for (var dx = -(w - 1); dx < w; dx++)
        {
            if (Overlap(w, h, dx, dy) < MinimumOverlap) continue;
            var cost = Cost(previous, current, dx, dy);
            // Strictly better, with the smaller shift winning ties: on a
            // featureless scene every shift costs about the same, and "no
            // movement" is the honest answer there.
            if (cost < bestCost - 1e-9 || (Math.Abs(cost - bestCost) <= 1e-9 && Magnitude(dx, dy) < Magnitude(best.dx, best.dy)))
            {
                bestCost = cost;
                best = (dx, dy);
            }
        }
        return best;
    }

    private static (int, int) LocalSearch(GrayscaleFrame previous, GrayscaleFrame current,
                                          int centreX, int centreY, int radius)
    {
        int w = previous.Width, h = previous.Height;
        var best = (dx: centreX, dy: centreY);
        var bestCost = double.MaxValue;
        for (var dy = centreY - radius; dy <= centreY + radius; dy++)
        for (var dx = centreX - radius; dx <= centreX + radius; dx++)
        {
            if (Math.Abs(dx) >= w || Math.Abs(dy) >= h) continue;
            var cost = Cost(previous, current, dx, dy);
            if (cost < bestCost - 1e-9 || (Math.Abs(cost - bestCost) <= 1e-9 && Magnitude(dx, dy) < Magnitude(best.dx, best.dy)))
            {
                bestCost = cost;
                best = (dx, dy);
            }
        }
        return best;
    }

    private static int Magnitude(int dx, int dy) => dx * dx + dy * dy;

    internal static double Overlap(int width, int height, int dx, int dy) =>
        (double)Math.Max(0, width - Math.Abs(dx)) * Math.Max(0, height - Math.Abs(dy)) / (width * height);

    /// <summary>Mean |previous(x+dx, y+dy) - current(x, y)| over the overlap.</summary>
    private static double Cost(GrayscaleFrame previous, GrayscaleFrame current, int dx, int dy)
    {
        int w = previous.Width, h = previous.Height;
        int xLower = Math.Max(0, -dx), xUpper = Math.Min(w, w - dx);
        int yLower = Math.Max(0, -dy), yUpper = Math.Min(h, h - dy);
        if (xLower >= xUpper || yLower >= yUpper) return double.MaxValue;

        var a = previous.Pixels;
        var b = current.Pixels;
        long total = 0;
        for (var y = yLower; y < yUpper; y++)
        {
            var rowA = (y + dy) * w + dx;
            var rowB = y * w;
            for (var x = xLower; x < xUpper; x++)
                total += Math.Abs(a[rowA + x] - b[rowB + x]);
        }
        return (double)total / ((long)(xUpper - xLower) * (yUpper - yLower));
    }
}
