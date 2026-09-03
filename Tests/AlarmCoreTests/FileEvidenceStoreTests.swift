import Testing
import Foundation
@testable import AlarmCore

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("evidence-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func item(_ second: Int) -> EvidenceItem {
    EvidenceItem(jpeg: Data([0xFF, 0xD8, UInt8(second % 256)]),
                 capturedAt: Date(timeIntervalSince1970: TimeInterval(1_000_000 + second)),
                 trigger: "motion")
}

// The privacy policy tells users photographs are "capped at the 40 most recent;
// older ones are deleted automatically". That is a published claim about real
// files on a real disk, so it is tested against one — the in-memory double
// cannot demonstrate it.
@Test func theRealStoreDeletesOlderFilesBeyondTheCap() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileEvidenceStore(directory: directory, keepingMostRecent: 5)

    for second in 1...20 { store.save(item(second)) }

    let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jpg" }
    #expect(files.count == 5, "the cap must hold on disk, not just in memory")
}

@Test func theRealStoreKeepsTheNewestNotTheOldest() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileEvidenceStore(directory: directory, keepingMostRecent: 3)

    for second in 1...10 { store.save(item(second)) }

    let names = store.allItems().map(\.lastPathComponent).sorted()
    #expect(names.count == 3)
    // Names are timestamp-prefixed, so the survivors must be the last three.
    #expect(names.allSatisfy { $0.contains("13-46") }, "unexpected names: \(names)")
    let saved = try #require(names.last)
    #expect(saved.hasSuffix("-motion.jpg"))
}

// Each shot must land in its own file. Identical timestamps meant one filename
// and silent overwriting.
@Test func distinctCaptureTimesProduceDistinctFiles() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileEvidenceStore(directory: directory, keepingMostRecent: 40)

    store.save(item(1)); store.save(item(2)); store.save(item(3))
    #expect(store.allItems().count == 3)
}

// What an alert attaches must be the real bytes from disk, newest first.
@Test func recentJPEGsReadsActualFileContents() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileEvidenceStore(directory: directory, keepingMostRecent: 40)

    store.save(EvidenceItem(jpeg: Data([1, 2, 3]),
                            capturedAt: Date(timeIntervalSince1970: 1_000_001),
                            trigger: "power"))
    let jpegs = store.recentJPEGs(limit: 3)
    #expect(jpegs.count == 1)
    #expect(jpegs.first == Data([1, 2, 3]))
}

@Test func aFreshStoreHasNoEvidence() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(FileEvidenceStore(directory: directory).allItems().isEmpty)
}

// The run-up's last frame and the first live shot can fall in the same second.
// At one-second filename resolution one silently overwrote the other, losing a
// photograph on roughly half of all firings.
@Test func shotsWithinTheSameSecondGetSeparateFiles() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileEvidenceStore(directory: directory, keepingMostRecent: 40)
    let base = Date(timeIntervalSince1970: 1_000_000)

    store.save(EvidenceItem(jpeg: Data([1]), capturedAt: base, trigger: "motion"))
    store.save(EvidenceItem(jpeg: Data([2]),
                            capturedAt: base.addingTimeInterval(0.2), trigger: "motion"))
    store.save(EvidenceItem(jpeg: Data([3]),
                            capturedAt: base.addingTimeInterval(0.8), trigger: "motion"))

    #expect(store.allItems().count == 3, "sub-second shots must not collide")
}

// An alert attaches the newest photographs. The in-memory double used to return
// oldest-first, so this ordering was unverifiable in the shipped path.
@Test func recentJPEGsReturnsNewestFirst() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileEvidenceStore(directory: directory, keepingMostRecent: 40)
    let base = Date(timeIntervalSince1970: 1_000_000)

    store.save(EvidenceItem(jpeg: Data([1]), capturedAt: base, trigger: "m"))
    store.save(EvidenceItem(jpeg: Data([2]),
                            capturedAt: base.addingTimeInterval(1), trigger: "m"))
    store.save(EvidenceItem(jpeg: Data([3]),
                            capturedAt: base.addingTimeInterval(2), trigger: "m"))

    #expect(store.recentJPEGs(limit: 2) == [Data([3]), Data([2])])
}

// The doubles must agree with the real store, or a test can pass against a
// broken shipped path.
@Test func theInMemoryDoubleMatchesTheRealStoresOrdering() {
    let double = InMemoryEvidenceStore(keepingMostRecent: 40)
    double.save(EvidenceItem(jpeg: Data([1]), capturedAt: Date(timeIntervalSince1970: 1), trigger: "m"))
    double.save(EvidenceItem(jpeg: Data([2]), capturedAt: Date(timeIntervalSince1970: 2), trigger: "m"))
    #expect(double.recentJPEGs(limit: 1) == [Data([2])], "newest first, like the real store")
}
