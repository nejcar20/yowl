import Foundation
import Network

public protocol NetworkMonitoring: AnyObject {
    var isAvailable: Bool { get }
    var isLinkUp: Bool { get }
    func startMonitoring(_ onChange: @escaping (Bool) -> Void)
    func stopMonitoring()
}

/// Watches whether the Mac still has a Wi-Fi connection.
///
/// Uses `NWPathMonitor` rather than CoreWLAN. `CWInterface.rssiValue()` returns
/// 0 both when disassociated AND on any internal error — the SDK header says so
/// in as many words — with no way to tell them apart, and the ambiguous case
/// fails toward firing a maximum-volume siren. It also costs a ~5 ms XPC round
/// trip to `airportd` per call, which was being made on the main actor once a
/// second and synchronously from `canFireNow`.
///
/// `NWPathMonitor` is event-driven, needs no permission, does not conflate error
/// with disconnection, and never touches the main thread.
///
/// Deliberately does not read the network name: `CWInterface.ssid()` requires
/// Location Services authorisation, and knowing the name only distinguishes
/// "moved to a different network", which is not the theft case.
public final class WiFiLinkMonitor: NetworkMonitoring {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "com.jernejkocica.laptopalarm.network")
    private var isStarted = false
    /// Last known state, updated on the main actor from the path handler.
    private var lastKnownLinkUp = true
    /// Stays main-actor isolated: only the Bool crosses the queue boundary.
    private var onChange: ((Bool) -> Void)?

    public init() {}

    /// Fixed for the process, as `Capability.isAvailable` requires. Asking the
    /// system live would let a transient answer flip `isActive` while armed and
    /// make the UI claim nothing is watching.
    public let isAvailable = true

    public var isLinkUp: Bool { lastKnownLinkUp }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
        stopMonitoring()
        self.onChange = onChange
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            // The handler runs on our own queue; only `up` crosses, and the
            // callback is read on the main actor where it lives.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastKnownLinkUp = up
                self.onChange?(up)
            }
        }
        monitor.start(queue: queue)
        isStarted = true
    }

    public func stopMonitoring() {
        guard isStarted else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        onChange = nil
        isStarted = false
    }
}

/// Fires when Wi-Fi stays disconnected for long enough to mean the machine has
/// left, rather than blinked.
///
/// The confirmation window is a duration, not a sample count. Access-point
/// roaming, 802.11r transitions, DFS radar channel evacuation, router reboots
/// and `airportd` restarts all routinely take several seconds, and each one
/// ending in a maximum-volume siren in a public room is not a recoverable
/// experience.
public final class NetworkTrigger: Trigger {
    public let id = TriggerID("network")
    public var identifier: String { id.rawValue }
    /// Off by default: losing Wi-Fi happens in ordinary use.
    public var isEnabled = false
    public var graceSeconds: TimeInterval

    /// How long the link must stay down before this counts as a theft.
    public let confirmAfter: TimeInterval

    private let monitor: NetworkMonitoring
    private let clock: AlarmClock
    private var pendingConfirmation: ScheduledWork?
    private var onFire: ((TriggerID) -> Void)?

    public init(monitor: NetworkMonitoring, clock: AlarmClock,
                confirmAfter: TimeInterval = 30, graceSeconds: TimeInterval) {
        self.monitor = monitor
        self.clock = clock
        self.confirmAfter = max(0, confirmAfter)
        self.graceSeconds = graceSeconds
    }

    public var isAvailable: Bool { monitor.isAvailable }

    /// Already disconnected means there is no departure left to observe — the
    /// same rule the charger and lid triggers follow.
    public var canFireNow: Bool { monitor.isAvailable && monitor.isLinkUp }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        cancelPendingConfirmation()
        monitor.startMonitoring { [weak self] isLinkUp in
            guard let self else { return }
            guard !isLinkUp else {
                // Back before the window elapsed: a blink, not a departure.
                self.cancelPendingConfirmation()
                return
            }
            guard self.pendingConfirmation == nil else { return }
            self.pendingConfirmation = self.clock.schedule(after: self.confirmAfter) { [weak self] in
                guard let self else { return }
                self.pendingConfirmation = nil
                self.onFire?(self.id)
            }
        }
    }

    public func stop() {
        monitor.stopMonitoring()
        cancelPendingConfirmation()
        onFire = nil
    }

    private func cancelPendingConfirmation() {
        pendingConfirmation?.cancel()
        pendingConfirmation = nil
    }
}

#if DEBUG
public final class FakeNetworkMonitor: NetworkMonitoring {
    public let isAvailable: Bool
    public private(set) var isLinkUp: Bool
    public private(set) var isMonitoring = false
    private var onChange: ((Bool) -> Void)?

    public init(isLinkUp: Bool, isAvailable: Bool = true) {
        self.isLinkUp = isLinkUp
        self.isAvailable = isAvailable
    }

    public func startMonitoring(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        isMonitoring = true
    }

    public func stopMonitoring() {
        isMonitoring = false
        onChange = nil
    }

    public func simulate(isLinkUp: Bool) {
        self.isLinkUp = isLinkUp
        onChange?(isLinkUp)
    }
}
#endif
