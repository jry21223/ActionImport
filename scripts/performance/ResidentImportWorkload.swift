import Foundation
import Darwin

// Benchmark-only entry point, compiled separately from the shipping application.
// Use synthetic footage and a dedicated archive: this exercises the public engine
// twice, then leaves the same process alive to observe post-import memory.
@main
struct ResidentImportWorkload {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: resident-import-workload SOURCE TEST_DESTINATION\n".utf8))
            exit(2)
        }
        let request = ImportRequest(
            source: URL(fileURLWithPath: CommandLine.arguments[1]),
            destination: URL(fileURLWithPath: CommandLine.arguments[2])
        )
        report("ready pid=\(getpid())")
        Thread.sleep(forTimeInterval: 2)
        for index in 1...2 {
            let result = try ImportEngine().run(request)
            report("run=\(index) imported=\(result.imported) skipped=\(result.skipped)")
        }
        report("post_import_idle")
        Thread.sleep(forTimeInterval: 60)
        report("finished")
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
