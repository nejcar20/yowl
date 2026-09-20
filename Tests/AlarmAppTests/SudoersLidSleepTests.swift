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
