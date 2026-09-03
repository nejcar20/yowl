import Foundation

/// A JPEG with the moment it was taken.
///
/// Explicitly `nonisolated`: these are built on the camera's capture queue, and
/// the package is main-actor isolated by default, which would otherwise put the
/// initialiser out of reach there — the same reason `GrayscaleFrame` is.
nonisolated public struct TimestampedStill: Equatable, Sendable {
    public let jpeg: Data
    public let capturedAt: Date
    public init(jpeg: Data, capturedAt: Date) {
        self.jpeg = jpeg
        self.capturedAt = capturedAt
    }
}

/// Something that can produce a still image from the camera.
public protocol StillCapturing: AnyObject {
    /// Hardware capability, fixed for the process — not permission, which the
    /// engine's construction-time filter would freeze.
    var isAvailable: Bool { get }
    /// The most recent frame as JPEG, or nil if none is available.
    func captureStill() -> Data?
    /// Frames from the seconds *before* now, oldest first. The most useful
    /// photograph is often from before the alarm fired — the thief approaching
    /// and looking at the machine, rather than the back of their head as they
    /// leave — and the camera is already running, so this costs memory only.
    func bufferedStills() -> [TimestampedStill]
    /// Drops what is buffered, so a second alarm does not re-save the moments
    /// before the first one.
    func clearBufferedStills()
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
        self.isAvailable = camera.isAvailable
        self.camera = camera
        self.store = store
        self.shotCount = max(1, shotCount)
        self.interval = max(0, interval)
        self.clock = clock
    }

    /// The camera's HARDWARE availability, captured once. Fixed at construction
    /// as `Capability` requires, but not simply `true`: a Mac with no camera at
    /// all must not be offered a photographs toggle. Whether an existing camera
    /// is permitted right now is user configuration and lives in `isEnabled`.
    public let isAvailable: Bool

    public func fire(context: AlarmContext) async {
        cancelPending()
        // The run-up first, oldest to newest, then the moment itself.
        for still in camera.bufferedStills() {
            store.save(EvidenceItem(jpeg: still.jpeg,
                                    capturedAt: still.capturedAt,
                                    trigger: context.trigger.rawValue))
        }
        camera.clearBufferedStills()
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
        // The time of THIS shot, not of the trigger. Sharing the trigger's
        // timestamp gave every shot the same filename, so each overwrote the
        // last and two thirds of the evidence was silently lost.
        store.save(EvidenceItem(jpeg: jpeg,
                                capturedAt: clock.now,
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
    public var buffered: [TimestampedStill] = []
    public private(set) var captureCount = 0
    public private(set) var clearCount = 0

    public init() {}

    public var isAvailable: Bool { available }

    public func captureStill() -> Data? {
        captureCount += 1
        return stillToReturn
    }

    public func bufferedStills() -> [TimestampedStill] { buffered }

    public func clearBufferedStills() {
        buffered = []
        clearCount += 1
    }
}
#endif
