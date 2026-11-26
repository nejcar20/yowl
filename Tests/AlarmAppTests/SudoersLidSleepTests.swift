import Testing
import Foundation
@testable import AlarmApp
@testable import AlarmCore

/// The sudoers rule is the whole security surface of this feature, so its shape
/// is pinned by tests rather than by care.

@Test @MainActor func theRuleGrantsExactlyTwoLiteralCommands() {
    let rule = SudoersLidSleepSuppressor.rule(for: "someone")
    #expect(rule.contains("/usr/bin/pmset -a disablesleep 1"))
    #expect(rule.contains("/usr/bin/pmset -a disablesleep 0"))
    #expect(rule.contains("NOPASSWD:"))
    // Absolute paths only: a relative one could be satisfied by anything on PATH.
    #expect(rule.contains(" pmset") == false || rule.contains("/usr/bin/pmset"))
    // No wildcard may ever appear here — it would grant far more than pmset.
    #expect(rule.contains("*") == false)
    #expect(rule.contains("ALL=(root)"))
}

@Test @MainActor func theRuleIsScopedToOneUser() {
    let rule = SudoersLidSleepSuppressor.rule(for: "jernej")
    #expect(rule.hasPrefix("#"), "it should explain itself to whoever finds it")
    #expect(rule.contains("jernej ALL=(root)"))
    // Never grant it to everyone.
    #expect(rule.contains("ALL ALL=") == false)
    #expect(rule.contains("%admin") == false)
}

/// Validated with visudo before it goes anywhere near /etc: a malformed sudoers
/// file can lock someone out of sudo entirely.
@Test @MainActor func theGeneratedRulePassesVisudo() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("yowl-rule-test")
    try SudoersLidSleepSuppressor.rule(for: NSUserName()).write(
        to: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: path) }

    let ok = SudoersLidSleepSuppressor.shell("/usr/sbin/visudo", ["-c", "-f", path.path])
    #expect(ok != nil, "the rule Yowl installs must be syntactically valid")
}

/// Nothing is installed by merely constructing it.
///
/// Asserted as "does not change" rather than "does not exist": the first
/// version failed the moment the feature was genuinely enabled on the machine
/// running the tests, which made it a test of the developer's settings instead
/// of a test of the code.
@Test @MainActor func constructingItInstallsNothing() {
    let path = SudoersLidSleepSuppressor.rulePath
    let before = FileManager.default.fileExists(atPath: path)

    _ = SudoersLidSleepSuppressor()

    #expect(FileManager.default.fileExists(atPath: path) == before)
}

/// Issue #1: an install that failed after the password was accepted showed the
/// same "cancelled or refused" message as a cancel, because stderr was thrown
/// away. The cause has to reach the person, or nobody can fix it.
@Test func aFailingCommandKeepsItsStderr() {
    let result = SudoersLidSleepSuppressor.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
    #expect(result.status == 3)
    #expect(result.stderr == "oops")
    #expect(result.output == nil)
}

@Test func cancellingThePromptIsReportedAsNotAuthorised() {
    let error = SudoersLidSleepSuppressor.adminFailure(
        from: "0:98: execution error: User canceled. (-128)")
    #expect(error == .notAuthorised)
}

@Test func anyOtherAdminFailureCarriesTheUnderlyingError() {
    let error = SudoersLidSleepSuppressor.adminFailure(
        from: "0:98: execution error: install: /etc/sudoers.d/yowl-disablesleep: Operation not permitted (1)")
    #expect(error == .installFailed(
        "install: /etc/sudoers.d/yowl-disablesleep: Operation not permitted (1)"))
    #expect(error.errorDescription?.contains("Operation not permitted") == true)
}

/// Issue #1: a bare `visudo -c` validates every file in sudoers.d, so another
/// app's broken rule failed this install. Only Yowl's own file is checked, and
/// a file that fails is removed rather than left in /etc.
@Test func theInstallChecksOnlyItsOwnFileAndRollsBack() {
    let command = SudoersLidSleepSuppressor.installCommand(
        rule: SudoersLidSleepSuppressor.rule(for: "someone"))
    let rule = SudoersLidSleepSuppressor.rulePath
    #expect(command.contains("visudo -c -f '\(rule)'"))
    #expect(command.contains("rm -f '\(rule)'"))
    #expect(command.hasSuffix("visudo -c") == false)
}

/// The installed rule must be the exact text Yowl generated, carried inside the
/// root command. Installing a file from the user's temp folder let anything
/// running as the user swap it during the password prompt and be granted
/// passwordless root.
@Test func theInstallCarriesTheExactRuleAndReadsNoUserFile() throws {
    let rule = SudoersLidSleepSuppressor.rule(for: "someone")
    let command = SudoersLidSleepSuppressor.installCommand(rule: rule)

    let encoded = try #require(command.firstMatch(of: /printf '%s' '([A-Za-z0-9+\/=]+)'/)?.1)
    let decoded = try #require(Data(base64Encoded: String(encoded)))
    #expect(String(decoding: decoded, as: UTF8.self) == rule)

    #expect(command.contains(FileManager.default.temporaryDirectory.path) == false)
    #expect(command.contains("mktemp"))
    // The fresh copy is validated before it is installed, not only after.
    let firstCheck = try #require(command.range(of: "visudo -c -f \"$t\""))
    let install = try #require(command.range(of: "install -m 0440"))
    #expect(firstCheck.lowerBound < install.lowerBound)
}

/// The shell part that writes and checks the rule, run for real without root:
/// everything up to the install must produce a file visudo accepts.
@Test func theWrittenRulePassesVisudo() throws {
    let rule = SudoersLidSleepSuppressor.rule(for: NSUserName())
    let command = SudoersLidSleepSuppressor.installCommand(rule: rule)
    let upToInstall = try #require(command.components(separatedBy: " && /usr/bin/install").first)
    let result = SudoersLidSleepSuppressor.run("/bin/sh", ["-c", upToInstall + " && /bin/cat \"$t\""])
    #expect(result.status == 0, "\(result.stderr)")
    #expect(result.output == rule)
}

/// Asking whether the rule applies must not change anything. It used to run
/// `pmset -a disablesleep 0`, so every state change — including the one that
/// starts the siren — released an active hold, and spawned sudo on the main
/// thread ahead of the siren.
@Test func checkingAvailabilityRunsNothing() {
    let args = SudoersLidSleepSuppressor.availabilityCheck
    #expect(args.first == "-n", "never prompts")
    #expect(args.contains("-l"), "lists the permission instead of running the command")
    #expect(args.suffix(4) == ["/usr/bin/pmset", "-a", "disablesleep", "1"],
            "asks about the exact command the rule grants")
}
