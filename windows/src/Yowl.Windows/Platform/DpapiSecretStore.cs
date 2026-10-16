using System.Security.Cryptography;
using Yowl.Core.Security;

namespace Yowl.Windows.Platform;

/// <summary>
/// Secrets encrypted with DPAPI for the current Windows user, one file each.
/// The Windows counterpart of the Mac Keychain: only this user, signed in on
/// this machine, can decrypt them.
/// </summary>
internal sealed class DpapiSecretStore(string directory) : ISecretStore
{
    // Ties the ciphertext to Yowl, so another app running as the same user
    // cannot decrypt these files by passing them to DPAPI with no entropy.
    private static readonly byte[] Entropy = "com.jernejkocica.yowl"u8.ToArray();

    private string PathFor(string name) => Path.Combine(directory, name + ".bin");

    public SecretRead Read(string name)
    {
        var path = PathFor(name);
        try
        {
            if (!File.Exists(path)) return new SecretRead.NotFound();
            var value = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            return new SecretRead.Found(value);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
        {
            // Present but unreadable is not "missing": see SecretRead.
            return new SecretRead.Unreadable(e.Message);
        }
    }

    public bool Write(string name, byte[] value)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var path = PathFor(name);
            var temp = path + ".tmp";
            File.WriteAllBytes(temp, ProtectedData.Protect(value, Entropy, DataProtectionScope.CurrentUser));
            // Replaced in one step, so a failure leaves the old secret intact.
            File.Move(temp, path, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
        {
            return false;
        }
    }

    public bool Delete(string name)
    {
        try
        {
            File.Delete(PathFor(name));
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
