import Foundation

/// Which phone is being paired. This is a real fork, not a cosmetic one: the
/// only way to open the ntfy app from a scan is its `ntfy://` scheme, and that
/// scheme exists only on Android.
public enum PairingTarget: String, CaseIterable, Identifiable {
    case iPhone
    case android

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iPhone: return "iPhone"
        case .android: return "Android"
        }
    }

    /// Whether a code helps. iOS has no way to open the ntfy app from a scan,
    /// and a code that opens a browser is not what anyone pairing wants, so
    /// an iPhone is given the topic to type instead.
    public var usesCode: Bool { self == .android }

    public var instructions: String {
        switch self {
        case .iPhone:
            return "In the ntfy app tap +, leave the server as ntfy.sh, and enter this topic:"
        case .android:
            return "Scan to open the ntfy app and subscribe. Or enter the topic by hand:"
        }
    }
}
