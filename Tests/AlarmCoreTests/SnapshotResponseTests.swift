import Testing
import Foundation
@testable import AlarmCore

private let context = AlarmContext(trigger: TriggerID("motion"),
                                   firedAt: Date(timeIntervalSince1970: 1_000_000))

private func makeResponse(_ camera: FakeStillCapture, _ store: InMemoryEvidenceStore)
    -> SnapshotResponse {
    SnapshotResponse(camera: camera, store: store, shotCount: 3, interval: 0.5,
                     clock: TestClock())
}

@Test func firingSavesAPhoto() async {
    let camera = FakeStillCapture()
    let store = InMemoryEvidenceStore()
    let response = SnapshotResponse(camera: camera, store: store, shotCount: 1,
                                    interval: 0, clock: TestClock())
    await response.fire(context: context)
    #expect(store.saved.count == 1)
    #expect(store.saved.first?.trigger == "motion")
}

// Several shots over a few seconds: the first may catch the back of a head, and
// a thief walking away turns around.
@Test func firingTakesSeveralShotsOverTime() async {
    let camera = FakeStillCapture()
    let store = InMemoryEvidenceStore()
    let clock = TestClock()
    let response = SnapshotResponse(camera: camera, store: store, shotCount: 3,
                                    interval: 2, clock: clock)
    await response.fire(context: context)
    #expect(store.saved.count == 1, "the first shot is immediate")
    clock.advance(by: 2)
    #expect(store.saved.count == 2)
    clock.advance(by: 2)
    #expect(store.saved.count == 3)
    clock.advance(by: 10)
    #expect(store.saved.count == 3, "and then it stops")
}

// A camera that cannot produce an image must not stop the alarm: the siren is
// the point, evidence is a bonus.
@Test func aFailingCameraDoesNotThrowOrBlock() async {
    let camera = FakeStillCapture()
    camera.stillToReturn = nil
    let store = InMemoryEvidenceStore()
    let response = makeResponse(camera, store)
    await response.fire(context: context)
    #expect(store.saved.isEmpty)
}

@Test func resettingStopsPendingShots() async {
    let camera = FakeStillCapture()
    let store = InMemoryEvidenceStore()
    let clock = TestClock()
    let response = SnapshotResponse(camera: camera, store: store, shotCount: 3,
                                    interval: 2, clock: clock)
    await response.fire(context: context)
    await response.reset()
    clock.advance(by: 30)
    #expect(store.saved.count == 1, "disarming must not keep photographing the room")
}

@Test func theResponseIsUnavailableWithoutACamera() {
    let camera = FakeStillCapture()
    camera.available = false
    #expect(makeResponse(camera, InMemoryEvidenceStore()).isAvailable == false)
}

// Off unless asked for: it writes photographs of whoever is in front of the
// machine to disk.
@Test func snapshotsAreOptIn() {
    #expect(makeResponse(FakeStillCapture(), InMemoryEvidenceStore()).isEnabled == false)
}

// Evidence is useless without knowing when it was taken and what set it off.
// The timestamp is the moment of the SHOT, not of the trigger: they differ for
// every shot after the first, and using the trigger's time gave them all one
// filename.
@Test func savedEvidenceCarriesItsContext() async {
    let camera = FakeStillCapture()
    let store = InMemoryEvidenceStore()
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_000_000))
    let response = SnapshotResponse(camera: camera, store: store, shotCount: 1,
                                    interval: 0, clock: clock)
    await response.fire(context: context)
    let item = try? #require(store.saved.first)
    #expect(item?.capturedAt == Date(timeIntervalSince1970: 1_000_000))
    #expect(item?.trigger == "motion")
    #expect((item?.jpeg.count ?? 0) > 0)
}
