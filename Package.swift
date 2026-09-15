// swift-tools-version: 5.9
import PackageDescription

// SamcastCore is the portable "brain" of the app: gesture classification,
// temporal debouncing, and the session state machine. It depends only on
// Foundation and contains ZERO Apple UI/media framework imports, so its logic
// and tests run on any Swift toolchain (including a future Windows port that
// reimplements only the platform adapters defined by the protocols here).
let package = Package(
    name: "SamcastCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SamcastCore", targets: ["SamcastCore"]),
        // Apple-framework adapters (Vision / AVFoundation / ScreenCaptureKit /
        // MultipeerConnectivity) implementing the core's Ports. Kept free of
        // SwiftUI so it type-checks with `swift build` even without full Xcode.
        .library(name: "SamcastPlatform", targets: ["SamcastPlatform"]),
        // A dependency-free smoke test runnable with `swift run CoreCheck`,
        // even on a machine with only Command Line Tools (no full Xcode / no
        // XCTest). The XCTest suite below is the richer suite used in Xcode/CI.
        .executable(name: "CoreCheck", targets: ["CoreCheck"]),
        // Headless peer used to test casting without a second device.
        .executable(name: "CastPeer", targets: ["CastPeer"])
    ],
    targets: [
        .target(name: "SamcastCore"),
        .target(name: "SamcastPlatform", dependencies: ["SamcastCore"]),
        .executableTarget(name: "CoreCheck", dependencies: ["SamcastCore"]),
        .executableTarget(name: "CastPeer", dependencies: ["SamcastCore", "SamcastPlatform"]),
        .testTarget(
            name: "SamcastCoreTests",
            dependencies: ["SamcastCore"]
        )
    ]
)
