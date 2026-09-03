import Foundation
import IOKit.hid

public protocol LidAngleSensing: AnyObject {
    var isAvailable: Bool { get }
    /// Current hinge angle in degrees, or nil if it cannot be read.
    var angle: Double? { get }
    func startReading(_ onAngle: @escaping (Double) -> Void)
    func stopReading()
}

/// Reads the hinge angle from the Apple Silicon lid-angle sensor.
///
/// Verified present on Mac17,9 / macOS 26.5: HID device VendorID 0x05AC,
/// ProductID 0x8104, usage page 0x20 (Sensors). The angle itself is element
/// usage 0x47F with a logical range of 0-360; the collection's primary usage
/// 0x8A is NOT the angle and reads zero. No TCC prompt, no entitlement, no root.
///
/// Intel Macs and the sandboxed App Store build have no access to this, which is
/// what `isAvailable` is for.
public final class HIDLidAngleSensor: LidAngleSensing {
    private static let vendorID = 0x05AC
    private static let productID = 0x8104
    private static let sensorUsagePage = 0x20
    private static let angleUsage = 0x47F

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var angleElement: IOHIDElement?
    private var pollTask: Task<Void, Never>?

    public init() { openDevice() }

    private func openDevice() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.sensorUsagePage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              let elements = IOHIDDeviceCopyMatchingElements(
                  device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        else { return }
        self.manager = manager
        self.device = device
        self.angleElement = elements.first { IOHIDElementGetUsage($0) == UInt32(Self.angleUsage) }
    }

    public var isAvailable: Bool { angleElement != nil }

    public var angle: Double? {
        guard let device, let angleElement else { return nil }
        var value: Unmanaged<IOHIDValue>?
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) {
                IOHIDDeviceGetValue(device, angleElement, $0)
            }
        }
        guard result == kIOReturnSuccess, let value = value?.takeUnretainedValue()
        else { return nil }
        return Double(IOHIDValueGetIntegerValue(value))
    }

    /// The sensor has no change notification, so it is polled. 10 Hz is well
    /// inside the time it takes to close a lid and costs nothing measurable.
    ///
    /// A Task rather than a Timer: it inherits this object's main-actor
    /// isolation, so the poll needs no escape hatch to touch state — the same
    /// reason the grace countdown uses one.
    public func startReading(_ onAngle: @escaping (Double) -> Void) {
        stopReading()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let angle = self.angle else { return }
                onAngle(angle)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func stopReading() {
        pollTask?.cancel()
        pollTask = nil
    }

    isolated deinit { stopReading() }
}

#if DEBUG
public final class FakeLidAngleSensor: LidAngleSensing {
    public let isAvailable: Bool
    public private(set) var angle: Double?
    public private(set) var isReading = false
    private var onAngle: ((Double) -> Void)?

    public init(angle: Double, isAvailable: Bool = true) {
        self.angle = angle
        self.isAvailable = isAvailable
    }

    public func startReading(_ onAngle: @escaping (Double) -> Void) {
        self.onAngle = onAngle
        isReading = true
    }

    public func stopReading() {
        isReading = false
        onAngle = nil
    }

    public func simulate(angle: Double) {
        self.angle = angle
        onAngle?(angle)
    }
}
#endif
