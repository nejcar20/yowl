import Foundation
import IOKit.ps
import CoreFoundation

public protocol PowerSourceMonitoring: AnyObject {
    var isOnACPower: Bool { get }
    func startMonitoring(_ onChange: @escaping (Bool) -> Void)
    func stopMonitoring()
}

/// Real implementation using IOKit. Underlying IOKit calls were verified against
/// the live system during planning, but this class is not exercised by the test suite.
public final class IOKitPowerSourceMonitor: PowerSourceMonitoring {
    private var source: CFRunLoopSource?
    private var onChange: ((Bool) -> Void)?
    private var lastKnownACPower: Bool = true

    public init() {}

    public var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
                  as String?
        else { return lastKnownACPower }
        let isAC = type == kIOPMACPowerKey
        lastKnownACPower = isAC
        return isAC
    }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
        stopMonitoring()
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        // ISOLATION INVARIANT (not checked by the compiler): this closure
        // converts to a `@convention(c)` function pointer with no diagnostic,
        // which erases its main-actor isolation — yet its body reads
        // `monitor.onChange` and `monitor.isOnACPower`, both main-actor state,
        // and `isOnACPower` mutates `lastKnownACPower`.
        //
        // It is safe *only* because of the CFRunLoopAddSource(CFRunLoopGetMain(),
        // ...) below: the run-loop source is attached to the main run loop, so
        // IOKit only ever invokes this on the main thread. Change that line to
        // any other run loop (a dedicated monitoring thread, CFRunLoopGetCurrent()
        // called off-main) and every access here becomes a data race, silently.
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<IOKitPowerSourceMonitor>
                .fromOpaque(ctx).takeUnretainedValue()
            monitor.onChange?(monitor.isOnACPower)
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        source = src
        // Load-bearing for the invariant documented above the callback: this is
        // what pins delivery to the main thread.
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    public func stopMonitoring() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        onChange = nil
    }

    // Isolated deinit runs on the class's actor (MainActor), allowing safe access to
    // main-thread-only CFRunLoopSource property without data-race diagnostics.
    isolated deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}

public final class FakePowerSourceMonitor: PowerSourceMonitoring {
    public private(set) var isOnACPower: Bool
    private var onChange: ((Bool) -> Void)?

    public init(isOnACPower: Bool) { self.isOnACPower = isOnACPower }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func stopMonitoring() { onChange = nil }

    public func simulateChange(isOnAC: Bool) {
        isOnACPower = isOnAC
        onChange?(isOnAC)
    }
}
