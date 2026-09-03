import Foundation
import CoreWLAN

public protocol NetworkMonitoring: AnyObject {
    var isAvailable: Bool { get }
    var isLinkUp: Bool { get }
    func startMonitoring(_ onSample: @escaping (Bool) -> Void)
    func stopMonitoring()
}

/// Watches whether the Wi-Fi link is up.
///
/// Deliberately does NOT read the network name. `CWInterface.ssid()` returns nil
/// without Location Services authorisation — verified on macOS 26.5 — so a
/// trusted-network trigger would need a second privacy prompt on top of the
/// camera. Knowing the name only distinguishes "moved to a different network",
/// which is not the theft case: someone carrying the laptop away drops the link
/// either way. Link state and signal strength read fine with no permission at
/// all.
public final class WiFiLinkMonitor: NetworkMonitoring {
    private let client = CWWiFiClient.shared()
    private var pollTask: Task<Void, Never>?

    public init() {}

    public var isAvailable: Bool { client.interface() != nil }

    /// RSSI is zero when there is no association, which is a permission-free way
    /// to ask "are we still on a network?".
    public var isLinkUp: Bool {
        guard let interface = client.interface(), interface.powerOn() else { return false }
        return interface.rssiValue() != 0
    }

    public func startMonitoring(_ onSample: @escaping (Bool) -> Void) {
        stopMonitoring()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                onSample(self.isLinkUp)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    isolated deinit { stopMonitoring() }
}

/// Fires when the Wi-Fi link stays down for several consecutive samples.
///
/// Requires a run of drops rather than one: Wi-Fi blips constantly, and firing
/// a maximum-volume siren on a single dropped sample would make the machine
/// unusable on any real network.
public final class NetworkTrigger: Trigger {
    public let id = TriggerID("network")
    public var identifier: String { id.rawValue }
    public var isEnabled = false
    public var graceSeconds: TimeInterval

    public let consecutiveDropsRequired: Int

    private let monitor: NetworkMonitoring
    private var consecutiveDrops = 0
    private var onFire: ((TriggerID) -> Void)?

    public init(monitor: NetworkMonitoring, consecutiveDropsRequired: Int = 3,
                graceSeconds: TimeInterval) {
        self.monitor = monitor
        self.consecutiveDropsRequired = max(1, consecutiveDropsRequired)
        self.graceSeconds = graceSeconds
    }

    public var isAvailable: Bool { monitor.isAvailable }

    /// Already disconnected means there is no drop left to observe — the same
    /// reasoning as the charger trigger refusing when the charger is already out.
    public var canFireNow: Bool { monitor.isAvailable && monitor.isLinkUp }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        // Clear any run from a previous session, or one new drop could complete
        // it and fire immediately on arming.
        consecutiveDrops = 0
        monitor.startMonitoring { [weak self] isLinkUp in
            guard let self else { return }
            guard !isLinkUp else {
                consecutiveDrops = 0
                return
            }
            consecutiveDrops += 1
            if consecutiveDrops == consecutiveDropsRequired {
                self.onFire?(self.id)
            }
        }
    }

    public func stop() {
        monitor.stopMonitoring()
        consecutiveDrops = 0
        onFire = nil
    }
}

#if DEBUG
public final class FakeNetworkMonitor: NetworkMonitoring {
    public let isAvailable: Bool
    public private(set) var isLinkUp: Bool
    public private(set) var isMonitoring = false
    private var onSample: ((Bool) -> Void)?

    public init(isLinkUp: Bool, isAvailable: Bool = true) {
        self.isLinkUp = isLinkUp
        self.isAvailable = isAvailable
    }

    public func startMonitoring(_ onSample: @escaping (Bool) -> Void) {
        self.onSample = onSample
        isMonitoring = true
    }

    public func stopMonitoring() {
        isMonitoring = false
        onSample = nil
    }

    public func simulate(isLinkUp: Bool) {
        self.isLinkUp = isLinkUp
        onSample?(isLinkUp)
    }
}
#endif
