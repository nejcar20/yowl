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
    @State private var newPasscode = ""

    var body: some View {
        DisclosureGroup("Settings", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if model.settingsLocked {
                    Text("Disarm to change settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Group {
                    Text("What triggers the alarm").font(.caption).foregroundStyle(.secondary)
                    Toggle("Charger unplugged", isOn: Binding(
                        get: { model.powerEnabled },
                        set: { model.setPowerEnabled($0) }))
                    if model.lidAvailable {
                        Toggle("Lid is closed part-way", isOn: Binding(
                            get: { model.lidEnabled },
                            set: { model.setLidEnabled($0) }))
                    }
                    if model.networkAvailable {
                        Toggle("Wi-Fi is lost for 30 seconds", isOn: Binding(
                            get: { model.networkEnabled },
                            set: { model.setNetworkEnabled($0) }))
                    }
                    if model.motionAvailable {
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
                            HStack {
                                Text("Sensitivity").font(.caption2).foregroundStyle(.secondary)
                                Slider(value: Binding(get: { model.motionSensitivity },
                                                      set: { model.setMotionSensitivity($0) }),
                                       in: 0...1)
                                Text(String(format: "%.4f", model.motionThreshold))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text("Right for more sensitive. The alarm fires when the number above crosses this one.")
                                .font(.caption2).foregroundStyle(.secondary)

                            if model.isCalibrating {
                                Text("Nudge the laptop: the number should jump. Wave a hand in front of it: the number should not. If waving DOES move it, your background is too repetitive for this — blinds, tiles and brick confuse it.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.nothingEnabled {
                        Text("Nothing is set to watch for anything — arming will refuse.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Divider()

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
                    SecureField("New passcode", text: $newPasscode)
                    Button("Change") {
                        model.changePasscode(to: newPasscode)
                        newPasscode = ""
                    }
                    .disabled(newPasscode.isEmpty)
                }

                if let message = model.settingsMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
            .disabled(model.settingsLocked)
        }
        .font(.callout)
        // The popover closing or the group collapsing must release the camera:
        // otherwise the light stays on with no visible reason.
        .onDisappear { model.stopCalibration() }
        .onChange(of: expanded) { _, isExpanded in
            if !isExpanded { model.stopCalibration() }
        }
    }
}
