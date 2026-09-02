import Foundation
import Security
import CommonCrypto

public extension PasscodeStoring {
    /// Shared by every store: verification and replacement are the same two
    /// steps everywhere, and duplicating them is how one copy loses the check.
    func changePasscode(current: String, new: String) throws -> Bool {
        guard !new.isEmpty else { throw PasscodeError.empty }
        guard verify(current) else { return false }
        try setPasscode(new)
        return true
    }
}

public enum PasscodeError: Error, Equatable {
    case empty
    case cryptoFailure(Int32)
    case keychain(OSStatus)
}

public protocol PasscodeStoring: AnyObject {
    var hasPasscode: Bool { get }
    func setPasscode(_ passcode: String) throws
    func verify(_ passcode: String) -> Bool
    func clear() throws
    /// Replaces the passcode, proving knowledge of the current one first.
    /// Returns `false` when `current` is wrong, leaving the stored passcode
    /// untouched. Without this check, changing the passcode would be a
    /// one-click disarm bypass.
    func changePasscode(current: String, new: String) throws -> Bool
}

/// Salt + PBKDF2-SHA256 hash, serialised as `salt || hash`.
enum PasscodeHasher {
    static let saltBytes = 16
    static let hashBytes = 32
    static let rounds: UInt32 = 210_000   // OWASP 2023 guidance for PBKDF2-SHA256

    static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes, &bytes)
        guard status == errSecSuccess else { throw PasscodeError.cryptoFailure(status) }
        return Data(bytes)
    }

    static func hash(_ passcode: String, salt: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: hashBytes)
        let pw = Array(passcode.utf8)
        var status: Int32 = 0
        salt.withUnsafeBytes { saltBuf in
            status = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.map { Int8(bitPattern: $0) }, pw.count,
                saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &out, hashBytes)
        }
        guard status == Int32(kCCSuccess) else {
            throw PasscodeError.cryptoFailure(status)
        }
        return Data(out)
    }

    static func makeRecord(_ passcode: String) throws -> Data {
        let salt = try randomSalt()
        return salt + (try hash(passcode, salt: salt))
    }

    static func matches(_ passcode: String, record: Data) -> Bool {
        guard record.count == saltBytes + hashBytes else { return false }
        let salt = record.prefix(saltBytes)
        let expected = record.suffix(hashBytes)
        guard let actual = try? hash(passcode, salt: Data(salt)) else { return false }
        // Constant-time comparison.
        guard actual.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(actual, expected) { diff |= a ^ b }
        return diff == 0
    }
}

#if DEBUG
// Test doubles are Debug-only. They are `public` so the test target and
// SwiftUI previews (both Debug builds) can reach them; shipping them in a
// Release build of a security product would export, among other things, an
// in-memory passcode store with a public accessor for the raw hash record.
/// Used by tests so CI never touches the real Keychain.
public final class InMemoryPasscodeStore: PasscodeStoring {
    public private(set) var rawRecord: Data?
    public init() {}
    public var hasPasscode: Bool { rawRecord != nil }

    public func setPasscode(_ passcode: String) throws {
        guard !passcode.isEmpty else { throw PasscodeError.empty }
        rawRecord = try PasscodeHasher.makeRecord(passcode)
    }

    public func verify(_ passcode: String) -> Bool {
        guard let rawRecord else { return false }
        return PasscodeHasher.matches(passcode, record: rawRecord)
    }

    public func clear() throws { rawRecord = nil }
}
#endif  // DEBUG

public final class KeychainPasscodeStore: PasscodeStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.jernejkocica.laptopalarm",
                account: String = "disarm-passcode") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        else { return nil }
        return item as? Data
    }

    public var hasPasscode: Bool { load() != nil }

    public func setPasscode(_ passcode: String) throws {
        guard !passcode.isEmpty else { throw PasscodeError.empty }
        let record = try PasscodeHasher.makeRecord(passcode)

        // Try to update the existing item first. If it doesn't exist, add it.
        // This keeps the old passcode intact if the update fails.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: record,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        } else if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it.
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = record
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PasscodeError.keychain(addStatus) }
        } else {
            throw PasscodeError.keychain(updateStatus)
        }
    }

    public func verify(_ passcode: String) -> Bool {
        guard let record = load() else { return false }
        return PasscodeHasher.matches(passcode, record: record)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasscodeError.keychain(status)
        }
    }
}
