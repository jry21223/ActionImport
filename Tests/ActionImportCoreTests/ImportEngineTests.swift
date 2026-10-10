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
            ("quick check skips unchanged footage without reading it", testQuickSkipDoesNotRead),
            ("quick check rejects changed source", testQuickSkipRejectsChangedSource),
            ("legacy manifest takes full check once then quick", testLegacyManifestUpgrades),
            ("full verification rereads footage", testFullVerificationRereads),
            ("capture date folder derived from DJI name and fallback", testCaptureDateFolder),
            ("panel presentation follows import state", testPanelPresentation),
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

    static func testQuickSkipDoesNotRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let video = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try ImportEngine().run(fixture.request)
        let archived = fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.MP4")
        // Unreadable files prove the quick path decides from metadata alone.
        try withUnreadable([video, archived]) {
            let result = try ImportEngine().run(fixture.request)
            try expect(result.imported, 0, "nothing copied")
            try expect(result.skipped, 1, "unchanged file skipped")
        }
    }

    static func testQuickSkipRejectsChangedSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let video = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try ImportEngine().run(fixture.request)
        try Data("replaced footage".utf8).write(to: video)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: video.path)
        let result = try ImportEngine().run(fixture.request)
        try expect(result.imported, 1, "changed source archived again")
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.MP4"), encoding: .utf8), "original footage", "earlier archive kept")
    }

    static func testLegacyManifestUpgrades() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let video = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try ImportEngine().run(fixture.request)
        let manifestURL = fixture.destination.appendingPathComponent(".actionimport-manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var files = manifest["files"] as! [String: [String: Any]]
        for key in files.keys { files[key] = files[key]!.filter { ["source", "size", "sha256", "verifiedAt"].contains($0.key) } }
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let archived = fixture.destination.appendingPathComponent("2026-10-03/DJI_20261003165918_0129_D.MP4")
        try expect(try throwsAny { try withUnreadable([video]) { _ = try ImportEngine().run(fixture.request) } }, true, "legacy record needs a full check")
        try expect(try ImportEngine().run(fixture.request).skipped, 1, "full check upgrades record")
        try withUnreadable([video, archived]) {
            try expect(try ImportEngine().run(fixture.request).skipped, 1, "upgraded record takes quick path")
        }
    }

    static func testFullVerificationRereads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let video = try fixture.add("DJI_20261003165918_0129_D.MP4", content: "original footage")
        _ = try ImportEngine().run(fixture.request)
        let full = ImportRequest(source: fixture.source, destination: fixture.destination, verification: .full)
        try expect(try throwsAny { try withUnreadable([video]) { _ = try ImportEngine().run(full) } }, true, "full mode reads source")
        try expect(try ImportEngine().run(full).skipped, 1, "full mode verifies existing archive")
    }

    private static func withUnreadable(_ urls: [URL], _ body: () throws -> Void) throws {
        for url in urls { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
        defer { for url in urls { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) } }
        try body()
    }

    private static func throwsAny(_ body: () throws -> Void) throws -> Bool {
        do { try body(); return false } catch { return true }
    }

    static func testCaptureDateFolder() throws {
        let fallback = Self.localDate(2025, 10, 19)
        try expect(CaptureDate.folderName(forFileName: "DJI_20261003165918_0129_D.MP4", fallback: fallback), "2026-10-03", "timestamp taken from DJI name")
        try expect(CaptureDate.folderName(forFileName: "DJI_20260101000000_0001_D.MP4", fallback: fallback), "2026-01-01", "midnight timestamp parsed")
        // A non-DJI name or a malformed timestamp uses the file's own modification date.
        try expect(
            CaptureDate.folderName(forFileName: "clip.mp4", fallback: Self.localDate(2026, 5, 6)),
            "2026-05-06",
            "falls back to modification date"
        )
        try expect(
            CaptureDate.folderName(forFileName: "DJI_notatimestamp_0129_D.MP4", fallback: Self.localDate(2026, 5, 6)),
            "2026-05-06",
            "malformed DJI timestamp falls back"
        )
        try expect(CaptureDate.djiTimestamp(in: "DJI_20261003165918_0129_D.MP4"), "20261003165918", "extracts raw stamp")
        try expect(CaptureDate.djiTimestamp(in: "DJI_2026_0129_D.MP4"), nil, "short field rejected")
        try expect(CaptureDate.djiTimestamp(in: "MP4_20261003165918_0129_D.MP4"), nil, "non-DJI prefix rejected")
    }

    static func testPanelPresentation() throws {
        // Unconfigured wins over everything else.
        let unconfigured = ImportPresentation(ImportPresentation.State(configured: false, busy: true))
        try expect(unconfigured.primaryAction, .configure, "unconfigured asks for setup")
        try expect(unconfigured.primaryEnabled, true, "setup stays clickable")
        try expect(unconfigured.primaryTitle, "完成设置", "setup title")

        // A running import offers stop, and its headline reflects work in progress.
        let busy = ImportPresentation(ImportPresentation.State(phase: .copying, configured: true, busy: true, importActive: true))
        try expect(busy.primaryAction, .stop, "busy offers stop")
        try expect(busy.headline, "正在复制", "copying headline")

        // A finished import reports what actually happened, not a generic success.
        let imported = ImportPresentation(ImportPresentation.State(phase: .completed, configured: true, lastImported: 3))
        try expect(imported.headline, "已收好", "imported headline")
        let nothingNew = ImportPresentation(ImportPresentation.State(phase: .completed, configured: true, lastImported: 0))
        try expect(nothingNew.headline, "没有新视频", "no-op headline")

        // Retry needs a camera; the button is disabled while it is gone.
        let retryOffline = ImportPresentation(ImportPresentation.State(phase: .failed, configured: true, cameraConnected: false))
        try expect(retryOffline.primaryAction, .retry, "failure offers retry")
        try expect(retryOffline.primaryEnabled, false, "retry disabled without camera")
        let retryOnline = ImportPresentation(ImportPresentation.State(phase: .failed, configured: true, cameraConnected: true))
        try expect(retryOnline.primaryEnabled, true, "retry enabled with camera")

        // Scanned footage starts an import; an empty scan falls through to open.
        let ready = ImportPresentation(ImportPresentation.State(phase: .ready, configured: true, cameraConnected: true, scannedFiles: 4))
        try expect(ready.primaryAction, .start, "scanned footage starts import")
        try expect(ready.headline, "准备导入", "ready headline")
        let empty = ImportPresentation(ImportPresentation.State(phase: .ready, configured: true, cameraConnected: true, scannedFiles: 0))
        try expect(empty.primaryAction, .open, "empty scan offers open")

        // Every phase yields a headline, and progress labels stay distinct.
        for phase in ImportPresentation.Phase.allCases {
            let state = ImportPresentation.State(phase: phase, configured: true, cameraConnected: true)
            try expect(ImportPresentation(state).headline.isEmpty, false, "headline for \(phase.rawValue)")
        }
        let labels = Set([ImportProgress.Phase.copying, .verifying, .checking, .completed].map(ImportPresentation.progressLabel))
        try expect(labels.count, 4, "progress labels are distinct")
    }

    /// Local noon, because folder names are formatted in the Mac's own time zone.
    private static func localDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
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
