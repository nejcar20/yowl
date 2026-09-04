import Testing
import Foundation
import AppKit
@testable import AlarmApp
@testable import AlarmCore

/// A model wired entirely to fakes. This is the thing that did not exist while
/// four separate "the toggle says on but nothing happens" defects shipped.
@MainActor
private func makeModel(
    preferences: InMemoryPreferences = InMemoryPreferences(),
    topicStore: InMemoryTopicStore = InMemoryTopicStore(),
    camera: FakeCamera = FakeCamera(),
    pasteboard: FakePasteboard = FakePasteboard(),
    onACPower: Bool = true,
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
        powerMonitor: FakePowerSourceMonitor(isOnACPower: onACPower),
        audio: FakeAudioOutputControl(state: AudioOutputState(deviceID: 1, volume: 0.3, muted: false)),
        siren: FakeSirenPlayer(),
        screenLocker: FakeScreenLocker(isAvailable: true),
        sleepAssertion: FakeSleepAssertion(),
        evidence: InMemoryEvidenceStore(),
        http: FakeHTTPClient(),
        clock: TestClock(),
        pasteboard: pasteboard))
    return (model, preferences, topicStore, camera)
}

/// Records what actually reached the clipboard. The whole defect being fixed
/// here was invisible in code review: the code said "copy", it copied, and only
/// someone standing at their phone with the ntfy app open could see it had
/// copied the wrong string.
final class FakePasteboard: Pasteboarding {
    private(set) var lastWritten: String?
    func writeSecret(_ string: String) { lastWritten = string }
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


// MARK: - Pairing a phone

/// The ntfy app's subscribe screen asks for a topic name, not a URL. Copying
/// "https://ntfy.sh/<topic>" into that field does not work, so the topic has to
/// be copyable on its own.
@Test @MainActor
func copyingTheTopicCopiesTheBareTopicAndNotTheURL() {
    let pasteboard = FakePasteboard()
    let (model, _, _, _) = makeModel(pasteboard: pasteboard)
    model.setAlertEnabled(true)
    #expect(!model.alertTopic.isEmpty)

    model.copyAlertTopic()

    #expect(pasteboard.lastWritten == model.alertTopic)
    #expect(pasteboard.lastWritten?.contains("ntfy.sh") == false)
    #expect(pasteboard.lastWritten?.contains("/") == false)
}

/// The link is still what you want for a browser, so it stays available.
@Test @MainActor
func copyingTheLinkCopiesTheFullSubscribeURL() {
    let pasteboard = FakePasteboard()
    let (model, _, _, _) = makeModel(pasteboard: pasteboard)
    model.setAlertEnabled(true)

    model.copyAlertLink()

    #expect(pasteboard.lastWritten == "https://ntfy.sh/\(model.alertTopic)")
}

/// With no topic there is nothing to pair, and writing an empty string would
/// silently wipe whatever the user had on their clipboard.
@Test @MainActor
func copyingWithNoTopicWritesNothing() {
    let pasteboard = FakePasteboard()
    let (model, _, _, _) = makeModel(pasteboard: pasteboard)

    model.copyAlertTopic()
    model.copyAlertLink()

    #expect(pasteboard.lastWritten == nil)
}

// MARK: - Pairing by camera

/// A 32-character hex topic is not something anyone will retype from a screen,
/// and the clipboard does not reach a phone unless Universal Clipboard is on.
/// The code is the only pairing route that works with nothing else configured.
@Test @MainActor
func aTopicProducesAScannableCode() {
    let image = SubscribeQRCode.image(for: "https://ntfy.sh/0123456789abcdef")
    #expect(image != nil)
    #expect((image?.size.width ?? 0) > 0)
}

/// A code for an empty string scans to nothing, which is worse than no code:
/// it looks like pairing is available when it is not.
@Test @MainActor
func noTopicProducesNoCode() {
    #expect(SubscribeQRCode.image(for: "") == nil)
}

/// CIQRCodeGenerator leaves about one module of margin. The spec asks for four,
/// and scanners genuinely refuse codes that run to the edge -- which is what this
/// caught. Compositing over black also pins the background down as opaque, so a
/// future change to a transparent one cannot quietly make the code invisible in
/// dark mode.
@Test @MainActor
func theCodeIsOpaqueAndHasAQuietZone() throws {
    let image = try #require(SubscribeQRCode.image(for: "https://ntfy.sh/abc123"))
    let side = Int(image.size.width)

    let canvas = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    // The corner is quiet zone. Over a black canvas it stays light only if the
    // generator painted an opaque light background there.
    let corner = try #require(canvas.colorAt(x: 2, y: 2))
    #expect(corner.brightnessComponent > 0.9)

    // Still blank several modules in, which is what a scanner needs to lock on.
    let inset = try #require(canvas.colorAt(x: 8, y: 8))
    #expect(inset.brightnessComponent > 0.9)
}

// MARK: - Advice you can act on

/// The protection warning ends with "switch on another trigger in Settings",
/// but the settings section is hidden until a passcode exists -- so on a fresh
/// install the app told the user to do something the window did not offer. The
/// passcode is the only thing to do at that point, and it should be the only
/// thing asked for.
@Test @MainActor
func noProtectionWarningIsShownWhileAPasscodeIsStillNeeded() {
    let (model, _, _, _) = makeModel(onACPower: false, passcode: nil)

    #expect(model.needsPasscodeSetup)
    #expect(model.protectionWarning == nil)
}

/// And once the passcode is set, the warning comes back -- otherwise a user who
/// finishes setup on battery is left with nothing watching and no notice.
@Test @MainActor
func theProtectionWarningReturnsOnceThePasscodeIsSet() {
    let (model, _, _, _) = makeModel(onACPower: false, passcode: nil)
    #expect(model.protectionWarning == nil)

    model.setPasscode("4321")

    #expect(!model.needsPasscodeSetup)
    #expect(model.protectionWarning != nil)
}

// MARK: - Pairing differs by phone

/// ntfy's docs are explicit that app deep links are Android-only: https links
/// cannot open the app, so ntfy:// exists for exactly this. On Android that
/// makes a scan open the app and subscribe in one step.
@Test @MainActor
func androidPairingUsesTheDeepLinkThatOpensTheApp() {
    let (model, _, _, _) = makeModel()
    model.setAlertEnabled(true)

    #expect(model.pairingPayload(for: .android) == "ntfy://ntfy.sh/\(model.alertTopic)")
}

/// iOS has no such scheme. The https link at least opens the topic's page, so
/// the scan does something useful rather than failing on an unknown scheme.
@Test @MainActor
func iPhonePairingUsesTheWebLinkBecauseNoSchemeExists() {
    let (model, _, _, _) = makeModel()
    model.setAlertEnabled(true)

    #expect(model.pairingPayload(for: .iPhone) == "https://ntfy.sh/\(model.alertTopic)")
}

/// No topic, no code. Encoding "ntfy://ntfy.sh/" would scan to a subscription
/// with an empty topic.
@Test @MainActor
func noTopicMeansNoPairingPayload() {
    let (model, _, _, _) = makeModel()

    #expect(model.alertTopic.isEmpty)
    #expect(model.pairingPayload(for: .android) == "")
    #expect(model.pairingPayload(for: .iPhone) == "")
}
