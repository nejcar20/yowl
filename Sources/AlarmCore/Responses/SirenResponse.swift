import Foundation

/// Forces the speakers to full volume and sounds the siren, restoring the
/// user's audio settings on reset.
public final class SirenResponse: Response {
    public let identifier = "siren"
    public let isAvailable = true
    public var isEnabled = true

    private let player: SirenPlaying
    private let audio: AudioOutputControlling
    /// Captured on the first fire only, so a repeat fire cannot overwrite it
    /// with the already-forced state.
    private var savedState: AudioOutputState?
    /// True if the siren is actually producing sound. False if fire was called
    /// but the player failed to start.
    public private(set) var isSounding = false

    public init(player: SirenPlaying, audio: AudioOutputControlling) {
        self.player = player
        self.audio = audio
    }

    public func fire(context: AlarmContext) async {
        if savedState == nil { savedState = audio.currentState() }

        // `forceMaxVolumeOnBuiltInSpeakers()` throws exactly when the unmute or
        // the volume write failed -- i.e. when the siren will be inaudible. We
        // still start the player (fail toward noise: a route we could not force
        // may still be audible), but we must not *claim* the siren is sounding
        // on a Mac we could not unmute. Swallowing this with `try?` is what made
        // the menu bar say "Siren sounding" on a muted machine.
        var forced = true
        do {
            try audio.forceMaxVolumeOnBuiltInSpeakers()
        } catch {
            forced = false
        }
        let started = player.start()
        isSounding = forced && started
    }

    public func reset() async {
        restoreAudioAndSilence()
    }

    /// The single teardown path for the siren: stop the player and put the
    /// user's audio settings back. Synchronous because
    /// `applicationWillTerminate` cannot await, and it must run there too --
    /// `NSApplication.terminate` does not run deinits, so without this a quit
    /// mid-alarm would leave the Mac permanently unmuted at volume 1.0 with
    /// output forced to the built-in speakers. `reset()` delegates here so
    /// there is exactly one restore implementation.
    public func restoreAudioAndSilence() {
        player.stop()
        isSounding = false
        if let savedState {
            audio.restore(savedState)
            self.savedState = nil
        }
    }
}
