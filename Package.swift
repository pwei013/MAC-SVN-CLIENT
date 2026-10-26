// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SVNManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SVNManager", targets: ["SVNManager"])],
    targets: [
        .target(name: "SVNCore"),
        .executableTarget(name: "SVNManager", dependencies: ["SVNCore"]),
        .executableTarget(name: "SVNCoreChecks", dependencies: ["SVNCore"], path: "Tests/SVNCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
