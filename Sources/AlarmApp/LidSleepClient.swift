import Foundation
import ServiceManagement
import AlarmCore

/// Talks to the privileged helper over XPC, and installs it on request.
///
/// Every method fails closed. If the helper is not installed, not approved, or
/// not answering, `hold()` returns false and the alarm behaves exactly as it
/// does today — a siren that goes quiet when the lid shuts. Nothing here is
/// allowed to make the app worse than the unprivileged version.
public final class XPCLidSleepSuppressor: LidSleepSuppressing {
    /// Matches the LaunchDaemon plist embedded in the app bundle.
    public static let daemonPlistName = "com.jernejkocica.yowl.lidhelper.plist"

    private var connection: NSXPCConnection?

    public init() {}

    public var installationState: SMAppService.Status {
        SMAppService.daemon(plistName: Self.daemonPlistName).status
    }

    public var isAvailable: Bool { installationState == .enabled }

    /// Asks macOS to register the daemon. The user then approves it in System
    /// Settings; there is no way to grant it silently, which is as it should be
    /// for something that runs as root.
    public func install() throws {
        try SMAppService.daemon(plistName: Self.daemonPlistName).register()
    }

    public func uninstall() async throws {
        await release()
        connection?.invalidate()
        connection = nil
        try await SMAppService.daemon(plistName: Self.daemonPlistName).unregister()
    }

    private func proxy() -> YowlLidHelper? {
        guard isAvailable else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: YowlLidHelperService.machServiceName,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: YowlLidHelper.self)
            // A dropped helper must not leave a stale proxy that silently does
            // nothing: drop the connection so the next call rebuilds it.
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxy as? YowlLidHelper
    }

    public func hold() async -> Bool {
        guard let helper = proxy() else { return false }
        return await withCheckedContinuation { continuation in
            helper.holdSleep { ok in continuation.resume(returning: ok) }
        }
    }

    public func release() async {
        guard let helper = proxy() else { return }
        _ = await withCheckedContinuation { continuation in
            helper.releaseSleep { ok in continuation.resume(returning: ok) }
        }
    }
}
