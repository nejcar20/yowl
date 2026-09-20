import Foundation
import os
import AlarmCore
import ServiceManagement

// The privileged helper. Runs as root and does exactly one thing: turn the
// system's SleepDisabled flag on while the alarm is screaming and off again
// afterwards. That flag is the only lever that keeps a MacBook awake with the
// lid shut, which is why this needs root at all.
//
// Everything is built around one rule: the dangerous state must expire by
// itself. A Mac that cannot sleep, shut in a bag with the camera running, is a
// fire risk — so sleep is re-enabled by a watchdog, on release, on exit, and at
// startup. It is never left on because something forgot to ask again.
//
// Nonisolated throughout: XPC replies arrive on arbitrary threads, and hopping
// to an actor would mean capturing a non-Sendable reply block.
nonisolated final class Helper: NSObject, YowlLidHelper, NSXPCListenerDelegate {
    private let pmset = PmsetSleepDisabler()
    /// A generation counter rather than a cancellable work item: DispatchWorkItem
    /// is not Sendable, and an Int is. A timer only acts if its generation is
    /// still the current one.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    override init() {
        super.init()
        // A previous run may have died holding sleep off. Start from safe.
        pmset.setSleepDisabled(false)
    }

    func holdSleep(withReply reply: @escaping (Bool) -> Void) {
        // setSleepDisabled confirms the flag actually moved. On a Mac where
        // `disablesleep` is inert this is false, and the app falls back to
        // behaving exactly as the unprivileged version does rather than
        // promising a siren that a closed lid will silence anyway.
        let ok = pmset.setSleepDisabled(true)
        if ok { armWatchdog() }
        reply(ok)
    }

    func releaseSleep(withReply reply: @escaping (Bool) -> Void) {
        generation.withLock { $0 &+= 1 }   // invalidate any pending watchdog
        reply(pmset.setSleepDisabled(false))
    }

    /// Re-armed by every hold. If the app stops asking — because it crashed, was
    /// force quit, or the machine was carried off — sleep returns on its own.
    private func armWatchdog() {
        let mine = generation.withLock { (g: inout Int) -> Int in g &+= 1; return g }
        let pmset = self.pmset
        let generation = self.generation
        DispatchQueue.global().asyncAfter(deadline: .now() + LidSleepSuppression.maximumHold) {
            guard generation.withLock({ $0 }) == mine else { return }
            pmset.setSleepDisabled(false)
        }
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: YowlLidHelper.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

// Captures nothing: building a fresh disabler inside the handler keeps this a
// genuinely Sendable closure.
atexit { PmsetSleepDisabler().setSleepDisabled(false) }

// A self-test so the mechanism can be proved as root without installing
// anything: toggles the flag, reads it back, and restores it.
// A self-test so the mechanism can be proved as root without installing
// anything. It tries each spelling of the command, reads the flag back after
// every attempt, and prints whatever pmset writes to stderr -- the first
// version only checked the exit status, which reported "accepted" for a
// command that silently did nothing.
setvbuf(stdout, nil, _IONBF, 0)

if CommandLine.arguments.contains("--holdtest") {
    setvbuf(stdout, nil, _IONBF, 0)
    func flag() -> String {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        t.arguments = ["-g"]
        let o = Pipe(); t.standardOutput = o; t.standardError = FileHandle.nullDevice
        try? t.run()
        let d = o.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
        return PmsetSleepDisabler.parseSleepDisabled(
            from: String(data: d, encoding: .utf8) ?? "") ? "1" : "0"
    }
    // Run loop rather than semaphores: the first version of this harness
    // signalled a semaphore from both the reply and the error handler and
    // tripped libdispatch's own assertion, which looked like a product crash.
    func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    print("SleepDisabled before : \(flag())")
    let c = NSXPCConnection(machServiceName: YowlLidHelperService.machServiceName,
                            options: .privileged)
    c.remoteObjectInterface = NSXPCInterface(with: YowlLidHelper.self)
    c.invalidationHandler = { print("connection INVALIDATED (daemon unreachable)") }
    c.interruptionHandler = { print("connection INTERRUPTED (daemon died)") }
    c.resume()

    let proxy = c.remoteObjectProxyWithErrorHandler { err in
        print("XPC ERROR: \(err.localizedDescription)")
    } as? YowlLidHelper
    guard let proxy else { print("no proxy"); exit(1) }

    proxy.holdSleep { ok in print("holdSleep replied: \(ok)") }
    settle(3)
    print("SleepDisabled during : \(flag())")

    proxy.releaseSleep { ok in print("releaseSleep replied: \(ok)") }
    settle(3)
    print("SleepDisabled after  : \(flag())")
    exit(0)
}

if CommandLine.arguments.contains("--status") {
    print("bundle       : \(Bundle.main.bundlePath)")
    print("bundle id    : \(Bundle.main.bundleIdentifier ?? "(none)")")
    let plist = "com.jernejkocica.yowl.lidhelper.plist"
    let path = Bundle.main.bundlePath + "/Contents/Library/LaunchDaemons/" + plist
    print("daemon plist : \(FileManager.default.fileExists(atPath: path) ? "present" : "MISSING") \(path)")
    let svc = SMAppService.daemon(plistName: plist)
    let names: [SMAppService.Status: String] = [
        .notRegistered: "notRegistered", .enabled: "enabled",
        .requiresApproval: "requiresApproval", .notFound: "notFound"]
    print("SMAppService : \(names[svc.status] ?? "raw(\(svc.status.rawValue))")")
    if CommandLine.arguments.contains("--unregister") {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { try await svc.unregister(); print("unregister   : ok") }
            catch { print("unregister   : FAILED \(error)") }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        print("status now   : \(names[svc.status] ?? "raw(\(svc.status.rawValue))")")
    }
    if CommandLine.arguments.contains("--register") {
        do { try svc.register(); print("register     : ok") }
        catch { print("register     : FAILED \(error)") }
        print("status now   : \(names[svc.status] ?? "raw(\(svc.status.rawValue))")")
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    func run(_ args: [String]) -> (Int32, String, String) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        t.arguments = args
        let o = Pipe(), e = Pipe()
        t.standardOutput = o; t.standardError = e
        try? t.run()
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        return (t.terminationStatus,
                String(data: od, encoding: .utf8) ?? "",
                String(data: ed, encoding: .utf8) ?? "")
    }
    func flag() -> String {
        let (_, out, _) = run(["-g"])
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return "(absent)"
    }

    print("running as root : \(getuid() == 0)")
    print("flag initially  : \(flag())")
    for variant in [["-a", "disablesleep", "1"],
                    ["disablesleep", "1"],
                    ["-b", "disablesleep", "1"],
                    ["-c", "disablesleep", "1"]] {
        let (code, _, err) = run(variant)
        let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
        print("pmset \(variant.joined(separator: " "))")
        print("   exit \(code)\(trimmed.isEmpty ? "" : "  stderr: \(trimmed)")")
        print("   flag now: \(flag())")
        _ = run(["-a", "disablesleep", "0"])
        _ = run(["disablesleep", "0"])
    }
    print("flag restored   : \(flag())")
    exit(0)
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: YowlLidHelperService.machServiceName)
listener.delegate = helper
listener.resume()
RunLoop.main.run()
