using System.Security.Cryptography;
using System.Text;

namespace Yowl.Core.Security;

public sealed class PasscodeException(string message) : Exception(message);

public interface IPasscodeStore
{
    bool HasPasscode { get; }

    /// <exception cref="PasscodeException">Empty passcode, or it could not be stored.</exception>
    void SetPasscode(string passcode);

    bool Verify(string passcode);
}

/// <summary>Salt + PBKDF2-SHA256, serialised as <c>salt || hash</c>. Same scheme as the Mac app.</summary>
internal static class PasscodeHasher
{
    public const int SaltBytes = 16;
    public const int HashBytes = 32;
    public const int Rounds = 210_000; // OWASP 2023 guidance for PBKDF2-SHA256

    public static byte[] Hash(string passcode, byte[] salt) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passcode), salt, Rounds,
                                  HashAlgorithmName.SHA256, HashBytes);

    public static byte[] MakeRecord(string passcode)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        return [.. salt, .. Hash(passcode, salt)];
    }

    public static bool Matches(string passcode, byte[] record)
    {
        if (record.Length != SaltBytes + HashBytes) return false;
        var salt = record[..SaltBytes];
        var expected = record[SaltBytes..];
        return CryptographicOperations.FixedTimeEquals(Hash(passcode, salt), expected);
    }
}

public sealed class PasscodeStore(ISecretStore secrets) : IPasscodeStore
{
    private const string Name = "disarm-passcode";

    public bool HasPasscode => secrets.Read(Name) is SecretRead.Found;

    public void SetPasscode(string passcode)
    {
        if (string.IsNullOrEmpty(passcode)) throw new PasscodeException("Enter a passcode before saving.");
        // Written in one replace, so a failure leaves the old passcode intact.
        if (!secrets.Write(Name, PasscodeHasher.MakeRecord(passcode)))
            throw new PasscodeException("Could not save the passcode. Try again.");
    }

    public bool Verify(string passcode) =>
        secrets.Read(Name) is SecretRead.Found found && PasscodeHasher.Matches(passcode, found.Value);
}
