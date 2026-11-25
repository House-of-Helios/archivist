// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArchivistCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchivistCore", targets: ["ArchivistCore"]),
        .executable(name: "archivist", targets: ["archivist"]),
    ],
    targets: [
        .target(name: "ArchivistCore"),
        .executableTarget(name: "archivist", dependencies: ["ArchivistCore"]),
        .testTarget(name: "ArchivistCoreTests", dependencies: ["ArchivistCore"]),
    ]
)
