import GestureCastCore
import Foundation

// A tiny, dependency-free assertion harness so the core logic can be verified
// on any Swift toolchain (including Command Line Tools without XCTest).

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ FAIL: \(message)  (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
    expect(a == b, "\(message) — expected \(b), got \(a)", file: file, line: line)
}

func section(_ name: String) { print("• \(name)") }

// Synthetic hand builder mirroring the XCTest fixture.
func makeHand(curl: Double, thumbIndexGap: Double = 0.6, confidence: Double = 0.9) -> HandLandmarks {
    var pts: [HandJoint: Point2D] = [.wrist: Point2D(x: 0.5, y: 1.0)]
    pts[.middleMCP] = Point2D(x: 0.5, y: 0.75)
    let fingers: [(mcp: HandJoint, pip: HandJoint, tip: HandJoint, x: Double)] = [
        (.indexMCP, .indexPIP, .indexTip, 0.40),
        (.middleMCP, .middlePIP, .middleTip, 0.50),
        (.ringMCP, .ringPIP, .ringTip, 0.60),
        (.littleMCP, .littlePIP, .littleTip, 0.68)
    ]
    for f in fingers {
        pts[f.mcp] = Point2D(x: f.x, y: 0.75)
        pts[f.pip] = Point2D(x: f.x, y: 0.62)
        let tipY = 0.48 + (0.70 - 0.48) * curl
        pts[f.tip] = Point2D(x: f.x, y: tipY)
    }
    let indexTip = pts[.indexTip]!
    pts[.thumbTip] = Point2D(x: indexTip.x - thumbIndexGap * 0.25, y: indexTip.y + thumbIndexGap * 0.125)
    return HandLandmarks(points: pts, confidence: confidence)
}

print("GestureCast core smoke test\n")

section("GestureClassifier")
do {
    let c = GestureClassifier()
    expectEqual(c.classify(makeHand(curl: 0.0)), .openHand, "open hand")
    expectEqual(c.classify(makeHand(curl: 1.0)), .closedHand, "fist")
    expectEqual(c.classify(makeHand(curl: 0.0, thumbIndexGap: 0.05)), .pinch, "pinch priority")
    expectEqual(c.classify(makeHand(curl: 0.0, confidence: 0.2)), HandGesture.none, "low confidence -> none")
}

section("GestureDebouncer")
do {
    var d = GestureDebouncer(holdDuration: 0.25)
    expect(d.update(.openHand, at: 0.0) == nil, "not fired on first frame")
    expect(d.update(.openHand, at: 0.1) == nil, "not fired before hold")
    expectEqual(d.update(.openHand, at: 0.3), .openHand, "fires after hold")
    expect(d.update(.openHand, at: 0.6) == nil, "no re-fire while held")
}

section("SessionCoordinator — two-device handshake")
do {
    let mac = Peer(id: "A", displayName: "Mac A", kind: .mac)
    let ipad = Peer(id: "B", displayName: "iPad B", kind: .iPad)
    var a = SessionCoordinator()
    var b = SessionCoordinator()

    expectEqual(a.reduce(.localGesture(.closedHand)), [.startScreenCapture, .advertiseSourceAvailable], "A arms on close")
    expectEqual(a.state, .armedSource, "A is armed source")

    _ = b.reduce(.remoteSourceBecameAvailable(mac))
    expectEqual(b.reduce(.localGesture(.openHand)), [.requestCastFromPeer(mac), .showRemoteScreen(from: mac)], "B requests cast on open")
    expectEqual(b.state, .receiving(from: mac), "B is receiving")

    expectEqual(a.reduce(.remoteRequestedCast(ipad)), [.startStreaming(to: ipad), .withdrawSourceAvailable], "A starts streaming")
    expectEqual(a.state, .casting(to: ipad), "A is casting")

    expectEqual(a.reduce(.localGesture(.snap)), [.takeScreenshot], "snap screenshots")
    expectEqual(a.state, .casting(to: ipad), "snap does not change state")
}

print("")
if failures == 0 {
    print("✅ All \(checks) checks passed")
    exit(0)
} else {
    print("❌ \(failures) of \(checks) checks failed")
    exit(1)
}
