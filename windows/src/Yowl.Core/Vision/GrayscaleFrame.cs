namespace Yowl.Core.Vision;

/// <summary>
/// One 8-bit grayscale frame, already downscaled to the detector's working size.
/// Immutable once built; safe to hand from the camera thread to the UI thread.
/// </summary>
public sealed class GrayscaleFrame
{
    public int Width { get; }
    public int Height { get; }
    public byte[] Pixels { get; }

    public GrayscaleFrame(int width, int height, byte[] pixels)
    {
        if (pixels.Length != width * height)
            throw new ArgumentException($"Expected {width * height} pixels, got {pixels.Length}.", nameof(pixels));
        Width = width;
        Height = height;
        Pixels = pixels;
    }

    /// <summary>Half-size by 2x2 averaging, for the registration pyramid.</summary>
    internal GrayscaleFrame Halved()
    {
        int w = Width / 2, h = Height / 2;
        var output = new byte[w * h];
        for (var y = 0; y < h; y++)
        {
            var row0 = 2 * y * Width;
            var row1 = row0 + Width;
            for (var x = 0; x < w; x++)
            {
                var sx = 2 * x;
                output[y * w + x] = (byte)((Pixels[row0 + sx] + Pixels[row0 + sx + 1]
                                            + Pixels[row1 + sx] + Pixels[row1 + sx + 1] + 2) / 4);
            }
        }
        return new GrayscaleFrame(w, h, output);
    }

    /// <summary>
    /// Downscales a BGRA buffer by sampling and converts to luma. Used by the
    /// camera on every frame, so it samples rather than averages.
    /// </summary>
    public static GrayscaleFrame FromBgra(ReadOnlySpan<byte> bgra, int sourceWidth, int sourceHeight,
                                          int stride, int width, int height)
    {
        var pixels = new byte[width * height];
        for (var y = 0; y < height; y++)
        {
            var sy = y * sourceHeight / height;
            for (var x = 0; x < width; x++)
            {
                var sx = x * sourceWidth / width;
                var offset = sy * stride + sx * 4;
                int b = bgra[offset], g = bgra[offset + 1], r = bgra[offset + 2];
                pixels[y * width + x] = (byte)((r * 299 + g * 587 + b * 114) / 1000);
            }
        }
        return new GrayscaleFrame(width, height, pixels);
    }
}
