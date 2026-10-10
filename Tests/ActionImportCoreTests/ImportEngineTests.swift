import Foundation
import Darwin
import ActionImportCore

@main
struct ImportEngineChecks {
    static func main() {
        let checks: [(String, () throws -> Void)] = [
            ("copies original and preserves source", testCopiesOriginalVideoIntoCaptureDateWithoutChangingSource),
            ("repeat import skips verified files", testRepeatImportSkipsVerifiedFiles),
            ("name collision preserves both and reuses verified copy", testNameCollision),
            ("interrupted batch resumes only remaining files", testInterruptionRecovery),
            ("damaged archive restored without overwriting it", testDamagedArchive),
            ("destination cannot point into source", testDestinationProtection),
            ("proxies can be explicitly included", testProxyOption),
            ("insufficient space fails before publishing a video", testInsufficientSpace),
            ("concurrent importer cannot share destination", testConcurrentImporter),
            ("collision archive reused when original name becomes free", testCollisionArchiveAfterOriginalDeleted),
        ]
        let filter = CommandLine.arguments.dropFirst().first
        var failures = 0
        let selected = checks.filter { entry in filter.map { entry.0.contains($0) } ?? true }
        if selected.isEmpty { print("No checks matched"); exit(2) }
        for (name, check) in selected {
            do {
                try check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failures > 0 { exit(1) }
    }

    static func testCopiesOriginalVideoIntoCaptureDateWithoutChangingSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let video = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try fixture.add("DJI_20261003165918_0129_D.LRF", content: "proxy")
        _ = try fixture.add("DJI_20261003165918_0129_D.SCR", content: "preview image")
        _ = try fixture.add("DJI_20261003165918_0129_D.THM", content: "small thumbnail")
        let result = try ImportEngine().run(fixture.request)

        try expect(result.imported, 1, "one original imported")
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.MP4"), encoding: .utf8), "original footage", "copied bytes")
        try expect(try String(contentsOf: video, encoding: .utf8), "original footage", "source unchanged")
        try expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.LRF").path), false, "proxy excluded")
    }

    static func testRepeatImportSkipsVerifiedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try ImportEngine().run(fixture.request)
        let result = try ImportEngine().run(fixture.request)
        try expect(result.imported, 0, "repeat does not copy")
        try expect(result.skipped, 1, "existing content verified")
        try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.appendingPathComponent("2026-10-03").path).count, 1, "one archived file")
    }

    static func testNameCollision() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let name = "DJI_20261003165918_0129_D.MP4"
        _ = try fixture.add(name, content: "new footage")
        let directory = fixture.destination.appendingPathComponent("2026-10-03")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalTarget = directory.appendingPathComponent(name)
        try Data("existing footage".utf8).write(to: originalTarget)
        let first = try ImportEngine().run(fixture.request)
        try expect(first.imported, 1, "new content archived")
        try expect(try String(contentsOf: originalTarget, encoding: .utf8), "existing footage", "existing file preserved")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".MP4") }
        try expect(names.count, 2, "both versions kept")
        let second = try ImportEngine().run(fixture.request)
        try expect(second.imported, 0, "renamed archive reused")
        try expect(second.skipped, 1, "renamed archive verified")
    }

    static func testInterruptionRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "first original")
        _ = try fixture.add("DJI_20261003170000_0130_D.MP4", content: "second original")
        let cancel = CancelFlag()
        do {
            _ = try ImportEngine().run(fixture.request, cancelled: { cancel.value }) { event in
                if event.phase == .completed && event.finishedFiles == 1 { cancel.set() }
            }
            throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: "cancellation should fail the unfinished batch"])
        } catch ImportFailure.cancelled {}
        let resumed = try ImportEngine().run(fixture.request)
        try expect(resumed.imported, 1, "remaining file imported")
        try expect(resumed.skipped, 1, "finished file verified and skipped")
    }

    static func testDamagedArchive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let name = "DJI_20261003165918_0129_D.MP4"
        _ = try fixture.add(name, content: "original footage")
        _ = try ImportEngine().run(fixture.request)
        let target = fixture.destination.appendingPathComponent("2026-10-03/" + name)
        try Data("damaged! footage".utf8).write(to: target)
        let repaired = try ImportEngine().run(fixture.request)
        try expect(repaired.imported, 1, "damaged target not trusted")
        try expect(try String(contentsOf: target, encoding: .utf8), "damaged! footage", "existing content not overwritten")
        let repeated = try ImportEngine().run(fixture.request)
        try expect(repeated.skipped, 1, "repaired copy verified on next run")
    }

    static func testDestinationProtection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "footage")
        let link = fixture.root.appendingPathComponent("camera-alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        do {
            _ = try ImportEngine().run(ImportRequest(source: fixture.source, destination: link.appendingPathComponent("archive")))
            throw NSError(domain: "Check", code: 1)
        } catch ImportFailure.destinationInsideSource {}
    }

    static func testProxyOption() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try fixture.add("DJI_20261003165918_0129_D.LRF", content: "proxy footage")
        let result = try ImportEngine().run(ImportRequest(source: fixture.source, destination: fixture.destination, includeProxies: true))
        try expect(result.imported, 2, "both original and proxy imported")
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.LRF"), encoding: .utf8), "proxy footage", "proxy bytes")
    }

    static func testInsufficientSpace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        do {
            _ = try ImportEngine(capacity: { _ in 0 }).run(fixture.request)
            throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected insufficient space error"])
        } catch ImportFailure.insufficientSpace {}
        try expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.MP4").path), false, "unfinished file absent")
    }

    static func testConcurrentImporter() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        let rejected = CancelFlag()
        _ = try ImportEngine().run(fixture.request, progress: { event in
            guard event.phase == .copying else { return }
            do { _ = try ImportEngine().run(fixture.request) }
            catch ImportFailure.busy { rejected.set() }
            catch {}
        })
        try expect(rejected.value, true, "second importer refused")
    }

    static func testCollisionArchiveAfterOriginalDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let name = "DJI_20261003165918_0129_D.MP4"
        _ = try fixture.add(name, content: "new footage")
        let directory = fixture.destination.appendingPathComponent("2026-10-03")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent(name)
        try Data("old footage".utf8).write(to: old)
        _ = try ImportEngine().run(fixture.request)
        try FileManager.default.removeItem(at: old)
        let repeated = try ImportEngine().run(fixture.request)
        try expect(repeated.imported, 0, "existing conflict archive must be reused")
        try expect(repeated.skipped, 1, "existing conflict archive verified")
        try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1, "no duplicate original name published")
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.withLock { cancelled } }
    func set() { lock.withLock { cancelled = true } }
}

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message): expected \(expected), got \(actual)"])
    }
}

private struct Fixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    var request: ImportRequest { ImportRequest(source: source, destination: destination) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ActionImportTests-\(UUID().uuidString)")
        source = root.appendingPathComponent("camera")
        destination = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("DCIM/DJI_001"), withIntermediateDirectories: true)
    }

    func add(_ name: String, content: String) throws -> URL {
        let url = source.appendingPathComponent("DCIM/DJI_001").appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
