import SwiftUI

@main
struct LaptopAlarmApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isFiring
                  ? "bell.badge.fill"
                  : (model.isArmed ? "lock.shield.fill" : "lock.shield"))
        }
        .menuBarExtraStyle(.window)
    }
}
