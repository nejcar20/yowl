import Testing
import Foundation
@testable import AlarmCore

// The most useful photograph is often from before the alarm fired: the thief
// approaching and looking at the machine, rather than the back of their head as
// they walk away. The camera is already running, so keeping recent frames costs
// memory and nothing else.
@Test func firingSavesTheFramesLeadingUpToIt() async {
    let camera = FakeStillCapture()
    camera.buffered = [
        TimestampedStill(jpeg: Data([1]), capturedAt: Date(timeIntervalSince1970: 10)),
        TimestampedStill(jpeg: Data([2]), capturedAt: Date(timeIntervalSince1970: 11)),
        TimestampedStill(jpeg: Data([3]), capturedAt: Date(timeIntervalSince1970: 12)),
    ]
    let store = InMemoryEvidenceStore(keepingMostRecent: 20)
    let clock = TestClock(now: Date(timeIntervalSince1970: 13))
    let response = SnapshotResponse(camera: camera, store: store,
                                    shotCount: 1, interval: 0, clock: clock)
    await response.fire(context: AlarmContext(trigger: TriggerID("motion"), firedAt: clock.now))

    // Three from before, one from the moment of firing.
    #expect(store.saved.count == 4)
    #expect(store.saved.map(\.capturedAt.timeIntervalSince1970) == [10, 11, 12, 13])
}

@Test func anEmptyBufferStillSavesTheLiveShot() async {
    let camera = FakeStillCapture()
    camera.buffered = []
    let store = InMemoryEvidenceStore(keepingMostRecent: 20)
    let clock = TestClock()
    let response = SnapshotResponse(camera: camera, store: store,
                                    shotCount: 1, interval: 0, clock: clock)
    await response.fire(context: AlarmContext(trigger: TriggerID("power"), firedAt: clock.now))
    #expect(store.saved.count == 1)
}

// Buffered frames are the moments before this alarm, not before the last one.
@Test func theBufferIsNotReplayedOnASecondFiring() async {
    let camera = FakeStillCapture()
    camera.buffered = [TimestampedStill(jpeg: Data([1]),
                                        capturedAt: Date(timeIntervalSince1970: 10))]
    let store = InMemoryEvidenceStore(keepingMostRecent: 20)
    let clock = TestClock(now: Date(timeIntervalSince1970: 11))
    let response = SnapshotResponse(camera: camera, store: store,
                                    shotCount: 1, interval: 0, clock: clock)
    await response.fire(context: AlarmContext(trigger: TriggerID("motion"), firedAt: clock.now))
    await response.reset()
    camera.buffered = []
    await response.fire(context: AlarmContext(trigger: TriggerID("motion"), firedAt: clock.now))
    #expect(store.saved.filter { $0.capturedAt.timeIntervalSince1970 == 10 }.count == 1)
}
