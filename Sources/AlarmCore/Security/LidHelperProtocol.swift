import Foundation

/// The entire interface of the privileged helper. Two calls, no arguments, no
/// return values beyond success — deliberately the smallest surface that can do
/// the job, because this is the only part of Yowl that runs as root.
@objc nonisolated public protocol YowlLidHelper {
    /// Disables system sleep and arms a watchdog. Must be called again before
    /// `LidSleepSuppression.maximumHold` elapses or the helper releases on its
    /// own.
    func holdSleep(withReply reply: @escaping (Bool) -> Void)
    /// Re-enables system sleep immediately.
    func releaseSleep(withReply reply: @escaping (Bool) -> Void)
}

nonisolated public enum YowlLidHelperService {
    /// Mach service name, matching the LaunchDaemon plist embedded in the app.
    public static let machServiceName = "com.jernejkocica.yowl.lidhelper"
}
