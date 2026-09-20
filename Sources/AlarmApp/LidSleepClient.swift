import Foundation
import ServiceManagement
import os
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

    public var stateDescription: String {
        switch installationState {
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for your approval in System Settings"
        case .notRegistered: return "not registered"
        case .notFound: return "not found in this copy of the app"
        @unknown default: return "unknown"
        }
    }

    /// Asks macOS to register the daemon. The user then approves it in System
    /// Settings; there is no way to grant it silently, which is as it should be
    /// for something that runs as root.
    public func install() throws {
        try SMAppService.daemon(plistName: Self.daemonPlistName).register()
    }

    public func uninstall() async throws {
        // Unregister FIRST. The previous order called release() first, which
        // opens an XPC connection to the very daemon being removed -- and when
        // that daemon never starts, the call never returns, the unregister
        // never runs, and the settings switch sticks on with no way to turn it
        // off. Tearing down the connection cannot depend on the connection.
        connection?.invalidate()
        connection = nil
        try await SMAppService.daemon(plistName: Self.daemonPlistName).unregister()
    }

    /// Set once a call has failed, so a dead helper is asked once and then left
    /// alone. Without this every hold and release retries a connection that is
    /// not coming back, and the UI waits on each one.
    private var isKnownUnreachable = false

    private func liveConnection() -> NSXPCConnection? {
        guard isAvailable, !isKnownUnreachable else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: YowlLidHelperService.machServiceName,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: YowlLidHelper.self)
            // A dropped helper must not leave a stale proxy that silently does
            // nothing: drop the connection so the next call rebuilds it.
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                    self?.isKnownUnreachable = true
                }
            }
            c.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection
    }

    public func hold() async -> Bool {
        await call { helper, done in helper.holdSleep { done($0) } }
    }

    public func release() async {
        _ = await call { helper, done in helper.releaseSleep { done($0) } }
    }

    /// Runs one helper call, resolving false if XPC fails instead of waiting
    /// forever. The alarm is already sounding; it cannot block on a daemon that
    /// is not coming back.
    /// Runs one helper call, resolving false if XPC fails instead of waiting
    /// forever. The alarm is already sounding; it cannot block on a daemon that
    /// is not coming back.
    ///
    /// Every closure here is explicitly `@Sendable`. This file is MainActor by
    /// default like the rest of the package, and a closure declared in that
    /// context inherits the isolation — but XPC invokes its reply and error
    /// blocks on its own queues, and an Objective-C API carries no isolation
    /// information to stop it. The result was a hard trap in
    /// `swift_task_checkIsolatedSwift` the moment the error block ran: the app
    /// crashed on arm. Marking them Sendable makes them nonisolated, which is
    /// what they have to be, and confines them to state that is safe anywhere.
    private func call(
        _ body: @escaping @Sendable (YowlLidHelper, @escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        guard let connection = liveConnection() else { return false }
        return await withCheckedContinuation { continuation in
            // XPC may call back on both paths; a continuation may be resumed
            // exactly once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { value in
                let already = resumed.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                if !already { continuation.resume(returning: value) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                finish(false)
            } as? YowlLidHelper
            guard let proxy else { return finish(false) }
            body(proxy, finish)
        }
    }
}
