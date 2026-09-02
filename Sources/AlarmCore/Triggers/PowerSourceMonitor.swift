import Foundation
import IOKit.ps

public protocol PowerSourceMonitoring: AnyObject {
    var isOnACPower: Bool { get }
    func startMonitoring(_ onChange: @escaping (Bool) -> Void)
    func stopMonitoring()
}

/// Real implementation. Verified working 2026-09-02.
public final class IOKitPowerSourceMonitor: PowerSourceMonitoring {
    private var source: CFRunLoopSource?
    private var onChange: ((Bool) -> Void)?

    public init() {}

    public var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
                  as String?
        else { return false }
        return type == kIOPMACPowerKey
    }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
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
