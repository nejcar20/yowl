// Tests/AlarmCoreTests/FrameSourceTests.swift
import Testing
import Foundation
@testable import AlarmCore

@Test func aFakeSourceDeliversFramesToItsHandler() throws {
    let source = FakeFrameSource()
    var received: [GrayscaleFrame] = []
    try source.start { received.append($0) }
    source.emit(SyntheticFrames.scene())
    source.emit(SyntheticFrames.scene(dx: 5))
    #expect(received.count == 2)
}

@Test func stoppingHaltsDelivery() throws {
    let source = FakeFrameSource()
    var count = 0
    try source.start { _ in count += 1 }
    source.stop()
    source.emit(SyntheticFrames.scene())
    #expect(count == 0)
    #expect(source.isRunning == false)
}

// Restarting must not stack handlers: two live handlers would double every
// frame and halve the effective consecutive-frame threshold.
@Test func restartingReplacesTheHandlerRatherThanAddingOne() throws {
    let source = FakeFrameSource()
    var first = 0, second = 0
    try source.start { _ in first += 1 }
    try source.start { _ in second += 1 }
    source.emit(SyntheticFrames.scene())
    #expect(first == 0)
    #expect(second == 1)
}

@Test func anUnavailableSourceThrowsOnStart() {
    let source = FakeFrameSource(isAvailable: false)
    #expect(throws: FrameSourceError.self) { try source.start { _ in } }
}
