// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkDownEditor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MarkDownEditor", targets: ["MarkDownEditor"])],
    targets: [
        .executableTarget(name: "MarkDownEditor"),
        .testTarget(name: "MarkDownEditorTests", dependencies: ["MarkDownEditor"])
    ]
)
