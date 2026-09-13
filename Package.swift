// swift-tools-version: 5.9
import PackageDescription

// GestureCastCore is the portable "brain" of the app: gesture classification,
// temporal debouncing, and the session state machine. It depends only on
// Foundation and contains ZERO Apple UI/media framework imports, so its logic
// and tests run on any Swift toolchain (including a future Windows port that
// reimplements only the platform adapters defined by the protocols here).
let package = Package(
    name: "GestureCastCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GestureCastCore", targets: ["GestureCastCore"]),
        // A dependency-free smoke test runnable with `swift run CoreCheck`,
        // even on a machine with only Command Line Tools (no full Xcode / no
        // XCTest). The XCTest suite below is the richer suite used in Xcode/CI.
        .executable(name: "CoreCheck", targets: ["CoreCheck"])
    ],
    targets: [
        .target(name: "GestureCastCore"),
        .executableTarget(name: "CoreCheck", dependencies: ["GestureCastCore"]),
        .testTarget(
            name: "GestureCastCoreTests",
            dependencies: ["GestureCastCore"]
        )
    ]
)
