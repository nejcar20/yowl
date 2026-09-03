import Foundation

/// Something that can produce a still image from the camera.
public protocol StillCapturing: AnyObject {
    var isAvailable: Bool { get }
    /// The most recent frame as JPEG, or nil if none is available.
    func captureStill() -> Data?
}

/// Photographs whoever is in front of the machine when the alarm fires.
///
/// Takes several shots rather than one: the first often catches the back of a
/// head, and someone walking away with a laptop turns around.
///
/// Deliberately cannot fail the alarm. The siren is the point and evidence is a
/// bonus, so a camera that will not produce an image is silently skipped rather
/// than allowed to interrupt firing.
public final class SnapshotResponse: Response {
    public let identifier = "snapshot"
    /// Off unless asked for: it writes photographs of people to disk.
    public var isEnabled = false

    private let camera: StillCapturing
    private let store: EvidenceStoring
    private let shotCount: Int
    private let interval: TimeInterval
    private let clock: AlarmClock
    private var pendingShots: [ScheduledWork] = []

    public init(camera: StillCapturing, store: EvidenceStoring,
                shotCount: Int = 3, interval: TimeInterval = 2, clock: AlarmClock) {
        self.camera = camera
        self.store = store
        self.shotCount = max(1, shotCount)
        self.interval = max(0, interval)
        self.clock = clock
    }

    public var isAvailable: Bool { camera.isAvailable }

    public func fire(context: AlarmContext) async {
        cancelPending()
        capture(context: context)
        guard shotCount > 1, interval > 0 else { return }
        for shot in 1..<shotCount {
            let work = clock.schedule(after: interval * Double(shot)) { [weak self] in
                self?.capture(context: context)
            }
            pendingShots.append(work)
        }
    }

    public func reset() async {
        // Stop photographing the room the moment the user disarms.
        cancelPending()
    }

    private func capture(context: AlarmContext) {
        guard let jpeg = camera.captureStill() else { return }
        store.save(EvidenceItem(jpeg: jpeg,
                                capturedAt: context.firedAt,
                                trigger: context.trigger.rawValue))
    }

    private func cancelPending() {
        pendingShots.forEach { $0.cancel() }
        pendingShots.removeAll()
    }
}

#if DEBUG
public final class FakeStillCapture: StillCapturing {
    public var available = true
    public var stillToReturn: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0])   // JPEG magic
    public private(set) var captureCount = 0

    public init() {}

    public var isAvailable: Bool { available }

    public func captureStill() -> Data? {
        captureCount += 1
        return stillToReturn
    }
}
#endif
