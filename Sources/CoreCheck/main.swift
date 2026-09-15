import SamcastCore
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

print("Samcast core smoke test\n")

section("GestureClassifier")
do {
    let c = GestureClassifier()
    expectEqual(c.classify(makeHand(curl: 0.0)), .openHand, "open hand")
    expectEqual(c.classify(makeHand(curl: 1.0)), .closedHand, "fist")
    expectEqual(c.classify(makeHand(curl: 0.0, confidence: 0.2)), HandGesture.none, "low confidence -> none")
}

section("Peace sign (screenshot gesture)")
do {
    let c = GestureClassifier()
    // Curl only ring + little on an otherwise open hand -> V sign.
    var v = makeHand(curl: 0.0)
    for tip in [HandJoint.ringTip, .littleTip] {
        let pip = tip == .ringTip ? v[.ringPIP]! : v[.littlePIP]!
        v.points[tip] = Point2D(x: pip.x, y: pip.y + 0.1)
    }
    let f = c.extendedFingers(v)
    expect(f.index && f.middle, "index and middle extended")
    expect(!f.ring && !f.little, "ring and little curled")
    expectEqual(f.count, 2, "exactly two fingers extended")
    expectEqual(c.classify(v), .peace, "V sign classifies as peace")
    // Must not be confused with the casting gestures.
    expectEqual(c.classify(makeHand(curl: 0.0)), .openHand, "open palm is still openHand")
    expectEqual(c.classify(makeHand(curl: 1.0)), .closedHand, "fist is still closedHand")
}

section("GestureDebouncer")
do {
    var d = GestureDebouncer(holdDuration: 0.25)
    expect(d.update(.openHand, at: 0.0) == nil, "not fired on first frame")
    expect(d.update(.openHand, at: 0.1) == nil, "not fired before hold")
    expectEqual(d.update(.openHand, at: 0.3), .openHand, "fires after hold")
    expect(d.update(.openHand, at: 0.6) == nil, "no re-fire while held")
}

section("DeviceIdentity")
do {
    // Use a scratch defaults domain so the real identity isn't touched.
    let suite = "samcast.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!

    let first = DeviceIdentity.loadOrCreate(defaults: defaults)
    expect(!first.id.isEmpty, "identity has an id")
    expect(first.name.split(separator: "-").count == 3, "name looks like adjective-animal-number")

    // The whole point is that it survives restarts.
    let second = DeviceIdentity.loadOrCreate(defaults: defaults)
    expectEqual(second.id, first.id, "id persists across loads")
    expectEqual(second.name, first.name, "name persists across loads")

    DeviceIdentity.rename(to: "kitchen-mac", defaults: defaults)
    expectEqual(DeviceIdentity.loadOrCreate(defaults: defaults).name, "kitchen-mac", "rename sticks")
    DeviceIdentity.rename(to: "   ", defaults: defaults)
    expectEqual(DeviceIdentity.loadOrCreate(defaults: defaults).name, "kitchen-mac", "blank rename ignored")

    defaults.removePersistentDomain(forName: suite)
}

section("TrustStore")
do {
    let suite = "samcast.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let trust = TrustStore(defaults: defaults)

    expect(!trust.isTrusted("peer-a"), "unknown peer is not trusted")
    trust.trust("peer-a", name: "swift-heron-1234")
    expect(trust.isTrusted("peer-a"), "accepted peer becomes trusted")
    expectEqual(trust.trusted["peer-a"], "swift-heron-1234", "remembers the name")

    // Trust must survive a new store, or it isn't trust.
    let reopened = TrustStore(defaults: defaults)
    expect(reopened.isTrusted("peer-a"), "trust persists")

    trust.untrust("peer-a")
    expect(!trust.isTrusted("peer-a"), "untrust removes it")
    trust.trust("peer-b", name: "b")
    trust.untrustAll()
    expect(trust.trusted.isEmpty, "untrustAll clears everything")

    defaults.removePersistentDomain(forName: suite)
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

    expectEqual(a.reduce(.localGesture(.peace)), [.takeScreenshot], "T-pose screenshots")
    expectEqual(a.state, .casting(to: ipad), "T-pose does not change state")
}

