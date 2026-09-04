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

    /// What actually happens when this phone scans the code.
    public var scanOutcome: String {
        switch self {
        case .iPhone:
            return "Scan to open your alerts in a browser. iOS has no way to open the ntfy app from a code, so for push notifications enter the topic in the app:"
        case .android:
            return "Scan to open the ntfy app and subscribe. Or enter the topic by hand:"
        }
    }
}
