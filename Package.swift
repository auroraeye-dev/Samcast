// swift-tools-version: 5.9
import PackageDescription

// QuackCastCore is the portable "brain" of the app: gesture classification,
// temporal debouncing, and the session state machine. It depends only on
// Foundation and contains ZERO Apple UI/media framework imports, so its logic
// and tests run on any Swift toolchain (including a future Windows port that
// reimplements only the platform adapters defined by the protocols here).
let package = Package(
    name: "QuackCastCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "QuackCastCore", targets: ["QuackCastCore"]),
        // Apple-framework adapters (Vision / AVFoundation / ScreenCaptureKit /
        // MultipeerConnectivity) implementing the core's Ports. Kept free of
        // SwiftUI so it type-checks with `swift build` even without full Xcode.
        .library(name: "QuackCastPlatform", targets: ["QuackCastPlatform"]),
        // A dependency-free smoke test runnable with `swift run CoreCheck`,
        // even on a machine with only Command Line Tools (no full Xcode / no
        // XCTest). The XCTest suite below is the richer suite used in Xcode/CI.
        .executable(name: "CoreCheck", targets: ["CoreCheck"]),
        // Headless peer used to test casting without a second device.
        .executable(name: "CastPeer", targets: ["CastPeer"])
    ],
    targets: [
        .target(name: "QuackCastCore"),
        .target(name: "QuackCastPlatform", dependencies: ["QuackCastCore"]),
        .executableTarget(name: "CoreCheck", dependencies: ["QuackCastCore"]),
        .executableTarget(name: "CastPeer", dependencies: ["QuackCastCore", "QuackCastPlatform"]),
        .testTarget(
            name: "QuackCastCoreTests",
            dependencies: ["QuackCastCore"]
        )
    ]
)
