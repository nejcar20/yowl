import SwiftUI

struct DisarmPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Passcode", text: $model.passcodeEntry)
                .onSubmit { model.disarm() }
            Button("Disarm") { model.disarm() }
                .disabled(model.passcodeEntry.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }
}
