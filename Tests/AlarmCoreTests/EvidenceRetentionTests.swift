import Testing
import Foundation
@testable import AlarmCore

private func item(_ second: Int) -> EvidenceItem {
    EvidenceItem(jpeg: Data([0xFF, 0xD8, UInt8(second % 256)]),
                 capturedAt: Date(timeIntervalSince1970: TimeInterval(second)),
                 trigger: "motion")
}

// Unbounded evidence fills the disk with photographs of the owner's own face.
@Test func theStoreKeepsOnlyTheMostRecentItems() {
    let store = InMemoryEvidenceStore(keepingMostRecent: 5)
    for second in 1...12 { store.save(item(second)) }
    #expect(store.saved.count == 5)
    #expect(store.saved.map(\.capturedAt.timeIntervalSince1970) == [8, 9, 10, 11, 12])
}

@Test func pruningKeepsTheNewestNotTheOldest() {
    let store = InMemoryEvidenceStore(keepingMostRecent: 2)
    store.save(item(1)); store.save(item(2)); store.save(item(3))
    #expect(store.saved.map(\.capturedAt.timeIntervalSince1970) == [2, 3])
}

@Test func aStoreBelowItsLimitKeepsEverything() {
    let store = InMemoryEvidenceStore(keepingMostRecent: 10)
    for second in 1...4 { store.save(item(second)) }
    #expect(store.saved.count == 4)
}

// Every shot must land in its own file. Sharing the trigger's timestamp across
// shots meant three photographs writing to one filename and overwriting each
// other — two thirds of the evidence silently lost.
@Test func eachShotGetsItsOwnTimestamp() async {
    let camera = FakeStillCapture()
    let store = InMemoryEvidenceStore(keepingMostRecent: 20)
    let clock = TestClock()
    let response = SnapshotResponse(camera: camera, store: store,
                                    shotCount: 3, interval: 2, clock: clock)
    await response.fire(context: AlarmContext(trigger: TriggerID("motion"), firedAt: clock.now))
    clock.advance(by: 2)
    clock.advance(by: 2)
    let stamps = Set(store.saved.map(\.capturedAt))
    #expect(store.saved.count == 3)
    #expect(stamps.count == 3, "identical timestamps mean identical filenames")
}
