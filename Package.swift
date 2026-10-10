// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActionImport",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ActionImportCore", targets: ["ActionImportCore"]),
        .executable(name: "ActionImport", targets: ["ActionImport"]),
        .executable(name: "ActionImportChecks", targets: ["ActionImportChecks"]),
    ],
    targets: [
        .target(name: "ActionImportCore"),
        .executableTarget(name: "ActionImport", dependencies: ["ActionImportCore"]),
        .executableTarget(name: "ActionImportChecks", dependencies: ["ActionImportCore"], path: "Tests/ActionImportCoreTests"),
    ]
)
