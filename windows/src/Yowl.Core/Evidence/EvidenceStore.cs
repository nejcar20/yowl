using System.Globalization;

namespace Yowl.Core.Evidence;

/// <summary>One photograph taken because the alarm fired.</summary>
public sealed record EvidenceItem(byte[] Jpeg, DateTimeOffset CapturedAt, string Trigger);

public interface IEvidenceStore
{
    /// <summary>Saves the photograph. Returns its path, or null if it could not be written.</summary>
    string? Save(EvidenceItem item);

    /// <summary>Every saved photograph, newest first.</summary>
    IReadOnlyList<string> AllItems();

    /// <summary>The newest photographs, for an alert to attach.</summary>
    IReadOnlyList<byte[]> RecentJpegs(int limit);

    string DirectoryPath { get; }
}

/// <summary>
/// One JPEG per shot, kept on this machine only. Photographs of whoever is in
/// front of the laptop are the most sensitive thing this app makes, so they
/// stay here unless the user sets up somewhere to send them.
/// </summary>
public sealed class FileEvidenceStore : IEvidenceStore
{
    private readonly int _keepingMostRecent;

    public FileEvidenceStore(string directory, int keepingMostRecent = 40)
    {
        DirectoryPath = directory;
        _keepingMostRecent = Math.Max(1, keepingMostRecent);
        try { Directory.CreateDirectory(directory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public string DirectoryPath { get; }

    public string? Save(EvidenceItem item)
    {
        // Milliseconds, not seconds. At one-second resolution the run-up's last
        // frame and the first live shot shared a filename and one overwrote the other.
        var stamp = item.CapturedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH-mm-ss.fff", CultureInfo.InvariantCulture);
        var path = Path.Combine(DirectoryPath, $"{stamp}-{item.Trigger}.jpg");
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            File.WriteAllBytes(path, item.Jpeg);
            Prune();
            return path;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public IReadOnlyList<string> AllItems()
    {
        try
        {
            return Directory.EnumerateFiles(DirectoryPath, "*.jpg")
                .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>
    /// Keeps the newest and deletes the rest. Most firings are the owner
    /// tripping their own alarm, so unbounded, this fills the disk with them.
    /// </summary>
    private void Prune()
    {
        foreach (var path in AllItems().Skip(_keepingMostRecent))
        {
            try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    public IReadOnlyList<byte[]> RecentJpegs(int limit)
    {
        var result = new List<byte[]>();
        foreach (var path in AllItems().Take(limit))
        {
            try { result.Add(File.ReadAllBytes(path)); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return result;
    }
}
