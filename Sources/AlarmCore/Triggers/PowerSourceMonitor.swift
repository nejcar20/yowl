import Foundation
import IOKit.ps
@preconcurrency import CoreFoundation

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
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<IOKitPowerSourceMonitor>
                .fromOpaque(ctx).takeUnretainedValue()
            monitor.onChange?(monitor.isOnACPower)
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    public func stopMonitoring() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        onChange = nil
    }

    deinit {
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
