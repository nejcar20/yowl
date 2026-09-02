import SwiftUI
import AlarmCore

final class AppModel: ObservableObject {
    @Published private(set) var state: AlarmState = .disarmed
    @Published var passcodeEntry = ""
    @Published var errorMessage: String?
    /// Non-blocking problems: armed, but with a degraded guarantee.
    @Published private(set) var warningMessage: String?
    @Published var needsPasscodeSetup: Bool
    /// Whether the siren is actually producing sound, distinct from whether the
    /// alarm is firing: audio-device failures should be visible, not silent.
    @Published private(set) var isSirenSounding = false

    private let engine: AlarmEngine
    private let passcodes: KeychainPasscodeStore
    private let siren: SirenResponse

    init() {
        let passcodes = KeychainPasscodeStore()
        self.passcodes = passcodes
        self.needsPasscodeSetup = !passcodes.hasPasscode

        let trigger = PowerTrigger(monitor: IOKitPowerSourceMonitor(),
                                   graceSeconds: 10)
        let siren = SirenResponse(player: AVSirenPlayer(),
                                  audio: CoreAudioOutputControl())
        self.siren = siren
        // LoginFrameworkScreenLocker never calls dlclose (its function pointer
        // would dangle), so it must be instantiated exactly once per process.
        // AppModel is itself a single @StateObject for the app's lifetime, so
        // this initializer is that one place.
        let lock = ScreenLockResponse(locker: LoginFrameworkScreenLocker())

        engine = AlarmEngine(triggers: [trigger],
                             responses: [siren, lock],
                             clock: SystemClock(),
                             passcodes: passcodes,
                             sleepAssertion: IOKitSleepAssertion())
        engine.onStateChange = { [weak self] newState in
            self?.state = newState
            // Clear here (not just on the next fire) so a stale "sounding"
            // status cannot survive a disarm.
            guard case .firing = newState else {
                self?.isSirenSounding = false
                return
            }
        }
        // Mirrors onStateChange: the engine tells us when it knows, rather
        // than AppModel polling siren.isSounding on its own timer.
        engine.onResponsesFired = { [weak self] in
            guard let self, case .firing = self.state else { return }
            self.isSirenSounding = self.siren.isSounding
        }
    }

    var isArmed: Bool { state != .disarmed }
    var isFiring: Bool { if case .firing = state { return true }; return false }

    func setPasscode(_ passcode: String) {
        do {
            try passcodes.setPasscode(passcode)
            needsPasscodeSetup = false
            errorMessage = nil
        } catch PasscodeError.empty {
            errorMessage = "Enter a passcode before saving."
        } catch PasscodeError.cryptoFailure {
            errorMessage = "Could not save the passcode: a system random/crypto call failed. Try again."
        } catch PasscodeError.keychain {
            errorMessage = "Could not save the passcode to the Keychain. Try again."
        } catch {
            errorMessage = "Could not save the passcode."
        }
    }

    func arm() {
        do {
            try engine.arm()
            errorMessage = nil
            // Armed, but the Mac may sleep and stop noticing the charger. Not
            // an error: the alarm is still wired up.
            warningMessage = engine.sleepAssertionFailed
                ? "Armed, but macOS refused the keep-awake request. Keep the lid open — a sleeping Mac cannot hear the charger being pulled."
                : nil
        } catch AlarmEngineError.noPasscodeSet {
            needsPasscodeSetup = true
            errorMessage = "Set a passcode before arming."
            warningMessage = nil
        } catch AlarmEngineError.noArmableTrigger {
            errorMessage = "Plug in the charger to arm. The alarm fires when the charger is pulled."
            warningMessage = nil
        } catch {
            errorMessage = "Could not arm."
            warningMessage = nil
        }
    }

    func disarm() {
        if engine.disarm(passcode: passcodeEntry) {
            passcodeEntry = ""
            errorMessage = nil
            warningMessage = nil
        } else {
            passcodeEntry = ""
            errorMessage = "Wrong passcode."
        }
    }

    /// Called from `applicationWillTerminate`. `NSApplication.terminate` does
    /// not run `@StateObject` deinits, so without this a quit (or a crash-path
    /// terminate) while the siren is firing would leave the Mac permanently
    /// unmuted at volume 1.0 with output forced to the built-in speakers.
    /// Reuses `SirenResponse`'s single restore path rather than duplicating it.
    /// This also silences the siren, which is correct: the process is dying
    /// either way, and vandalised audio settings would outlive it.
    func restoreAudioBeforeTermination() {
        siren.restoreAudioAndSilence()
    }
}
