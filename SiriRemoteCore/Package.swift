// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SiriRemoteCore",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "SiriRemoteCore", type: .static, targets: ["SiriRemoteCore"]),
        .library(name: "RemoteInputCore", type: .static, targets: ["RemoteInputCore"]),
    ],
    targets: [
        .target(name: "SiriRemoteCore"),
        .target(name: "RemoteInputCore"),
        .testTarget(name: "SiriRemoteCoreTests", dependencies: ["SiriRemoteCore"]),
        .testTarget(name: "RemoteInputCoreTests", dependencies: ["RemoteInputCore"]),
    ]
)
