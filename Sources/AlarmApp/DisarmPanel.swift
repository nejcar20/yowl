import SwiftUI

public struct DisarmPanel: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Passcode", text: $model.passcodeEntry)
                .onSubmit { model.disarm() }
            Button("Disarm") { model.disarm() }
                .disabled(model.passcodeEntry.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }
}
