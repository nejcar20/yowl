import Foundation

/// One photograph taken because the alarm fired.
public struct EvidenceItem: Equatable, Sendable {
    public let jpeg: Data
    public let capturedAt: Date
    /// Which trigger fired, so a photo can be read months later without guessing.
    public let trigger: String

    public init(jpeg: Data, capturedAt: Date, trigger: String) {
        self.jpeg = jpeg
        self.capturedAt = capturedAt
        self.trigger = trigger
    }
}

public protocol EvidenceStoring: AnyObject {
    @discardableResult
    func save(_ item: EvidenceItem) -> URL?
    func allItems() -> [URL]
    /// The newest photographs, for an alert to attach.
    func recentJPEGs(limit: Int) -> [Data]
}

/// Writes evidence to Application Support, one JPEG per shot.
///
/// Local only. Photographs of whoever is in front of the machine are the most
/// sensitive thing this app produces, so they stay on the disk of the machine
/// that took them unless the user explicitly sets up somewhere to send them.
public final class FileEvidenceStore: EvidenceStoring {
    private let directory: URL
    private let keepingMostRecent: Int

    public init(directory: URL? = nil, keepingMostRecent: Int = 40) {
        self.keepingMostRecent = max(1, keepingMostRecent)
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaptopAlarm/Evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    @discardableResult
    public func save(_ item: EvidenceItem) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: item.capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(stamp)-\(item.trigger).jpg")
        do {
            try item.jpeg.write(to: url, options: .atomic)
            prune()
            return url
        } catch {
            return nil
        }
    }

    public func allItems() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    /// Keeps the newest and deletes the rest. Evidence accumulates every time
    /// the alarm fires, and most of those will be the owner tripping their own
    /// alarm, so leaving it unbounded fills the disk with pictures of them.
    private func prune() {
        let items = allItems()
        guard items.count > keepingMostRecent else { return }
        for url in items.dropFirst(keepingMostRecent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func recentJPEGs(limit: Int) -> [Data] {
        allItems().prefix(limit).compactMap { try? Data(contentsOf: $0) }
    }

    public var directoryURL: URL { directory }
}

#if DEBUG
public final class InMemoryEvidenceStore: EvidenceStoring {
    public private(set) var saved: [EvidenceItem] = []
    private let keepingMostRecent: Int

    public init(keepingMostRecent: Int = 40) {
        self.keepingMostRecent = max(1, keepingMostRecent)
    }

    @discardableResult
    public func save(_ item: EvidenceItem) -> URL? {
        saved.append(item)
        if saved.count > keepingMostRecent {
            saved.removeFirst(saved.count - keepingMostRecent)
        }
        return URL(string: "memory://\(saved.count)")
    }

    public func allItems() -> [URL] { saved.indices.map { URL(string: "memory://\($0)")! } }

    public func recentJPEGs(limit: Int) -> [Data] {
        saved.suffix(limit).map(\.jpeg)
    }
}
#endif
