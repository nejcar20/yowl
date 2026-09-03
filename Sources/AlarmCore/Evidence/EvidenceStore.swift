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
}

/// Writes evidence to Application Support, one JPEG per shot.
///
/// Local only. Photographs of whoever is in front of the machine are the most
/// sensitive thing this app produces, so they stay on the disk of the machine
/// that took them unless the user explicitly sets up somewhere to send them.
public final class FileEvidenceStore: EvidenceStoring {
    private let directory: URL

    public init(directory: URL? = nil) {
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

    public var directoryURL: URL { directory }
}

#if DEBUG
public final class InMemoryEvidenceStore: EvidenceStoring {
    public private(set) var saved: [EvidenceItem] = []
    public init() {}

    @discardableResult
    public func save(_ item: EvidenceItem) -> URL? {
        saved.append(item)
        return URL(string: "memory://\(saved.count)")
    }

    public func allItems() -> [URL] { saved.indices.map { URL(string: "memory://\($0)")! } }
}
#endif