// ---------------------------------------------------------------------------
section("Trust is asked once, and remembered either way")
do {
    // A throwaway suite, so the real trust store is never touched.
    let defaults = UserDefaults(suiteName: "samcast.checks.trust")!
    defaults.removePersistentDomain(forName: "samcast.checks.trust")
    let trust = TrustStore(defaults: defaults)

    expect(!trust.isKnown("peer-A"), "a device starts unknown, so it gets asked")

    trust.trust("peer-A", name: "swift-heron-3172")
    expect(trust.isTrusted("peer-A"), "allowing is remembered")
    expect(trust.isKnown("peer-A"), "and it is never asked about again")
    expect(!trust.isBlocked("peer-A"), "allowed is not blocked")

    trust.block("peer-B", name: "teal-lynx-2222")
    expect(trust.isBlocked("peer-B"), "declining is remembered too")
    expect(trust.isKnown("peer-B"), "so a refused device stops asking")
    expect(!trust.isTrusted("peer-B"), "declined is not trusted")

    // The two states must be mutually exclusive, or the app has to guess
    // which one wins — and a device that is both would be a security bug.
    trust.trust("peer-B", name: "teal-lynx-2222")
    expect(trust.isTrusted("peer-B"), "changing your mind allows it")
    expect(!trust.isBlocked("peer-B"), "and clears the refusal")

    trust.block("peer-A", name: "swift-heron-3172")
    expect(trust.isBlocked("peer-A"), "changing your mind the other way blocks it")
    expect(!trust.isTrusted("peer-A"), "and clears the trust")

    trust.unblock("peer-A")
    expect(!trust.isKnown("peer-A"), "unblocking returns it to being asked about")

    defaults.removePersistentDomain(forName: "samcast.checks.trust")
}

// ---------------------------------------------------------------------------
section("Mac to Mac — both ends can be a source")
do {
    // Only two Macs can reach this. An iPad is never a source, so it is always
    // idle and free to receive; two Macs can each arm themselves, and then
    // neither answers the other — one sits offering while the other ignores
    // every open hand, and a page closes on the sender and arrives nowhere.
    let macA = Peer(id: "A", displayName: "Mac A", kind: .mac)
    let macB = Peer(id: "B", displayName: "Mac B", kind: .mac)
    var b = SessionCoordinator()

    _ = b.reduce(.localGesture(.closedHand))
    expectEqual(b.state, .armedSource, "B armed itself first")

    _ = b.reduce(.remoteSourceBecameAvailable(macA))
    let effects = b.reduce(.localGesture(.openHand))
    expectEqual(effects, [.stopScreenCapture, .withdrawSourceAvailable,
                          .requestCastFromPeer(macA), .showRemoteScreen(from: macA)],
                "an armed device takes what is offered when you open your hand")
    expectEqual(b.state, .receiving(from: macA), "and becomes the receiver")

    // Its own offer must be withdrawn before it starts receiving, or the far
    // side is left holding a request against a device that has moved on.
    expect(effects.firstIndex(of: .withdrawSourceAvailable)! <
           effects.firstIndex(of: .requestCastFromPeer(macA))!,
           "it stops offering before it starts asking")

    // With nobody offering, an open hand while armed still does nothing —
    // you cannot cast to yourself.
    var c = SessionCoordinator()
    _ = c.reduce(.localGesture(.closedHand))
    expectEqual(c.reduce(.localGesture(.openHand)), [], "no source offering, so nothing happens")
    expectEqual(c.state, .armedSource, "and it stays armed")

    _ = macB   // named for symmetry with the scenario above
}

// ---------------------------------------------------------------------------
section("Live-meeting detection (docs/meeting-vectors.json)")
do {
    // Shared with the Windows build's test suite, so all three platforms agree
    // on what counts as a call. A misread fist on an ordinary page costs a
    // reopened tab; on a live meeting it drops you out of the call.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // CoreCheck
        .deletingLastPathComponent()      // Sources
        .deletingLastPathComponent()      // repo root
        .appendingPathComponent("docs/meeting-vectors.json")

    struct Fixture: Decodable {
        struct Case: Decodable {
            let url: String
            let expect_service: String?
            let expect_code: String?
        }
        let cases: [Case]
    }

    if let data = try? Data(contentsOf: url),
       let fixture = try? JSONDecoder().decode(Fixture.self, from: data) {
        expect(!fixture.cases.isEmpty, "meeting fixtures are present")
        for item in fixture.cases {
            switch PageRiskDetector.assess(item.url) {
            case .ordinary:
                expect(item.expect_service == nil,
                       "\(item.url) should have been \(item.expect_service ?? "-")")
            case .liveMeeting(let match):
                expectEqual(match.service, item.expect_service ?? "(none expected)",
                            "service for \(item.url)")
                if let expected = item.expect_code {
                    expectEqual(match.code ?? "(nil)", expected, "code for \(item.url)")
                }
            }
        }
    } else {
        expect(false, "could not read docs/meeting-vectors.json")
    }

    // The prompt exists to gate the destructive step, so this flag is what the
    // app branches on.
    expect(PageRiskDetector.assess("https://meet.google.com/abc-defg-hij").needsConfirmation,
           "a live meeting needs confirmation")
    expect(!PageRiskDetector.assess("https://example.com").needsConfirmation,
           "an ordinary page does not")
    // Nonsense must not block a handoff it merely failed to parse.
    expectEqual(PageRiskDetector.assess("not a url"), PageRisk.ordinary,
                "unparseable input is treated as ordinary")
    expectEqual(PageRiskDetector.assess(""), PageRisk.ordinary,
                "empty input is treated as ordinary")
}

print("")
if failures == 0 {
    print("✅ All \(checks) checks passed")
    exit(0)
} else {
    print("❌ \(failures) of \(checks) checks failed")
    exit(1)
}
