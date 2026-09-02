import SwiftUI
import AlarmCore
import ServiceManagement

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
    /// Seconds left in the grace window. Nil unless counting down.
    @Published private(set) var graceRemaining: Int?
    /// Settings, mirrored for the UI. Writes go through the `set…` methods so
    /// preference storage and the live objects can never disagree.
    @Published private(set) var sirenEnabled = true
    @Published private(set) var screenLockEnabled = true
    @Published private(set) var graceSeconds: TimeInterval = GraceLimits.defaultValue
    @Published private(set) var launchAtLogin = false
    @Published private(set) var settingsMessage: String?
    @Published private(set) var motionEnabled = false
    @Published private(set) var liveMotionScore: Double?
    @Published private(set) var isCalibrating = false

    private let engine: AlarmEngine
    private let passcodes: KeychainPasscodeStore
    private let siren: SirenResponse
    private let screenLock: ScreenLockResponse
    private let powerTrigger: PowerTrigger
    private let motionTrigger: MotionTrigger
    private let preferences: PreferenceStoring
    private var countdownTask: Task<Void, Never>?

    init(preferences: PreferenceStoring = UserDefaultsPreferences()) {
        self.preferences = preferences
        let passcodes = KeychainPasscodeStore()
        self.passcodes = passcodes
        self.needsPasscodeSetup = !passcodes.hasPasscode

        let trigger = PowerTrigger(monitor: IOKitPowerSourceMonitor(),
                                   graceSeconds: preferences.graceSeconds)
        self.powerTrigger = trigger
        let motion = MotionTrigger(source: CameraFrameSource(framesPerSecond: 5),
                                   detector: EgoMotionDetector(),
                                   graceSeconds: preferences.graceSeconds)
        self.motionTrigger = motion
        let siren = SirenResponse(player: AVSirenPlayer(),
                                  audio: CoreAudioOutputControl())
        self.siren = siren
        // LoginFrameworkScreenLocker never calls dlclose (its function pointer
        // would dangle), so it must be instantiated exactly once per process.
        // AppModel is itself a single @StateObject for the app's lifetime, so
        // this initializer is that one place.
        let lock = ScreenLockResponse(locker: LoginFrameworkScreenLocker())
        self.screenLock = lock

        engine = AlarmEngine(triggers: [trigger, motion],
                             responses: [siren, lock],
                             clock: SystemClock(),
                             passcodes: passcodes,
                             sleepAssertion: IOKitSleepAssertion())
        engine.onStateChange = { [weak self] newState in
            self?.state = newState
            self?.updateCountdown(for: newState)
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

        // Apply stored preferences to the live objects. Availability is decided
        // by the build and must never be overridden here: an unavailable
        // feature stays off whatever the stored preference says.
        siren.isEnabled = siren.isAvailable && preferences.isEnabled(siren.identifier)
        lock.isEnabled = lock.isAvailable && preferences.isEnabled(lock.identifier)
        trigger.isEnabled = trigger.isAvailable && preferences.isEnabled(trigger.identifier)
        // Motion is the one feature that stays off until asked for: it holds
        // the camera open, and the green light is hardware-enforced. Everything
        // else defaults on; this one requires a deliberate decision.
        motion.isEnabled = motion.isAvailable
            && preferences.isEnabled(motion.identifier, default: false)
        motionEnabled = motion.isActive
        sirenEnabled = siren.isActive
        screenLockEnabled = lock.isActive
        graceSeconds = preferences.graceSeconds
        launchAtLogin = Self.loginItemIsRegistered()
        // Set at init too, not only when the toggle is touched: a relaunch
        // while approval is still pending would otherwise show the toggle on
        // with no explanation, and the user would believe they are protected at
        // every login when they are not.
        settingsMessage = Self.pendingApprovalMessage()
    }

    // MARK: - Grace countdown

    /// A silent grace window reads as a broken alarm without a countdown:
    /// "Triggered" with nothing happening looks identical to a siren that
    /// failed. Showing the seconds makes the silence legible.
    private func updateCountdown(for newState: AlarmState) {
        countdownTask?.cancel()
        countdownTask = nil

        guard case let .grace(until, _) = newState else {
            graceRemaining = nil
            return
        }
        graceRemaining = Self.secondsRemaining(until: until)
        // A Task rather than a Timer: it inherits this object's main-actor
        // isolation, so the countdown needs no escape hatch to touch state.
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, case let .grace(deadline, _) = self.state else { return }
                let remaining = Self.secondsRemaining(until: deadline)
                // Publish only on change: the loop ticks 4x/s for a value that
                // changes 1x/s, and every publish re-renders the popover
                // including the focused disarm field.
                if remaining != self.graceRemaining { self.graceRemaining = remaining }
            }
        }
    }

    private static func secondsRemaining(until deadline: Date) -> Int {
        max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }

    // MARK: - Settings

    /// Settings are frozen while armed. This is a security property, not a UX
    /// nicety: being able to switch off the siren while it is screaming, or
    /// stretch the grace window mid-countdown, would be a disarm that never
    /// meets the passcode.
    var settingsLocked: Bool { isArmed }

    /// A response the user can switch off. Only the siren and the screen lock
    /// today; trigger toggles stay hidden until a second trigger exists, since
    /// unchecking the only one just makes arming refuse.
    /// Every setter clamps against `isAvailable`. Without the clamp the UI can
    /// claim a security feature is on while the engine has already dropped it —
    /// exactly the lie the two-axis design exists to prevent.
    func setSirenEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        let applied = enabled && siren.isAvailable
        siren.isEnabled = applied
        preferences.setEnabled(applied, for: siren.identifier)
        sirenEnabled = siren.isActive
        warnIfNoResponsesLeft()
    }

    func setScreenLockEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        let applied = enabled && screenLock.isAvailable
        screenLock.isEnabled = applied
        preferences.setEnabled(applied, for: screenLock.identifier)
        screenLockEnabled = screenLock.isActive
        warnIfNoResponsesLeft()
    }

    var motionAvailable: Bool { motionTrigger.isAvailable }

    func setMotionEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        let applied = enabled && motionTrigger.isAvailable
        motionTrigger.isEnabled = applied
        preferences.setEnabled(applied, for: motionTrigger.identifier)
        motionEnabled = motionTrigger.isActive
        if !applied { stopCalibration() }
    }

    /// The live score readout. Only runs while the settings pane asks for it,
    /// so the camera light is never on without a visible reason.
    func startCalibration() {
        guard !settingsLocked, motionTrigger.isAvailable, !isCalibrating else { return }
        do {
            try motionTrigger.startCalibration { [weak self] score in
                self?.liveMotionScore = score.value
            }
            isCalibrating = true
            settingsMessage = nil
        } catch {
            settingsMessage = "Could not open the camera. Grant access in System Settings ▸ Privacy & Security ▸ Camera."
        }
    }

    func stopCalibration() {
        guard isCalibrating else { return }
        motionTrigger.stopCalibration()
        isCalibrating = false
        liveMotionScore = nil
    }

    var motionThreshold: Double { motionTrigger.detector.threshold }

    var sirenAvailable: Bool { siren.isAvailable }
    var screenLockAvailable: Bool { screenLock.isAvailable }

    /// Reads the live objects, not the UI mirrors: a mirror can say "on" for a
    /// response the engine dropped, which is precisely when this warning matters.
    private func warnIfNoResponsesLeft() {
        let nothingWillHappen = !siren.isActive && !screenLock.isActive
        if nothingWillHappen {
            settingsMessage = "Nothing will happen when the alarm fires. It will still detect the theft — it just won't react."
        } else if settingsMessage?.hasPrefix("Nothing will happen") == true {
            // Only clear our own message; don't clobber "Passcode changed."
            settingsMessage = nil
        }
    }

    func setGraceSeconds(_ seconds: TimeInterval) {
        guard !settingsLocked else { return }
        preferences.graceSeconds = seconds
        // Read back: the store clamps, so this is the value actually applied.
        let applied = preferences.graceSeconds
        powerTrigger.graceSeconds = applied
        graceSeconds = applied
    }

    /// `SMAppService` only works from a real .app bundle and can throw — an
    /// unbundled debug run, or a copy macOS does not trust. Failing loudly here
    /// is right: silently not registering would mean the user believes they are
    /// protected at every login when they are not.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !settingsLocked else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = Self.loginItemIsRegistered()
            // register() commonly lands in .requiresApproval rather than
            // .enabled. Reporting that as plain failure would snap the toggle
            // back with no explanation, and the user would reasonably conclude
            // the app is broken — or worse, think they are protected at every
            // login when they are not.
            settingsMessage = Self.pendingApprovalMessage()
        } catch {
            launchAtLogin = Self.loginItemIsRegistered()
            settingsMessage = "Could not change the login item. Run the app from /Applications and try again."
        }
    }

    /// Non-nil while macOS has the login item registered but unapproved.
    private static func pendingApprovalMessage() -> String? {
        SMAppService.mainApp.status == .requiresApproval
            ? "Approve LaptopAlarm in System Settings ▸ General ▸ Login Items to start it at login."
            : nil
    }

    private static func loginItemIsRegistered() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    func changePasscode(current: String, new: String) {
        guard !settingsLocked else { return }
        do {
            if try passcodes.changePasscode(current: current, new: new) {
                settingsMessage = "Passcode changed."
            } else {
                settingsMessage = "That is not the current passcode."
            }
        } catch PasscodeError.empty {
            settingsMessage = "Enter a new passcode."
        } catch {
            settingsMessage = "Could not change the passcode."
        }
    }

    var isArmed: Bool { state != .disarmed }
    var isFiring: Bool { if case .firing = state { return true }; return false }

    /// First-run only. Guarded because an unguarded overwrite is a disarm
    /// bypass: set a new passcode mid-alarm, then use it to stop the siren
    /// without ever knowing the old one. Changing an existing passcode goes
    /// through `changePasscode`, which demands the current one.
    func setPasscode(_ passcode: String) {
        guard !settingsLocked, !passcodes.hasPasscode else { return }
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
        // The alarm needs exclusive use of the camera, and a calibration
        // session left running would hold it open.
        stopCalibration()
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
    deinit { countdownTask?.cancel() }

    func restoreAudioBeforeTermination() {
        siren.restoreAudioAndSilence()
    }
}
