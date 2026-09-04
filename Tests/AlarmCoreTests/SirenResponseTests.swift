import Testing
import Foundation
@testable import AlarmCore

private let ctx = AlarmContext(trigger: TriggerID("power"),
                               firedAt: Date(timeIntervalSince1970: 0))

private func makeResponse(volume: Float = 0.3, muted: Bool = true)
    -> (SirenResponse, FakeSirenPlayer, FakeAudioOutputControl) {
    let player = FakeSirenPlayer()
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: volume, muted: muted))
    return (SirenResponse(player: player, audio: audio, clock: TestClock()), player, audio)
}

@Test func firingStartsThePlayerAtFullVolume() async {
    let (response, player, audio) = makeResponse()
    await response.fire(context: ctx)
    #expect(player.isPlaying == true)
    #expect(response.isSounding == true)
    #expect(audio.state.volume == 1.0)
    #expect(audio.state.muted == false)
}

@Test func resettingStopsThePlayerAndRestoresAudio() async {
    let (response, player, audio) = makeResponse(volume: 0.3, muted: true)
    await response.fire(context: ctx)
    await response.reset()
    #expect(player.isPlaying == false)
    #expect(audio.state == AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
}

// Firing twice must not overwrite the saved state with the forced state, or
// disarming would leave the machine at full volume.
@Test func firingTwiceStillRestoresTheOriginalVolume() async {
    let (response, _, audio) = makeResponse(volume: 0.3, muted: false)
    await response.fire(context: ctx)
    await response.fire(context: ctx)
    await response.reset()
    #expect(audio.state.volume == 0.3)
}

@Test func resettingWithoutFiringIsHarmless() async {
    let (response, player, audio) = makeResponse(volume: 0.3, muted: false)
    await response.reset()
    #expect(player.stopCount == 1)
    #expect(audio.restoredStates.isEmpty)
}

@Test func sirenIsAlwaysAvailable() {
    let (response, _, _) = makeResponse()
    #expect(response.isAvailable == true)
    #expect(response.identifier == "siren")
}

@Test func firingReportsNotSoundingWhenPlayerFailsToStart() async {
    let player = FakeSirenPlayer()
    player.shouldFailStart = true
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
    let response = SirenResponse(player: player, audio: audio, clock: TestClock())

    await response.fire(context: ctx)
    #expect(response.isSounding == false)
    #expect(player.isPlaying == false)
    #expect(player.startCount == 1)
}

@Test func resettingClearsIsSoundingFlag() async {
    let (response, _, _) = makeResponse()
    await response.fire(context: ctx)
    #expect(response.isSounding == true)
    await response.reset()
    #expect(response.isSounding == false)
}

// The whole point of `forceMaxVolumeOnBuiltInSpeakers()` throwing is that it
// throws exactly when the siren will be inaudible (unmute or volume write
// failed). The siren still fires -- failing toward noise -- but the UI must not
// claim "Siren sounding" on a Mac we could not unmute. Before this fix,
// `try?` discarded the throw and `isSounding` tracked only the player.
@Test func firingReportsNotSoundingWhenForcingTheAudioFails() async {
    let player = FakeSirenPlayer()
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
    audio.shouldFailForce = true
    let response = SirenResponse(player: player, audio: audio, clock: TestClock())

    await response.fire(context: ctx)
    // The player did start: we still fire toward noise.
    #expect(player.startCount == 1)
    #expect(player.isPlaying == true)
    // But we do not claim it is audible.
    #expect(response.isSounding == false)
}

// Guards the other half of the conjunction: a successful force plus a
// successful start is the only combination that reports sounding.
@Test func firingReportsSoundingOnlyWhenBothForceAndStartSucceed() async {
    let player = FakeSirenPlayer()
    player.shouldFailStart = true
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
    audio.shouldFailForce = true
    let response = SirenResponse(player: player, audio: audio, clock: TestClock())

    await response.fire(context: ctx)
    #expect(response.isSounding == false)
}

// A failed force must not stop the saved state from being restored later, or
// disarming would leave the user's audio settings behind.
@Test func resetStillRestoresAudioAfterAFailedForce() async {
    let player = FakeSirenPlayer()
    let original = AudioOutputState(deviceID: 1, volume: 0.3, muted: true)
    let audio = FakeAudioOutputControl(state: original)
    audio.shouldFailForce = true
    let response = SirenResponse(player: player, audio: audio, clock: TestClock())

    await response.fire(context: ctx)
    await response.reset()
    #expect(audio.restoredStates == [original])
    #expect(response.isSounding == false)
}

// MARK: - Holding the volume against someone actively fighting it

/// The siren forced the volume once, at the instant it started. A thief who
/// pressed the mute key one second later silenced the alarm permanently -- the
/// app never looked again. "Screams over mute" was only true for people who did
/// not think to press mute.
@Test func theSirenTakesTheVolumeBackAfterSomeoneMutesIt() async {
    let clock = TestClock()
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.3, muted: false))
    let response = SirenResponse(player: FakeSirenPlayer(), audio: audio, clock: clock)

    await response.fire(context: ctx)
    #expect(audio.state.muted == false)

    audio.simulateExternalMute()
    #expect(audio.state.muted == true)

    clock.advance(by: SirenResponse.volumeHoldInterval)

    #expect(audio.state.muted == false)
    #expect(audio.state.volume == 1.0)
}

/// It has to keep doing it, not just once: a thief who mutes twice is not a
/// harder problem than one who mutes once.
@Test func theSirenKeepsTakingTheVolumeBack() async {
    let clock = TestClock()
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.3, muted: false))
    let response = SirenResponse(player: FakeSirenPlayer(), audio: audio, clock: clock)
    await response.fire(context: ctx)

    for _ in 0..<5 {
        audio.simulateExternalMute()
        clock.advance(by: SirenResponse.volumeHoldInterval)
        #expect(audio.state.muted == false)
    }
}

/// And it must stop the moment the alarm does. A siren that kept forcing the
/// volume after disarm would be a worse bug than the one being fixed: the Mac
/// would be stuck at full volume with nothing to explain it.
@Test func takingTheVolumeBackStopsWhenTheAlarmStops() async {
    let clock = TestClock()
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
    let response = SirenResponse(player: FakeSirenPlayer(), audio: audio, clock: clock)
    await response.fire(context: ctx)
    await response.reset()

    let afterReset = audio.forceCount
    clock.advance(by: SirenResponse.volumeHoldInterval * 10)

    #expect(audio.forceCount == afterReset)
    #expect(audio.state == AudioOutputState(deviceID: 1, volume: 0.3, muted: true))
}
