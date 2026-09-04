import SwiftUI

public struct DisarmPanel: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Unlocking the Mac is the disarm whenever the screen lock is on,
            // and it is the only one when no passcode was ever set. Showing an
            // empty passcode field then is an instruction nobody can follow.
            if model.screenLockEnabled {
                Text(model.hasPasscode
                     ? "Unlock your Mac to disarm, or enter your passcode."
                     : "Unlock your Mac to disarm.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.hasPasscode {
                SecureField("Passcode", text: $model.passcodeEntry)
                    .onSubmit { model.disarm() }
                Button("Disarm") { model.disarm() }
                    .disabled(model.passcodeEntry.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
