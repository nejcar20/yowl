import SwiftUI
import AlarmCore

final class AppModel: ObservableObject {
    @Published private(set) var state: AlarmState = .disarmed
    @Published var passcodeEntry = ""
    @Published var errorMessage: String?
    @Published var needsPasscodeSetup: Bool
    /// Whether the siren is actually producing sound, distinct from whether the
    /// alarm is firing: audio-device failures should be visible, not silent.
    @Published private(set) var isSirenSounding = false

    private let engine: AlarmEngine
    private let passcodes: KeychainPasscodeStore
    private let siren: SirenResponse
    private var sirenWatchTask: Task<Void, Never>?

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
            self?.updateSirenWatcher(for: newState)
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
        } catch AlarmEngineError.noPasscodeSet {
            needsPasscodeSetup = true
            errorMessage = "Set a passcode before arming."
        } catch {
            errorMessage = "Could not arm."
        }
    }

    func disarm() {
        if engine.disarm(passcode: passcodeEntry) {
            passcodeEntry = ""
            errorMessage = nil
        } else {
            passcodeEntry = ""
            errorMessage = "Wrong passcode."
        }
    }

    /// The siren's `fire()` runs asynchronously just after the state
    /// transition to `.firing` is observed here, so `isSounding` briefly
    /// lags. Poll for a moment rather than reporting a stale "silent" status.
    private func updateSirenWatcher(for state: AlarmState) {
        guard case .firing = state else {
            sirenWatchTask?.cancel()
            sirenWatchTask = nil
            isSirenSounding = false
            return
        }
        guard sirenWatchTask == nil else { return }
        sirenWatchTask = Task { [weak self] in
            for _ in 0..<20 {
                guard let self, case .firing = self.state else { return }
                self.isSirenSounding = self.siren.isSounding
                if self.isSirenSounding { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
