import Foundation

/// Stops the Mac sleeping when the lid closes, so the siren stays audible.
///
/// This is the one thing in the app that needs root. Closing the lid begins a
/// sleep, and the audio hardware powers down at the *start* of that transition —
/// measured directly: lid shut, Mac held awake by a deferred sleep, output
/// device present, volume 1.0, mute cleared four times a second, engine
/// running, and silence. Deferring the sleep is not enough. The sleep has to not
/// happen, and the only lever for that is `pmset disablesleep`, which is root.
public protocol LidSleepSuppressing: AnyObject {
    /// Whether the privileged helper is installed and reachable.
    var isAvailable: Bool { get }
    /// Holds sleep off. Must be renewed before `maximumHold` elapses or it lapses
    /// on its own — a laptop that cannot sleep, shut in a bag with the camera
    /// running, is a fire risk, so the dangerous state is the one that expires.
    func hold(seconds: TimeInterval) async -> Bool
    /// Lets the Mac sleep again. Safe to call when nothing is held.
    func release() async

    /// What the system says about the helper, for showing to the user.
    var stateDescription: String { get }

    /// Registers the privileged helper. macOS then asks the user to approve it
    /// in System Settings — there is deliberately no way to grant it silently.
    func install() async throws
    /// Removes it again, releasing any hold first.
    func uninstall() async throws
}

nonisolated public enum LidSleepSuppression {
    /// The default, when nobody has chosen: a minute. Long enough to be
    /// unbearable to stand next to, short enough that a bagged laptop is not
    /// kept awake for long.
    public static let maximumHold: TimeInterval = 60

    /// What the setting offers. Capped deliberately: every extra minute is
    /// another minute a laptop shut in a bag cannot sleep, which is a thermal
    /// problem rather than a preference, so the ceiling is not the user's to
    /// raise indefinitely.
    public static let holdChoices: [TimeInterval] = [30, 60, 120, 300]

    public static func label(forHold seconds: TimeInterval) -> String {
        seconds < 60
            ? "\(Int(seconds)) seconds"
            : (seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes")
    }

    /// Clamps anything stored or passed in to the offered range, so a hand-edited
    /// preference cannot hold a machine awake for an hour.
    public static func clampHold(_ seconds: TimeInterval) -> TimeInterval {
        guard let lowest = holdChoices.first, let highest = holdChoices.last else {
            return maximumHold
        }
        return Swift.min(Swift.max(seconds, lowest), highest)
    }

    /// Kept for the watchdog's own polling; the app does not renew a hold.
    public static let renewInterval: TimeInterval = 20
}

/// Reads and writes the system's `SleepDisabled` flag through `pmset`.
///
/// Deliberately shells out rather than calling a private symbol: `pmset` is
/// documented, and anyone auditing the helper can read the exact command it
/// runs. Only ever useful inside a process already running as root — as a normal
/// user every call fails, which `isAvailable` reports honestly rather than
/// pretending to work.
nonisolated public final class PmsetSleepDisabler: Sendable {
    public init() {}

    public var isRoot: Bool { getuid() == 0 }

    /// Current value of the flag, or nil when it cannot be read.
    public func sleepDisabled() -> Bool? {
        guard let out = Self.run("/usr/bin/pmset", ["-g"]) else { return nil }
        return Self.parseSleepDisabled(from: out)
    }

    /// Split out so it can be tested against real pmset output. The flag is
    /// printed padded with spaces and a line matching on "SleepDisabled" also
    /// matches nothing else, so the value is the last field on that line.
    /// Absent means it was never set, which is the same as off.
    public static func parseSleepDisabled(from output: String) -> Bool {
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            guard let value = line.split(separator: " ",
                                         omittingEmptySubsequences: true).last else { continue }
            return value == "1"
        }
        return false
    }

    /// Sets the flag and *confirms it took*.
    ///
    /// pmset exits 0 for settings it silently ignores — a self-test on one Mac
    /// reported "accepted" for a command that changed nothing, purely because
    /// the exit status was believed. Not every Mac and macOS supports
    /// `disablesleep`, so the only honest answer comes from reading the flag
    /// back. A machine where it is inert reports false here, the helper reports
    /// false to the app, and the app behaves exactly like the unprivileged
    /// version instead of promising a siren it cannot deliver.
    @discardableResult
    public func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard isRoot else { return false }
        guard Self.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"]) != nil
        else { return false }
        return sleepDisabled() == disabled
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum LidHelperError: Error, LocalizedError {
    case registrationRefused
    case invalidRule
    case notAuthorised
    public var errorDescription: String? {
        switch self {
        case .registrationRefused: return "macOS refused to register the helper."
        case .invalidRule: return "The permission rule failed validation and was not installed."
        case .notAuthorised: return "Not authorised — the administrator prompt was cancelled or refused."
        }
    }
}

#if DEBUG
public final class FakeLidSleepSuppressor: LidSleepSuppressing {
    public var isAvailable: Bool
    public private(set) var isHeld = false
    public private(set) var holdCount = 0
    public private(set) var releaseCount = 0
    public init(isAvailable: Bool = true) { self.isAvailable = isAvailable }
    public var stateDescription: String { isAvailable ? "enabled" : "not registered" }
    public private(set) var holdAttempts = 0
    public private(set) var lastHoldSeconds: TimeInterval = 0
    public func hold(seconds: TimeInterval) async -> Bool {
        holdAttempts += 1
        lastHoldSeconds = seconds
        guard isAvailable else { return false }
        isHeld = true; holdCount += 1; return true
    }
    public func release() async { isHeld = false; releaseCount += 1 }
    public private(set) var installCount = 0
    public var installFails = false
    public func install() async throws {
        installCount += 1
        if installFails { throw LidHelperError.registrationRefused }
        isAvailable = true
    }
    public func uninstall() async throws {
        await release()
        isAvailable = false
    }
}
#endif
