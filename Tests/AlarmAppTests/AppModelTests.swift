import Testing
import Foundation
@testable import AlarmApp
@testable import AlarmCore

/// A model wired entirely to fakes. This is the thing that did not exist while
/// four separate "the toggle says on but nothing happens" defects shipped.
@MainActor
private func makeModel(
    preferences: InMemoryPreferences = InMemoryPreferences(),
    topicStore: InMemoryTopicStore = InMemoryTopicStore(),
    camera: FakeCamera = FakeCamera(),
    passcode: String? = "1234"
) -> (AppModel, InMemoryPreferences, InMemoryTopicStore, FakeCamera) {
    let passcodes = InMemoryPasscodeStore()
    if let passcode { try? passcodes.setPasscode(passcode) }
    let model = AppModel(dependencies: AppDependencies(
        passcodes: passcodes,
        preferences: preferences,
        topicStore: topicStore,
        camera: camera,
        lidSensor: FakeLidAngleSensor(angle: 110),
        powerMonitor: FakePowerSourceMonitor(isOnACPower: true),
        audio: FakeAudioOutputControl(state: AudioOutputState(deviceID: 1, volume: 0.3, muted: false)),
        siren: FakeSirenPlayer(),
        screenLocker: FakeScreenLocker(isAvailable: true),
        sleepAssertion: FakeSleepAssertion(),
        evidence: InMemoryEvidenceStore(),
        http: FakeHTTPClient(),
        clock: TestClock()))
    return (model, preferences, topicStore, camera)
}

/// A camera that is both a frame source and a still source, as the real one is.
final class FakeCamera: FrameSourcing, StillCapturing {
    var isAvailable = true
    var retainsStills = false
    var isHighRate = false
    var startShouldThrow = false
    private(set) var startCount = 0
    var accessGranted = true

    func requestAccess() async -> Bool { accessGranted }
    func setHighRate(_ high: Bool) { isHighRate = high }
    func setRetainsStills(_ retain: Bool) { retainsStills = retain }
    func start(onFrame: @escaping (GrayscaleFrame) -> Void) throws {
        if startShouldThrow { throw FrameSourceError.cameraUnavailable }
        startCount += 1
    }
    func stop() {}
    func captureStill() -> Data? { Data([0xFF, 0xD8]) }
    func bufferedStills() -> [TimestampedStill] { [] }
    func clearBufferedStills() {}
}

// MARK: - The defects this file exists to prevent

// A stored preference of "alerts on" with an UNREADABLE link must not mint a
// replacement: minting deletes first, so it would destroy a working link and
// leave the phone subscribed to a dead one. Most likely at login, which is when
// this app starts.
@Test @MainActor func anUnreadableAlertLinkIsNeverReplacedAtLaunch() {
    let preferences = InMemoryPreferences()
    preferences.setEnabled(true, for: "alert")
    let store = InMemoryTopicStore(stored: .unreadable(-25300))
    let (model, _, topicStore, _) = makeModel(preferences: preferences, topicStore: store)

    #expect(topicStore.mintCount == 0, "a working link must never be destroyed")
    #expect(model.alertEnabled == false, "paused, not silently on")
    #expect(model.startupMessage != nil, "the user must be told")
}

// A genuinely missing link is safe to replace.
@Test @MainActor func aMissingAlertLinkIsMintedAtLaunch() {
    let preferences = InMemoryPreferences()
    preferences.setEnabled(true, for: "alert")
    let (model, _, topicStore, _) = makeModel(preferences: preferences,
                                              topicStore: InMemoryTopicStore(stored: .notFound))
    #expect(topicStore.mintCount == 1)
    #expect(model.alertEnabled == true)
}

// The exact bug that shipped: toggle reading on while the feature was inert.
@Test @MainActor func alertsAreNeverEnabledWithoutALink() {
    let preferences = InMemoryPreferences()
    preferences.setEnabled(true, for: "alert")
    let store = InMemoryTopicStore(stored: .notFound, mintResult: nil)   // minting fails
    let (model, prefs, _, _) = makeModel(preferences: preferences, topicStore: store)

    #expect(model.alertEnabled == false)
    #expect(prefs.isEnabled("alert", default: false) == false,
            "the preference must not stay on, or the next launch repeats this")
}

// A user who never switched alerts on must never have a link minted for them.
@Test @MainActor func noLinkIsMintedForAUserWhoNeverEnabledAlerts() {
    let (_, _, topicStore, _) = makeModel()
    #expect(topicStore.mintCount == 0)
}

// Photographs and alerts must agree, or turning photographs off still sends
// previously captured ones — which the privacy policy says does not happen.
@Test @MainActor func turningPhotographsOffStopsThemBeingSent() async {
    let (model, _, _, camera) = makeModel()
    model.setSnapshotEnabled(true)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(camera.retainsStills == true)

    model.setSnapshotEnabled(false)
    #expect(camera.retainsStills == false, "the camera must stop keeping frames")
}

// Settings are frozen while armed: switching the siren off mid-alarm would be a
// disarm that never meets the passcode.
@Test @MainActor func settingsCannotBeChangedWhileArmed() {
    let (model, _, _, _) = makeModel()
    model.arm()
    #expect(model.isArmed == true)

    let before = model.sirenEnabled
    model.setSirenEnabled(!before)
    #expect(model.sirenEnabled == before, "a frozen setting must not move")
}

// Arming with no passcode must refuse rather than pretend.
@Test @MainActor func armingWithoutAPasscodeRefuses() {
    let (model, _, _, _) = makeModel(passcode: nil)
    model.arm()
    #expect(model.isArmed == false)
    #expect(model.needsPasscodeSetup == true)
}

// "Armed" must never mean nothing is watching.
@Test @MainActor func armingWithEveryTriggerOffRefuses() {
    let (model, _, _, _) = makeModel()
    model.setPowerEnabled(false)
    model.arm()
    #expect(model.isArmed == false)
    #expect(model.protectionWarning != nil)
}
