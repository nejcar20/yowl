using Yowl.Core.Vision;

namespace Yowl.Core.Tests.Support;

/// <summary>
/// Deterministic, non-periodic test scenes, the same recipe as the Mac tests.
/// Periodic patterns make translational registration ambiguous and would make
/// these tests meaningless.
/// </summary>
public static class SyntheticFrames
{
    public const int Width = 320;
    public const int Height = 240;

    private sealed record Blob(double X, double Y, double Size, double Gray);

    private static IReadOnlyList<Blob> Blobs(ulong seed = 42, int count = 120)
    {
        var state = seed;
        double Next()
        {
            state = unchecked(state * 6364136223846793005UL + 1442695040888963407UL);
            return (state >> 33) % 10_000 / 10_000.0;
        }
        return Enumerable.Range(0, count)
            .Select(_ => new Blob(Next() * 320, Next() * 240, 6 + Next() * 22, 0.2 + Next() * 0.7))
            .ToList();
    }

    private static void Fill(byte[] pixels, double x, double y, double w, double h, double gray)
    {
        var value = (byte)Math.Round(Math.Clamp(gray, 0, 1) * 255);
        int x0 = Math.Max(0, (int)Math.Round(x)), x1 = Math.Min(Width, (int)Math.Round(x + w));
        int y0 = Math.Max(0, (int)Math.Round(y)), y1 = Math.Min(Height, (int)Math.Round(y + h));
        if (x0 >= x1 || y0 >= y1) return;
        for (var row = y0; row < y1; row++)
            Array.Fill(pixels, value, row * Width + x0, x1 - x0);
    }

    /// <summary>
    /// <paramref name="dx"/>/<paramref name="dy"/> move the whole scene (the camera moved).
    /// <paramref name="occluderAt"/> moves a foreground bar only (a person walked past).
    /// <paramref name="brightness"/> shifts every pixel (the lighting changed).
    /// </summary>
    public static GrayscaleFrame Scene(double dx = 0, double dy = 0, double? occluderAt = null, double brightness = 0)
    {
        var pixels = new byte[Width * Height];
        Fill(pixels, 0, 0, Width, Height, 0.2 + brightness);
        foreach (var blob in Blobs())
            Fill(pixels, blob.X + dx, blob.Y + dy, blob.Size, blob.Size, blob.Gray + brightness);
        if (occluderAt is { } ox) Fill(pixels, ox, 0, 70, Height, 0.5);
        return new GrayscaleFrame(Width, Height, pixels);
    }

    /// <summary>A dim, featureless scene: a dark room, or the lid part-closed.</summary>
    public static GrayscaleFrame Flat(double gray = 0.03, int noise = 2, ulong seed = 7)
    {
        var state = seed;
        var baseValue = (int)(gray * 255);
        var pixels = new byte[Width * Height];
        for (var i = 0; i < pixels.Length; i++)
        {
            state = unchecked(state * 6364136223846793005UL + 1442695040888963407UL);
            var jitter = (int)((state >> 33) % (ulong)(noise * 2 + 1)) - noise;
            pixels[i] = (byte)Math.Clamp(baseValue + jitter, 0, 255);
        }
        return new GrayscaleFrame(Width, Height, pixels);
    }
}
