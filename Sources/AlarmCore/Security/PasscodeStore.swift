import Foundation
import Security
import CommonCrypto

public enum PasscodeError: Error, Equatable {
    case empty
    case keychain(OSStatus)
}

public protocol PasscodeStoring: AnyObject {
    var hasPasscode: Bool { get }
    func setPasscode(_ passcode: String) throws
    func verify(_ passcode: String) -> Bool
    func clear() throws
}

/// Salt + PBKDF2-SHA256 hash, serialised as `salt || hash`.
enum PasscodeHasher {
    static let saltBytes = 16
    static let hashBytes = 32
    static let rounds: UInt32 = 210_000   // OWASP 2023 guidance for PBKDF2-SHA256

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes, &bytes)
        return Data(bytes)
    }

    static func hash(_ passcode: String, salt: Data) -> Data {
        var out = [UInt8](repeating: 0, count: hashBytes)
        let pw = Array(passcode.utf8)
        salt.withUnsafeBytes { saltBuf in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.map { Int8(bitPattern: $0) }, pw.count,
                saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &out, hashBytes)
        }
        return Data(out)
    }

    static func makeRecord(_ passcode: String) -> Data {
        let salt = randomSalt()
        return salt + hash(passcode, salt: salt)
    }

    static func matches(_ passcode: String, record: Data) -> Bool {
        guard record.count == saltBytes + hashBytes else { return false }
        let salt = record.prefix(saltBytes)
        let expected = record.suffix(hashBytes)
        let actual = hash(passcode, salt: Data(salt))
        // Constant-time comparison.
        guard actual.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(actual, expected) { diff |= a ^ b }
        return diff == 0
    }
}

/// Used by tests so CI never touches the real Keychain.
public final class InMemoryPasscodeStore: PasscodeStoring {
    public private(set) var rawRecord: Data?
    public init() {}
    public var hasPasscode: Bool { rawRecord != nil }

    public func setPasscode(_ passcode: String) throws {
        guard !passcode.isEmpty else { throw PasscodeError.empty }
        rawRecord = PasscodeHasher.makeRecord(passcode)
    }

    public func verify(_ passcode: String) -> Bool {
        guard let rawRecord else { return false }
        return PasscodeHasher.matches(passcode, record: rawRecord)
    }

    public func clear() throws { rawRecord = nil }
}

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
        let record = PasscodeHasher.makeRecord(passcode)
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = record
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasscodeError.keychain(status) }
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
