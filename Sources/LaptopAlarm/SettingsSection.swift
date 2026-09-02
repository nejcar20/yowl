import SwiftUI
import AlarmCore

/// Collapsible settings, inline in the menu bar popover.
///
/// Every control is disabled while armed. That is a security property, not a
/// UX nicety: switching off the siren while it is screaming, or stretching the
/// grace window mid-countdown, would be a disarm that never meets the passcode.
struct SettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    @State private var currentPasscode = ""
    @State private var newPasscode = ""

    var body: some View {
        DisclosureGroup("Settings", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if model.settingsLocked {
                    Text("Disarm to change settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if model.motionAvailable {
                    Group {
                        Text("What triggers the alarm").font(.caption).foregroundStyle(.secondary)
                        Text("Charger unplugged — always on")
                            .font(.caption2).foregroundStyle(.secondary)
                        Toggle("Laptop is moved (uses the camera)", isOn: Binding(
                            get: { model.motionEnabled },
                            set: { model.setMotionEnabled($0) }))
                        Text("The camera light stays on while armed. Video never leaves your Mac and is never recorded.")
                            .font(.caption2).foregroundStyle(.secondary)

                        if model.motionEnabled {
                            HStack {
                                Button(model.isCalibrating ? "Stop test" : "Test sensitivity") {
                                    if model.isCalibrating { model.stopCalibration() }
                                    else { model.startCalibration() }
                                }
                                if let score = model.liveMotionScore {
                                    Text(String(format: "%.4f", score))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(score > model.motionThreshold ? Color.red : Color.secondary)
                                }
                            }
                            if model.isCalibrating {
                                Text("Nudge the laptop: the number should jump. Wave a hand in front of it: the number should not.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                }

                Group {
                    Text("When the alarm fires").font(.caption).foregroundStyle(.secondary)
                    // Only features this build can actually run are offered.
                    // An unavailable feature is absent, not shown-and-disabled,
                    // so a sandboxed build never advertises what it dropped.
                    if model.sirenAvailable {
                        Toggle("Sound the siren", isOn: Binding(
                            get: { model.sirenEnabled },
                            set: { model.setSirenEnabled($0) }))
                    }
                    if model.screenLockAvailable {
                        Toggle("Lock the screen", isOn: Binding(
                            get: { model.screenLockEnabled },
                            set: { model.setScreenLockEnabled($0) }))
                    }
                }

                Divider()

                Group {
                    HStack {
                        Text("Grace period").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(model.graceSeconds == 0
                             ? "None" : "\(Int(model.graceSeconds))s")
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(get: { model.graceSeconds },
                                          set: { model.setGraceSeconds($0) }),
                           in: GraceLimits.minimum...GraceLimits.maximum,
                           step: 1)
                    Text(model.graceSeconds == 0
                         ? "The siren fires the instant the charger is pulled."
                         : "You get \(Int(model.graceSeconds))s to disarm before the siren starts.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()

                Toggle("Start at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))

                Divider()

                Group {
                    Text("Change passcode").font(.caption).foregroundStyle(.secondary)
                    SecureField("Current", text: $currentPasscode)
                    SecureField("New", text: $newPasscode)
                    Button("Change") {
                        model.changePasscode(current: currentPasscode, new: newPasscode)
                        currentPasscode = ""
                        newPasscode = ""
                    }
                    .disabled(currentPasscode.isEmpty || newPasscode.isEmpty)
                }

                if let message = model.settingsMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
            .disabled(model.settingsLocked)
        }
        .font(.callout)
    }
}
