import SwiftUI

/// Owns the `AppModel` so `applicationWillTerminate` is guaranteed to have it.
///
/// `NSApplication.terminate` tears the process down without running SwiftUI
/// `@StateObject` deinits, so the audio restore has to hang off the AppKit
/// lifecycle rather than off object lifetime.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillTerminate(_ notification: Notification) {
        model.restoreAudioBeforeTermination()
    }
}

@main
struct LaptopAlarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon lives in its own view so `@ObservedObject` can re-render it: the
/// model hangs off the delegate, which SwiftUI does not observe transitively.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.isFiring
              ? "bell.badge.fill"
              : (model.isArmed ? "lock.shield.fill" : "lock.shield"))
    }
}
