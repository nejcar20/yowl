import SwiftUI
import AlarmCore

public struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText).font(.headline)

            if model.isFiring {
                Text(model.isSirenSounding ? "Siren sounding" : "Siren silent — check audio output")
                    .font(.caption)
                    .foregroundStyle(model.isSirenSounding ? Color.secondary : Color.red)
            }

            if model.needsPasscodeSetup {
                PasscodeSetupField(model: model)
            } else if model.isArmed {
                DisarmPanel(model: model)
            } else {
                Button("Arm") { model.arm() }
                    .keyboardShortcut("a")
            }

            // Above the arm button, not below it: this is the thing that
            // decides whether arming is worth doing at all.
            if !model.isArmed, let protection = model.protectionWarning {
                Text(protection)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let startup = model.startupMessage {
                Text(startup).font(.caption).foregroundStyle(.orange)
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if let warning = model.warningMessage {
                Text(warning).foregroundStyle(.orange).font(.caption)
            }

            if !model.needsPasscodeSetup {
                Divider()
                SettingsSection(model: model)
            }

            Divider()
            // Quit is a kill switch: during any grace window the screen is
            // not locked yet, so a thief who recognises the app could otherwise
            // click Quit and end the alarm without ever meeting the passcode.
            // The passcode gates disarm; it must gate quit too.
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .disabled(model.isArmed)
            if model.isArmed {
                Text("Disarm to quit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var statusText: String {
        switch model.state {
        case .disarmed: "Disarmed"
        case .armed: "Armed"
        case .grace: model.graceRemaining.map { "Triggered — \($0)s to disarm" }
                        ?? "Triggered — disarm now"
        case .firing: "ALARM"
        }
    }
}

struct PasscodeSetupField: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }
    @State private var entry = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose a passcode to disarm the alarm.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Passcode", text: $entry)
                .onSubmit { model.setPasscode(entry); entry = "" }
            Button("Save") { model.setPasscode(entry); entry = "" }
                .disabled(entry.isEmpty)
        }
    }
}
