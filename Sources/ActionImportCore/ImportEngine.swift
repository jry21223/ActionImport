import Foundation
import CryptoKit
import Darwin

public struct ImportRequest: Sendable {
    /// `quick` trusts an archive whose recorded source and file metadata are unchanged;
    /// `full` rereads every source and archive to compare SHA-256.
    public enum Verification: Sendable { case quick, full }

    public let source: URL
    public let destination: URL
    public let includeProxies: Bool
    public let verification: Verification

    public init(source: URL, destination: URL, includeProxies: Bool = false, verification: Verification = .quick) {
        self.source = source
        self.destination = destination
        self.includeProxies = includeProxies
        self.verification = verification
    }
}

public struct ImportResult: Sendable {
    public let imported: Int
    public let skipped: Int
}

public struct MediaFile: Sendable {
    public let url: URL
    public let relativePath: String
    public let dateFolder: String
    public let size: Int64
    public let modified: Date
}

public struct ImportPlan: Sendable {
    public let files: [MediaFile]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ImportProgress: Sendable {
    public enum Phase: String, Sendable { case copying, verifying, checking, completed }
    public let phase: Phase
    public let fileName: String
    public let finishedFiles: Int
    public let totalFiles: Int
    public let processedBytes: Int64
    public let fileBytes: Int64
    public var fraction: Double {
        guard totalFiles > 0 else { return 1 }
        let part = min(1, Double(processedBytes) / Double(max(fileBytes, 1)))
        let weight = phase == .copying ? part * 0.5 : (phase == .completed ? 0 : 0.5 + part * 0.5)
        return min(1, (Double(finishedFiles) + weight) / Double(totalFiles))
    }
}

public enum ImportFailure: LocalizedError {
    case invalidSource, destinationInsideSource, cancelled, sourceChanged, verificationFailed, conflict, insufficientSpace, busy
    public var errorDescription: String? {
        switch self {
        case .invalidSource: "来源没有可读取的 DCIM 文件夹，请将相机切换到文件传输模式。"
        case .destinationInsideSource: "保存目录不能放在相机存储中，也不能包含来源目录。"
        case .cancelled: "导入已停止。已完成的文件保留，下次可重试剩余文件。"
        case .sourceChanged: "来源素材发生变化或相机已断开，请重新连接后重试。"
        case .verificationFailed: "复制校验失败，该文件没有计为完成，请重试。"
        case .conflict: "目标已有不同内容的同名文件，现有素材已保留。"
        case .insufficientSpace: "保存磁盘空间不足，请释放空间后重试。"
        case .busy: "该保存目录正在导入，请等待当前任务完成。"
        }
    }
}

public struct ImportEngine: Sendable {
    private let capacity: @Sendable (URL) throws -> Int64?

    public init(capacity: @escaping @Sendable (URL) throws -> Int64? = { url in
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
    }) {
        self.capacity = capacity
    }

