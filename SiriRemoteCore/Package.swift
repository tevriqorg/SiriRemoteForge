// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SiriRemoteCore",
    platforms: [.macOS(.v11)],
    products: [.library(name: "SiriRemoteCore", type: .static, targets: ["SiriRemoteCore"])],
    targets: [
        .target(name: "SiriRemoteCore"),
        .testTarget(name: "SiriRemoteCoreTests", dependencies: ["SiriRemoteCore"]),
    ]
)
