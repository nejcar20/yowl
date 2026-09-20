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
    func hold() async -> Bool
    /// Lets the Mac sleep again. Safe to call when nothing is held.
    func release() async

    /// What the system says about the helper, for showing to the user.
    var stateDescription: String { get }

    /// Registers the privileged helper. macOS then asks the user to approve it
    /// in System Settings — there is deliberately no way to grant it silently.
    func install() throws
    /// Removes it again, releasing any hold first.
    func uninstall() async throws
}

nonisolated public enum LidSleepSuppression {
    /// How long a single hold survives without renewal.
    ///
    /// A minute. Long enough to be unbearable to stand next to, and the point
    /// of the alarm is to make a thief put the machine down, not to run for an
    /// hour. It also halves the window in which a bagged laptop cannot sleep.
    public static let maximumHold: TimeInterval = 60

    /// Renewed well inside the maximum, so a lapse means something really has
    /// stopped asking rather than a scheduling wobble.
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
    public var errorDescription: String? {
        "macOS refused to register the helper."
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
    public func hold() async -> Bool {
        holdAttempts += 1
        guard isAvailable else { return false }
        isHeld = true; holdCount += 1; return true
    }
    public func release() async { isHeld = false; releaseCount += 1 }
    public private(set) var installCount = 0
    public var installFails = false
    public func install() throws {
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
