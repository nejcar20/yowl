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
    @Published private(set) var powerEnabled = true
    @Published private(set) var motionEnabled = false
    @Published private(set) var snapshotEnabled = false
    @Published private(set) var lidEnabled = false
    @Published private(set) var liveMotionScore: Double?
    @Published private(set) var isCalibrating = false
    /// Shown in the main panel, not buried in settings: a configuration that
    /// cannot protect anything has to be visible before the user walks away.
    @Published private(set) var protectionWarning: String?
    /// Mirrors `ProtectionStatus` for the settings pane, so "nothing is enabled"
    /// has exactly one implementation rather than a conjunction repeated at
    /// every site that has to be edited when a trigger is added.
    @Published private(set) var nothingEnabled = false
    @Published private(set) var motionSensitivity = MotionSensitivity.sensitivity(
        forThreshold: MotionSensitivity.defaultValue)

    private let engine: AlarmEngine
    private let passcodes: KeychainPasscodeStore
    private let siren: SirenResponse
    private let screenLock: ScreenLockResponse
    private let powerTrigger: PowerTrigger
    private let motionTrigger: MotionTrigger
    private let snapshotResponse: SnapshotResponse
    private let camera: CameraFrameSource
    private let evidenceStore: FileEvidenceStore
    private let lidTrigger: LidAngleTrigger
    /// One list so a per-trigger setting cannot reach some triggers and not others.
    private var allTriggers: [any Trigger] {
        [powerTrigger, motionTrigger, lidTrigger]
    }

    /// Recomputed whenever anything that affects coverage changes.
    private func refreshProtectionWarning() {
        let status = ProtectionStatus(triggers: allTriggers)
        protectionWarning = status.warning
        nothingEnabled = status == .nothingEnabled
    }
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
        // One camera source shared by motion detection and evidence capture:
        // two sessions on one device is a conflict, and reusing the frames the
        // detector already receives means a photo from the exact moment the
        // alarm fired rather than one taken a second later.
        let camera = CameraFrameSource(framesPerSecond: 5)
        self.camera = camera
        let motion = MotionTrigger(
            source: camera,
            detector: EgoMotionDetector(threshold: preferences.motionThreshold),
            graceSeconds: preferences.graceSeconds)
        self.motionTrigger = motion
        let lid = LidAngleTrigger(sensor: HIDLidAngleSensor(),
                                  graceSeconds: preferences.graceSeconds)
        self.lidTrigger = lid
        let clock = SystemClock()
        let siren = SirenResponse(player: AVSirenPlayer(),
                                  audio: CoreAudioOutputControl())
        self.siren = siren
        // LoginFrameworkScreenLocker never calls dlclose (its function pointer
        // would dangle), so it must be instantiated exactly once per process.
        // AppModel is itself a single @StateObject for the app's lifetime, so
        // this initializer is that one place.
        let lock = ScreenLockResponse(locker: LoginFrameworkScreenLocker())
        let evidenceStore = FileEvidenceStore()
        self.evidenceStore = evidenceStore
        let snapshot = SnapshotResponse(camera: camera, store: evidenceStore, clock: clock)
        self.snapshotResponse = snapshot
        self.screenLock = lock

        engine = AlarmEngine(triggers: [trigger, motion, lid],
                             responses: [siren, lock, snapshot],
                             clock: clock,
                             passcodes: passcodes,
                             sleepAssertion: IOKitSleepAssertion())
        engine.onStateChange = { [weak self] newState in
            self?.state = newState
            self?.updateCountdown(for: newState)
            self?.refreshProtectionWarning()
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
        // Lid and network default OFF like motion: both can fire in ordinary
        // use — closing your own laptop, walking out of Wi-Fi range — so they
        // are a deliberate choice rather than something to discover by accident.
        lid.isEnabled = lid.isAvailable && preferences.isEnabled(lid.identifier, default: false)
        snapshot.isEnabled = snapshot.isAvailable
            && preferences.isEnabled(snapshot.identifier, default: false)
        camera.setRetainsStills(snapshot.isEnabled)
        snapshotEnabled = snapshot.isActive
        motionEnabled = motion.isActive
        powerEnabled = trigger.isActive
        lidEnabled = lid.isActive
        motionSensitivity = MotionSensitivity.sensitivity(forThreshold: preferences.motionThreshold)
        refreshProtectionWarning()
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

    /// Three different reasons arming can be refused, and telling the user the
    /// wrong one is worse than saying nothing.
    /// Derived from the same status the panel shows, so the refusal and the
    /// warning can never disagree about why.
    private var armRefusalReason: String {
        ProtectionStatus(triggers: allTriggers).warning
            ?? "Nothing can currently watch for a theft."
    }

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
    var snapshotAvailable: Bool { snapshotResponse.isAvailable }
    var evidenceFolder: URL { evidenceStore.directoryURL }
    var savedEvidenceCount: Int { evidenceStore.allItems().count }

    func setSnapshotEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        guard enabled else {
            snapshotResponse.isEnabled = false
            preferences.setEnabled(false, for: snapshotResponse.identifier)
            snapshotEnabled = false
            camera.setRetainsStills(false)
            return
        }
        // Same permission the motion trigger needs, asked for at the same point:
        // when the feature is switched on, not discovered at arm time.
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.camera.requestAccess()
            let applied = granted && self.snapshotResponse.isAvailable
            self.snapshotResponse.isEnabled = applied
            self.preferences.setEnabled(applied, for: self.snapshotResponse.identifier)
            self.snapshotEnabled = self.snapshotResponse.isActive
            self.camera.setRetainsStills(applied)
            self.settingsMessage = applied ? nil
                : "LaptopAlarm needs camera access to photograph a thief. Grant it in System Settings ▸ Privacy & Security ▸ Camera."
        }
    }

    func revealEvidenceFolder() {
        NSWorkspace.shared.open(evidenceStore.directoryURL)
    }

    var lidAvailable: Bool { lidTrigger.isAvailable }

    func setLidEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        let applied = enabled && lidTrigger.isAvailable
        lidTrigger.isEnabled = applied
        preferences.setEnabled(applied, for: lidTrigger.identifier)
        lidEnabled = lidTrigger.isActive
        refreshProtectionWarning()
    }


    func setPowerEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        let applied = enabled && powerTrigger.isAvailable
        powerTrigger.isEnabled = applied
        preferences.setEnabled(applied, for: powerTrigger.identifier)
        powerEnabled = powerTrigger.isActive
        refreshProtectionWarning()
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard !settingsLocked else { return }
        guard enabled else {
            motionTrigger.isEnabled = false
            preferences.setEnabled(false, for: motionTrigger.identifier)
            motionEnabled = false
            stopCalibration()
            return
        }
        // Ask for camera access here, when the user switches the feature on,
        // rather than letting them discover at arm time that it was never
        // granted. Switching on a feature that cannot run is how "Armed" comes
        // to mean nothing is watching.
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.motionTrigger.requestAccess()
            let applied = granted && self.motionTrigger.isAvailable
            self.motionTrigger.isEnabled = applied
            self.preferences.setEnabled(applied, for: self.motionTrigger.identifier)
            self.motionEnabled = self.motionTrigger.isActive
        self.refreshProtectionWarning()
            self.refreshProtectionWarning()
            self.settingsMessage = applied ? nil
                : "LaptopAlarm needs camera access for this. Grant it in System Settings ▸ Privacy & Security ▸ Camera."
        }
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

    /// Also called when the settings UI disappears. A calibration session left
    /// running keeps the green camera light on with nothing on screen
    /// explaining why, which is the most trust-destroying thing this app can do.
    func stopCalibration() {
        guard isCalibrating else { return }
        motionTrigger.stopCalibration()
        isCalibrating = false
        liveMotionScore = nil
    }

    var motionThreshold: Double { motionTrigger.detector.threshold }

    /// Presented as sensitivity, which runs the opposite way to the threshold it
    /// sets. Takes effect immediately, including mid-calibration, so the user
    /// can drag the slider while watching the live number and see the colour
    /// change at the point they choose.
    func setMotionSensitivity(_ sensitivity: Double) {
        guard !settingsLocked else { return }
        let threshold = MotionSensitivity.threshold(forSensitivity: sensitivity)
        preferences.motionThreshold = threshold
        let applied = preferences.motionThreshold
        motionTrigger.detector.threshold = applied
        motionSensitivity = MotionSensitivity.sensitivity(forThreshold: applied)
    }

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
        // Every trigger, not just the charger. The motion trigger was
        // constructed once at launch and never updated, so a user who set a
        // 30s grace and armed in the same session got 0s on it -- an accidental
        // nudge meant an instant siren with no window to stop it.
        for trigger in allTriggers { trigger.graceSeconds = applied }
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

    func changePasscode(to newPasscode: String) {
        guard !settingsLocked else { return }
        do {
            try passcodes.setPasscode(newPasscode)
            settingsMessage = "Passcode changed."
        } catch PasscodeError.empty {
            settingsMessage = "Enter a new passcode."
        } catch {
            settingsMessage = "Could not change the passcode."
        }
    }

    var isArmed: Bool { state != .disarmed }
    var isFiring: Bool { if case .firing = state { return true }; return false }

    /// Settable whenever disarmed. The armed guard is the whole protection: it
    /// stops the obvious bypass of setting a new passcode mid-alarm and using it
    /// to silence the siren. Demanding the *current* passcode on top adds
    /// nothing — a Mac sitting unlocked and disarmed has already lost, and the
    /// alarm is not what is protecting it at that point.
    func setPasscode(_ passcode: String) {
        guard !settingsLocked else { return }
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
            // Evidence capture needs frames flowing, and only the motion trigger
            // starts the camera. With snapshots on but motion off, nothing would
            // have been feeding it and every photo would have been empty.
            // Starting it cold when the alarm fires is not an option: the first
            // frame takes long enough that the thief is gone.
            if snapshotEnabled && !motionEnabled {
                try? camera.start { _ in }
            }
            errorMessage = nil
            // Armed, but the Mac may sleep and stop noticing the charger. Not
            // an error: the alarm is still wired up.
            // Armed with less cover than the user asked for is a warning, not
            // a failure: the triggers that did start are still watching.
            var warnings: [String] = []
            if engine.sleepAssertionFailed {
                warnings.append("macOS refused the keep-awake request. Keep the lid open — a sleeping Mac cannot hear the charger being pulled.")
            }
            if engine.failedTriggers.contains("motion") {
                warnings.append("The camera would not start, so movement is not being watched.")
            }
            warningMessage = warnings.isEmpty ? nil : "Armed, but: " + warnings.joined(separator: " ")
        } catch AlarmEngineError.noPasscodeSet {
            needsPasscodeSetup = true
            errorMessage = "Set a passcode before arming."
            warningMessage = nil
        } catch AlarmEngineError.noArmableTrigger {
            errorMessage = armRefusalReason
            warningMessage = nil
        } catch AlarmEngineError.noTriggerStarted {
            errorMessage = "Nothing could start watching. If movement detection is on, check camera access in System Settings ▸ Privacy & Security ▸ Camera."
            warningMessage = nil
        } catch {
            errorMessage = "Could not arm."
            warningMessage = nil
        }
    }

    func disarm() {
        if engine.disarm(passcode: passcodeEntry) {
            // Release the camera if we were the ones holding it open. The motion
            // trigger releases its own.
            if snapshotEnabled && !motionEnabled { camera.stop() }
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
