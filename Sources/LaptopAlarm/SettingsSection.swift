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

                Group {
                    Text("When the alarm fires").font(.caption).foregroundStyle(.secondary)
                    Toggle("Sound the siren", isOn: Binding(
                        get: { model.sirenEnabled },
                        set: { model.setSirenEnabled($0) }))
                    Toggle("Lock the screen", isOn: Binding(
                        get: { model.screenLockEnabled },
                        set: { model.setScreenLockEnabled($0) }))
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
