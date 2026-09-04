import Foundation

/// Forces the speakers to full volume and sounds the siren, restoring the
/// user's audio settings on reset.
public final class SirenResponse: Response {
    public let identifier = "siren"
    public let isAvailable = true
    public var isEnabled = true

    /// How often the volume is taken back while the siren sounds. Short enough
    /// that a muted second is all a thief gets; long enough that it is a handful
    /// of cheap CoreAudio writes a second, not a spin loop.
    public static let volumeHoldInterval: TimeInterval = 1

    private let player: SirenPlaying
    private let audio: AudioOutputControlling
    private let clock: AlarmClock
    /// Cancelled by `restoreAudioAndSilence`, which is the only teardown path.
    private var volumeHold: ScheduledWork?
    /// Captured on the first fire only, so a repeat fire cannot overwrite it
    /// with the already-forced state.
    private var savedState: AudioOutputState?
    /// True if the siren is actually producing sound. False if fire was called
    /// but the player failed to start.
    public private(set) var isSounding = false

    public init(player: SirenPlaying, audio: AudioOutputControlling, clock: AlarmClock) {
        self.player = player
        self.audio = audio
        self.clock = clock
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
        scheduleVolumeHold()
    }

    /// Forcing the volume once, at the instant the siren starts, is only enough
    /// against a thief who does not think to press mute. Anyone who does gets a
    /// permanently silent alarm, which is the failure this whole app exists to
    /// avoid. So the volume is taken back for as long as the siren is sounding.
    ///
    /// Re-arms itself rather than repeating on a timer so there is exactly one
    /// piece of pending work to cancel, and so a cancelled hold cannot fire once
    /// more after the user has disarmed and had their settings restored.
    private func scheduleVolumeHold() {
        volumeHold?.cancel()
        volumeHold = clock.schedule(after: Self.volumeHoldInterval) { [weak self] in
            guard let self, self.savedState != nil else { return }
            // Deliberately ignored: a failure here means this one attempt did
            // not land, and the next is a second away. `isSounding` is not
            // downgraded, because it reports whether the siren started, and
            // re-reporting it from a transient write failure would flap.
            try? self.audio.forceMaxVolumeOnBuiltInSpeakers()
            self.scheduleVolumeHold()
        }
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
        // Before the restore, never after: a hold that fired in between would
        // put the Mac back to full volume with the alarm already over.
        volumeHold?.cancel()
        volumeHold = nil
        player.stop()
        isSounding = false
        if let savedState {
            audio.restore(savedState)
            self.savedState = nil
        }
    }
}
