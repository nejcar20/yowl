import Foundation

/// Forces the speakers to full volume and sounds the siren, restoring the
/// user's audio settings on reset.
public final class SirenResponse: Response {
    public let identifier = "siren"
    public let isAvailable = true

    private let player: SirenPlaying
    private let audio: AudioOutputControlling
    /// Captured on the first fire only, so a repeat fire cannot overwrite it
    /// with the already-forced state.
    private var savedState: AudioOutputState?

    public init(player: SirenPlaying, audio: AudioOutputControlling) {
        self.player = player
        self.audio = audio
    }

    public func fire(context: AlarmContext) async {
        if savedState == nil { savedState = audio.currentState() }
        try? audio.forceMaxVolumeOnBuiltInSpeakers()
        player.start()
    }

    public func reset() async {
        player.stop()
        if let savedState {
            audio.restore(savedState)
            self.savedState = nil
        }
    }
}