    public func scan(_ request: ImportRequest) throws -> ImportPlan {
        let source = request.source.resolvingSymlinksInPath().standardizedFileURL
        let destination = request.destination.resolvingSymlinksInPath().standardizedFileURL
        guard !contains(source, destination), !contains(destination, source) else {
            throw ImportFailure.destinationInsideSource
        }
        let dcim = source.appendingPathComponent("DCIM")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dcim.path, isDirectory: &directory), directory.boolValue,
              contains(source, dcim.resolvingSymlinksInPath()) else { throw ImportFailure.invalidSource }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw ImportFailure.invalidSource }
        var files: [MediaFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true,
                  url.pathExtension.uppercased() == "MP4" || (request.includeProxies && url.pathExtension.uppercased() == "LRF") else { continue }
            guard contains(source, url.resolvingSymlinksInPath()) else { throw ImportFailure.invalidSource }
            let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            files.append(MediaFile(url: url, relativePath: String(url.path.dropFirst(source.path.count + 1)), dateFolder: CaptureDate.folderName(forFileName: url.lastPathComponent, fallback: modified), size: Int64(values.fileSize ?? 0), modified: modified))
        }
        if let enumerationError { throw enumerationError }
        return ImportPlan(files: files.sorted { $0.relativePath < $1.relativePath })
    }

    public func run(_ request: ImportRequest, cancelled: @Sendable () -> Bool = { false }, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) throws -> ImportResult {
        let plan = try scan(request)
        let destination = request.destination.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let lockURL = destination.appendingPathComponent(".actionimport.lock")
        let lockDescriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600) }
        guard lockDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG else { throw ImportFailure.conflict }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw ImportFailure.busy }
        defer { flock(lockDescriptor, LOCK_UN) }
        var manifest = try loadManifest(destination)
        let recordsBySource = Dictionary(grouping: manifest.files, by: \.value.source)
        var imported = 0
        var skipped = 0
        for file in plan.files {
            try checkCancellation(cancelled)
            let directory = destination.appendingPathComponent(file.dateFolder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard contains(destination, directory.resolvingSymlinksInPath()), !contains(request.source.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath()) else { throw ImportFailure.destinationInsideSource }
            let originalTarget = directory.appendingPathComponent(file.url.lastPathComponent)
            var target = originalTarget
            let temporary = directory.appendingPathComponent(".actionimport-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let emit: (ImportProgress.Phase, Int64) -> Void = { phase, bytes in
                progress(ImportProgress(phase: phase, fileName: file.url.lastPathComponent, finishedFiles: imported + skipped, totalFiles: plan.files.count, processedBytes: bytes, fileBytes: file.size))
            }
            if request.verification == .quick, quickMatch(file, destination: destination, records: recordsBySource[file.relativePath] ?? []) {
                skipped += 1
                emit(.completed, 0)
                continue
            }
            if try exists(target) || manifest.files.values.contains(where: { $0.source == file.relativePath && $0.size == file.size }) {
                let checksum = try hash(file.url, cancelled: cancelled) { emit(.checking, $0) }
                try validateSource(file)
                let choice = try chooseTarget(originalTarget, file: file, destination: destination, manifest: manifest, checksum: checksum, cancelled: cancelled)
                target = choice.url
                if choice.matches {
                    try record(file, target: target, checksum: checksum, destination: destination, manifest: &manifest)
                    skipped += 1
                    emit(.completed, 0)
                    continue
                }
            }
            if let available = try capacity(destination), available < file.size + 1_048_576 {
                throw ImportFailure.insufficientSpace
            }
            let sourceHandle = try openRead(file.url)
            defer { try? sourceHandle.close() }
            let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard descriptor >= 0 else { throw posixError() }
            // Best effort: keep written pages out of the cache so the readback below normally comes from storage.
            _ = fcntl(descriptor, F_NOCACHE, 1)
            let targetHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var digest = SHA256()
            var written: Int64 = 0
            do {
                while true {
                    try checkCancellation(cancelled)
                    // Foundation's autoreleased read buffers must not survive the whole import task.
                    let hasChunk = try autoreleasepool {
                        guard let data = try sourceHandle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                        try targetHandle.write(contentsOf: data)
                        digest.update(data: data)
                        written += Int64(data.count)
                        emit(.copying, written)
                        return true
                    }
                    if !hasChunk { break }
                }
                // F_FULLFSYNC also flushes the drive cache; filesystems without it fall back to fsync.
                if fcntl(descriptor, F_FULLFSYNC) != 0 { try targetHandle.synchronize() }
                try targetHandle.close()
            } catch {
                try? targetHandle.close()
                throw error
            }
            guard written == file.size else { throw ImportFailure.sourceChanged }
            try validateSource(file)
            let expected = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let actual = try hash(temporary, cancelled: cancelled) { emit(.verifying, $0) }
            guard expected == actual else { throw ImportFailure.verificationFailed }
            try checkCancellation(cancelled)
            var published = false
            for _ in 0..<16 {
                try checkCancellation(cancelled)
                let choice = try chooseTarget(originalTarget, file: file, destination: destination, manifest: manifest, checksum: expected, cancelled: cancelled)
                target = choice.url
                if choice.matches { break }
                guard contains(destination, directory.resolvingSymlinksInPath()) else { throw ImportFailure.destinationInsideSource }
                let status = temporary.path.withCString { from in target.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
                if status == 0 { published = true; break }
                guard errno == EEXIST else { throw posixError() }
            }
            if !published {
                guard try existingChecksum(target, size: file.size, cancelled: cancelled) == expected else { throw ImportFailure.conflict }
            }
            try record(file, target: target, checksum: expected, destination: destination, manifest: &manifest)
            if published { imported += 1 } else { skipped += 1 }
            emit(.completed, 0)
        }
        return ImportResult(imported: imported, skipped: skipped)
    }

    private struct Manifest: Codable {
        var version = 1
        var files: [String: Record] = [:]
    }

    private struct Record: Codable {
        let source: String
        let size: Int64
        let sha256: String
        let verifiedAt: Date
        // Absent in manifests written before quick checks; such records take one full check.
        let sourceModified: Date?
        let archive: FileStamp?
    }

    /// Identity of an archived file when it was verified; a rewrite or replacement changes it.
    /// Device numbers are left out because they change when an external archive disk remounts.
    private struct FileStamp: Codable, Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedNanoseconds: Int64
    }

    private func loadManifest(_ destination: URL) throws -> Manifest {
        let url = destination.appendingPathComponent(".actionimport-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Manifest() }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ImportFailure.conflict }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func record(_ file: MediaFile, target: URL, checksum: String, destination: URL, manifest: inout Manifest) throws {
        let relative = String(target.path.dropFirst(destination.path.count + 1))
        manifest.files[relative] = Record(source: file.relativePath, size: file.size, sha256: checksum, verifiedAt: Date(), sourceModified: file.modified, archive: stamp(target))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: destination.appendingPathComponent(".actionimport-manifest.json"), options: .atomic)
    }

    private func quickMatch(_ file: MediaFile, destination: URL, records: [(key: String, value: Record)]) -> Bool {
        records.contains { relative, record in
            guard record.size == file.size, record.sourceModified == file.modified,
                  let recorded = record.archive, recorded.size == file.size,
                  !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return false }
            let archived = destination.appendingPathComponent(relative)
            return contains(destination, archived.resolvingSymlinksInPath()) && stamp(archived) == recorded
        }
    }

    private func stamp(_ url: URL) -> FileStamp? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size), modifiedNanoseconds: modified)
    }

    private func existingChecksum(_ target: URL, size: Int64, cancelled: () -> Bool) throws -> String? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == size else { return nil }
        return try hash(target, cancelled: cancelled) { _ in }
    }

    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError()
    }

    private func chooseTarget(_ original: URL, file: MediaFile, destination: URL, manifest: Manifest, checksum: String, cancelled: () -> Bool) throws -> (url: URL, matches: Bool) {
        for (relative, record) in manifest.files.sorted(by: { $0.key < $1.key }) {
            guard record.source == file.relativePath, record.size == file.size, record.sha256 == checksum,
                  !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { continue }
            let archived = destination.appendingPathComponent(relative)
            guard contains(destination, archived.resolvingSymlinksInPath()),
                  try existingChecksum(archived, size: file.size, cancelled: cancelled) == checksum else { continue }
            return (archived, true)
        }
        var stem = original.deletingPathExtension().lastPathComponent
        while stem.utf8.count > 120 { stem.removeLast() }
        let directory = original.deletingLastPathComponent()
        let knownTargets = [original, directory.appendingPathComponent("\(stem)--\(checksum.prefix(12)).\(original.pathExtension)"), directory.appendingPathComponent("\(stem)--\(checksum).\(original.pathExtension)")]
        for candidate in knownTargets {
            if try existingChecksum(candidate, size: file.size, cancelled: cancelled) == checksum { return (candidate, true) }
        }
        for index in 0..<1000 {
            let candidate: URL
            if index == 0 { candidate = original }
            else {
                let suffix = index == 1 ? String(checksum.prefix(12)) : checksum + (index > 2 ? "-\(index - 2)" : "")
                candidate = original.deletingLastPathComponent().appendingPathComponent("\(stem)--\(suffix).\(original.pathExtension)")
            }
            guard try exists(candidate) else { return (candidate, false) }
            if try existingChecksum(candidate, size: file.size, cancelled: cancelled) == checksum { return (candidate, true) }
        }
        throw ImportFailure.conflict
    }

    private func validateSource(_ file: MediaFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
              (attributes[.modificationDate] as? Date) == file.modified else { throw ImportFailure.sourceChanged }
    }

    private func contains(_ parent: URL, _ child: URL) -> Bool {
        parent.path == child.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }

    private func openRead(_ url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ImportFailure.invalidSource
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func hash(_ url: URL, cancelled: () -> Bool, progress: (Int64) -> Void) throws -> String {
        let handle = try openRead(url)
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes: Int64 = 0
        while true {
            try checkCancellation(cancelled)
            let hasChunk = try autoreleasepool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                digest.update(data: data)
                bytes += Int64(data.count)
                progress(bytes)
                return true
            }
            if !hasChunk { break }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw ImportFailure.cancelled }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
