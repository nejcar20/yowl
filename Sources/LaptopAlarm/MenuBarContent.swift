import SwiftUI
import AlarmCore

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
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

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var statusText: String {
        switch model.state {
        case .disarmed: "Disarmed"
        case .armed: "Armed"
        case .grace: "Triggered — disarm now"
        case .firing: "ALARM"
        }
    }
}

struct PasscodeSetupField: View {
    @ObservedObject var model: AppModel
    @State private var entry = ""

    var body: some View {
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
