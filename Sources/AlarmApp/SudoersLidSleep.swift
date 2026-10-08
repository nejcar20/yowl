import Foundation
import os
import AlarmCore

/// Keeps the Mac awake with the lid shut, by letting the app run exactly two
/// `pmset` commands as root.
///
/// The launchd/XPC helper this replaces registered cleanly, reported `enabled`,
/// and was never started by launchd — so every call failed. This design has no
/// daemon, no Mach service and no XPC: one sudoers rule naming two literal
/// commands, and `sudo -n` to run them. It is the approach Amphetamine uses,
/// and it is proven to work on hardware where the other one did not.
public final class SudoersLidSleepSuppressor: LidSleepSuppressing {
    /// Both commands in full. A sudoers rule is only as safe as its narrowness:
    /// these are absolute paths with fixed arguments, so the grant cannot be
    /// used to run anything else.
    nonisolated static let allowed = [
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -a disablesleep 0",
    ]
    nonisolated static let rulePath = "/etc/sudoers.d/yowl-disablesleep"
    /// Touched while the alarm wants sleep held off. The watchdog releases when
    /// it goes stale, which is what makes a crashed app safe.
    nonisolated static let holdFile = "/tmp/.yowl-hold-until"

    private let log = Logger(subsystem: "com.jernejkocica.yowl", category: "lidsleep")

    public init() {}

    nonisolated static func rule(for user: String) -> String {
        """
        # Installed by Yowl so the alarm can keep this Mac awake while the siren
        # is sounding and the lid is shut. Exactly two commands, nothing else.
        # Remove this file, or untick the setting in Yowl, to revoke it.
        \(user) ALL=(root) NOPASSWD: \(allowed[0]), \(allowed[1])
        """
    }

    // MARK: - State

    /// Asks sudo, rather than trusting the file to exist: the rule can be
    /// present and still not apply, and a feature that reports itself available
    /// when it is not is the failure this whole area keeps producing.
    public var isAvailable: Bool {
        Self.shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]) != nil
    }

    public var stateDescription: String {
        guard FileManager.default.fileExists(atPath: Self.rulePath) else { return "not installed" }
        return isAvailable ? "enabled" : "installed but not permitted"
    }

    // MARK: - Install

    /// Async, and off the main thread. Run synchronously on the main actor the
    /// administrator prompt has nowhere to draw: the UI is blocked waiting for
    /// the very dialog it needs to present, so nothing appears and the install
    /// silently does not happen.
    public func install() async throws {
        let user = NSUserName()
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("yowl-sudoers")
        try Self.rule(for: user).write(to: staged, atomically: true, encoding: .utf8)

        // Validated before it is anywhere near /etc. A malformed sudoers file
        // can lock a person out of sudo entirely, so this is checked first and
        // checked again after installing.
        guard Self.shell("/usr/sbin/visudo", ["-c", "-f", staged.path]) != nil else {
            throw LidHelperError.invalidRule
        }

        let command = Self.installCommand(staged: staged.path)
        let result = await Task.detached { Self.adminShell(command) }.value
        try? FileManager.default.removeItem(at: staged)
        guard result.output != nil else {
            log.error("helper install failed (\(result.status)): \(result.stderr, privacy: .public)")
            throw Self.adminFailure(from: result.stderr)
        }
    }

    /// Checks only Yowl's own file once it is in place. A bare `visudo -c`
    /// checks every file in sudoers.d, so someone else's broken rule failed
    /// this install with ours perfectly valid. On failure the file is removed
    /// again: a rule that does not pass visudo must not be left in /etc.
    nonisolated static func installCommand(staged: String) -> String {
        "install -m 0440 -o root -g wheel '\(staged)' '\(rulePath)'"
            + " && { /usr/sbin/visudo -c -f '\(rulePath)' || { rm -f '\(rulePath)'; exit 1; }; }"
    }

    /// Tells a cancelled prompt apart from a command that failed after the
    /// password was accepted. Both used to read "not authorised", which hid
    /// the real error (issue #1).
    nonisolated static func adminFailure(from stderr: String) -> LidHelperError {
        // osascript reports a cancel as AppleScript error -128.
        if stderr.contains("(-128)") { return .notAuthorised }
        // Strip osascript's "0:98: execution error: " so the cause reads first.
        var detail = stderr
        if let range = detail.range(of: "execution error: ") {
            detail = String(detail[range.upperBound...])
        }
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return .installFailed(detail.isEmpty ? "no error output" : detail)
    }

    public func uninstall() async throws {
        await release()
        let command = "rm -f '\(Self.rulePath)'"
        _ = await Task.detached { Self.adminShell(command) }.value
    }

    // MARK: - Hold

    public func hold(seconds: TimeInterval) async -> Bool {
        let window = LidSleepSuppression.clampHold(seconds)
        let until = Int(Date().timeIntervalSince1970 + window)
        try? String(until).write(toFile: Self.holdFile, atomically: true, encoding: .utf8)
        guard Self.shell("/usr/bin/sudo",
                         ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]) != nil else {
            log.notice("hold refused: sudo rule not in place")
            return false
        }
        startWatchdog()
        return true
    }

    public func release() async {
        try? FileManager.default.removeItem(atPath: Self.holdFile)
        _ = Self.shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    /// A detached shell that outlives this app. Without a daemon there is
    /// nothing else to undo the setting if the app is force quit or the machine
    /// is carried off mid-alarm — and a Mac that cannot sleep, shut in a bag
    /// with the camera running, is a fire risk. It polls the hold file and
    /// releases as soon as it is stale or gone.
    private func startWatchdog() {
        let script = """
        while [ -f '\(Self.holdFile)' ] && \
        [ "$(date +%s)" -lt "$(cat '\(Self.holdFile)' 2>/dev/null || echo 0)" ]; do sleep 5; done
        /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
        rm -f '\(Self.holdFile)'
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()   // deliberately not awaited: it must outlive us
    }

    // MARK: - Shell

    struct ShellResult {
        let status: Int32
        /// Stdout on success, nil on any failure — the shape `shell` returns.
        let output: String?
        let stderr: String
    }

    /// Runs a command and keeps its stderr, so a failure can say why.
    nonisolated static func run(_ path: String, _ args: [String]) -> ShellResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        // Stderr goes to a file, not a second pipe: two pipes need concurrent
        // draining or a full one blocks the child.
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yowl-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let out = Pipe()
        task.standardOutput = out
        task.standardError = try? FileHandle(forWritingTo: errURL)
        do { try task.run() } catch {
            return ShellResult(status: -1, output: nil, stderr: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = task.terminationStatus == 0
            ? (String(data: outData, encoding: .utf8) ?? "") : nil
        return ShellResult(status: task.terminationStatus, output: output, stderr: stderr)
    }

    @discardableResult
    nonisolated static func shell(_ path: String, _ args: [String]) -> String? {
        run(path, args).output
    }

    /// One admin prompt, shown by macOS itself. Used only to install or remove
    /// the rule — never to run pmset, which is the whole point of the rule.
    nonisolated static func adminShell(_ command: String) -> ShellResult {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript",
                   ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}
