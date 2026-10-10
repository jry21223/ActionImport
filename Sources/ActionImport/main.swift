import ActionImportCore
import AppKit
import Foundation
import Darwin

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

if let sourcePath = argument("--scan") ?? argument("--import") ?? argument("--configure"), let destinationPath = argument("--destination") {
    do {
        let request = ImportRequest(source: URL(fileURLWithPath: sourcePath), destination: URL(fileURLWithPath: destinationPath), includeProxies: CommandLine.arguments.contains("--include-proxies"))
        let plan = try ImportEngine().scan(request)
        if CommandLine.arguments.contains("--configure") {
            guard let camera = CameraCatalog.connected().first(where: { $0.url.path == request.source.standardizedFileURL.path }) else { throw ImportFailure.invalidSource }
            var settings = AppSettings()
            settings.volumeIdentifier = camera.identifier
            settings.volumeName = camera.name
            settings.destinationPath = request.destination.path
            settings.includeProxies = request.includeProxies
            settings.autoImport = CommandLine.arguments.contains("--enable-auto")
            try settings.save()
            print("Configured \(camera.name): \(plan.files.count) files, \(plan.totalBytes) bytes")
        } else if CommandLine.arguments.contains("--import") {
            let result = try ImportEngine().run(request)
            print("{\"imported\":\(result.imported),\"skipped\":\(result.skipped)}")
        } else {
            let payload: [String: Any] = ["files": plan.files.count, "bytes": plan.totalBytes, "source": sourcePath, "destination": destinationPath]
            print(String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!)
        }
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
} else if CommandLine.arguments.count > 1 {
    print("Usage: ActionImport --scan|--import|--configure SOURCE --destination DESTINATION [--include-proxies] [--enable-auto]")
    exit(2)
} else {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.accessory)
    application.run()
    withExtendedLifetime(controller) {}
}
