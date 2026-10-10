import Foundation

struct CameraVolume: Sendable {
    let url: URL
    let identifier: String
    let name: String
}

enum CameraCatalog {
    static func connected() -> [CameraVolume] {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsInternal == false,
                  let identifier = values.volumeUUIDString,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path) else { return nil }
            return CameraVolume(url: url, identifier: identifier.uppercased(), name: values.volumeName ?? url.lastPathComponent)
        }.sorted { $0.name < $1.name }
    }
}

struct AppSettings: Codable, Sendable {
    var volumeIdentifier: String?
    var volumeName: String?
    var destinationPath: String?
    var includeProxies = false
    var autoImport = false

    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ActionImport")
    }

    static func load() throws -> AppSettings {
        let path = storageDirectory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: path))
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.storageDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.storageDirectory.appendingPathComponent("settings.json"), options: .atomic)
    }
}

struct RuntimeStatus: Codable, Sendable {
    let phase: String
    let imported: Int
    let skipped: Int
    let finished: Int
    let total: Int
    let message: String
    let updatedAt: String
}

actor RuntimeStore {
    static let shared = RuntimeStore()
    private var settingsRevision = 0
    private var statusRevision = 0

    func loadSettings() throws -> AppSettings { try AppSettings.load() }
    func connectedCameras() -> [CameraVolume] { CameraCatalog.connected() }

    func saveSettings(_ settings: AppSettings, revision: Int) throws {
        guard revision > settingsRevision else { return }
        settingsRevision = revision
        try settings.save()
    }

    func writeStatus(_ status: RuntimeStatus, revision: Int) {
        guard revision > statusRevision else { return }
        statusRevision = revision
        do {
            try FileManager.default.createDirectory(at: AppSettings.storageDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(status).write(to: AppSettings.storageDirectory.appendingPathComponent("status.json"), options: .atomic)
        } catch { /* Diagnostics cannot change a verified import result. */ }
    }
}
