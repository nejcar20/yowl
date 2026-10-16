namespace Yowl.Core.Security;

/// <summary>
/// The result of reading a secret. "Not there" and "could not be read" are kept
/// apart on purpose: on the Mac, collapsing them meant one failed read at login
/// was taken as "missing", and the repair path deleted the user's working alert
/// link and minted a new one their phone was not subscribed to.
/// </summary>
public abstract record SecretRead
{
    public sealed record Found(byte[] Value) : SecretRead;
    public sealed record NotFound : SecretRead;
    public sealed record Unreadable(string Reason) : SecretRead;
}

/// <summary>
/// Small named secrets: the passcode hash and the alert topic. On Windows this
/// is DPAPI-encrypted files under the user's profile, the counterpart of the
/// Mac Keychain.
/// </summary>
public interface ISecretStore
{
    SecretRead Read(string name);

    /// <summary>Replaces the secret. Returns false if it could not be stored.</summary>
    bool Write(string name, byte[] value);

    /// <summary>Removes the secret. Returns true if it is gone, including if it never existed.</summary>
    bool Delete(string name);
}

/// <summary>A plain in-memory store, for tests and for previews.</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, byte[]> _values = [];
    public HashSet<string> Unreadable { get; } = [];
    public bool FailWrites { get; set; }
    public bool FailDeletes { get; set; }

    public SecretRead Read(string name)
    {
        if (Unreadable.Contains(name)) return new SecretRead.Unreadable("simulated");
        return _values.TryGetValue(name, out var value)
            ? new SecretRead.Found(value)
            : new SecretRead.NotFound();
    }

    public bool Write(string name, byte[] value)
    {
        if (FailWrites) return false;
        _values[name] = value;
        return true;
    }

    public bool Delete(string name)
    {
        if (FailDeletes) return false;
        _values.Remove(name);
        return true;
    }
}
