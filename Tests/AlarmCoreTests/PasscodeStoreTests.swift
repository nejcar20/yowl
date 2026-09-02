import Testing
import Foundation
@testable import AlarmCore

@Test func newStoreHasNoPasscode() {
    #expect(InMemoryPasscodeStore().hasPasscode == false)
}

@Test func correctPasscodeVerifies() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    #expect(store.hasPasscode == true)
    #expect(store.verify("hunter2") == true)
}

@Test func wrongPasscodeFails() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    #expect(store.verify("hunter3") == false)
}

@Test func verifyFailsWhenNoPasscodeSet() {
    #expect(InMemoryPasscodeStore().verify("anything") == false)
}

@Test func emptyPasscodeIsRejected() {
    let store = InMemoryPasscodeStore()
    #expect(throws: PasscodeError.self) { try store.setPasscode("") }
}

@Test func passcodeIsNotStoredInPlaintext() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    let blob = try #require(store.rawRecord)
    #expect(String(data: blob, encoding: .utf8)?.contains("hunter2") != true)
    #expect(blob.range(of: Data("hunter2".utf8)) == nil)
}

// Two stores with the same passcode must produce different hashes, or a
// stolen record would reveal that two users share a passcode.
@Test func saltsDifferBetweenStores() throws {
    let a = InMemoryPasscodeStore(); try a.setPasscode("same")
    let b = InMemoryPasscodeStore(); try b.setPasscode("same")
    #expect(a.rawRecord != b.rawRecord)
}

@Test func clearingRemovesPasscode() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("hunter2")
    try store.clear()
    #expect(store.hasPasscode == false)
    #expect(store.verify("hunter2") == false)
}

// Replacing a passcode is a plain overwrite. The protection is that settings
// are frozen while armed, so this is unreachable mid-alarm; demanding the old
// passcode on top adds nothing, because a Mac sitting unlocked and disarmed has
// already lost.
@Test func replacingThePasscodeOverwritesTheOldOne() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("old")
    try store.setPasscode("new")
    #expect(store.verify("new") == true)
    #expect(store.verify("old") == false)
}

@Test func replacingWithAnEmptyPasscodeIsRejectedAndKeepsTheOldOne() throws {
    let store = InMemoryPasscodeStore()
    try store.setPasscode("old")
    #expect(throws: PasscodeError.self) { try store.setPasscode("") }
    #expect(store.verify("old") == true)
}
