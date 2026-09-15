import XCTest
@testable import SamcastCore

final class SessionCoordinatorTests: XCTestCase {
    private let mac = Peer(id: "A", displayName: "Mac A", kind: .mac)
    private let ipad = Peer(id: "B", displayName: "iPad B", kind: .iPad)

    func testCloseHandArmsSourceAndAdvertises() {
        var c = SessionCoordinator()
        let effects = c.reduce(.localGesture(.closedHand))
        XCTAssertEqual(c.state, .armedSource)
        XCTAssertEqual(effects, [.startScreenCapture, .advertiseSourceAvailable])
    }

    func testCloseAgainDisarms() {
        var c = SessionCoordinator()
        _ = c.reduce(.localGesture(.closedHand))
        let effects = c.reduce(.localGesture(.closedHand))
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(effects, [.stopScreenCapture, .withdrawSourceAvailable])
    }

    func testOpenHandWithNoSourceDoesNothing() {
        var c = SessionCoordinator()
        let effects = c.reduce(.localGesture(.openHand))
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(effects.isEmpty)
    }

    func testOpenHandReceivesFromAvailableSource() {
        var c = SessionCoordinator()
        _ = c.reduce(.remoteSourceBecameAvailable(mac))
        let effects = c.reduce(.localGesture(.openHand))
        XCTAssertEqual(c.state, .receiving(from: mac))
        XCTAssertEqual(effects, [.requestCastFromPeer(mac), .showRemoteScreen(from: mac)])
    }

    func testPreferredSourceIsMostRecent() {
        var c = SessionCoordinator()
        _ = c.reduce(.remoteSourceBecameAvailable(mac))
        _ = c.reduce(.remoteSourceBecameAvailable(ipad))
        XCTAssertEqual(c.preferredSource, ipad)
    }

    func testWithdrawnSourceIsRemoved() {
        var c = SessionCoordinator()
        _ = c.reduce(.remoteSourceBecameAvailable(mac))
        _ = c.reduce(.remoteSourceWithdrawn(mac))
        XCTAssertNil(c.preferredSource)
    }

    func testArmedSourceStartsCastingWhenPeerRequests() {
        var c = SessionCoordinator()
        _ = c.reduce(.localGesture(.closedHand)) // armedSource
        let effects = c.reduce(.remoteRequestedCast(ipad))
        XCTAssertEqual(c.state, .casting(to: ipad))
        XCTAssertEqual(effects, [.startStreaming(to: ipad), .withdrawSourceAvailable])
    }

    func testCastRequestIgnoredWhenNotArmed() {
        var c = SessionCoordinator()
        let effects = c.reduce(.remoteRequestedCast(ipad))
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(effects.isEmpty)
    }

    func testClosingHandStopsCasting() {
        var c = SessionCoordinator()
        _ = c.reduce(.localGesture(.closedHand))
        _ = c.reduce(.remoteRequestedCast(ipad))
        let effects = c.reduce(.localGesture(.closedHand))
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(effects, [.stopStreaming(to: ipad), .stopScreenCapture, .notifyEndedCast(to: ipad)])
    }

    func testReceiverClosingHandHidesRemoteScreen() {
        var c = SessionCoordinator()
        _ = c.reduce(.remoteSourceBecameAvailable(mac))
        _ = c.reduce(.localGesture(.openHand)) // receiving
        let effects = c.reduce(.localGesture(.closedHand))
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(effects, [.hideRemoteScreen, .notifyEndedCast(to: mac)])
    }

    func testSnapTakesScreenshotWithoutChangingState() {
        var c = SessionCoordinator()
        _ = c.reduce(.localGesture(.closedHand)) // armedSource
        let effects = c.reduce(.localGesture(.peace))
        XCTAssertEqual(c.state, .armedSource)
        XCTAssertEqual(effects, [.takeScreenshot])
    }

    func testFullTwoDeviceHandshake() {
        // Simulate Mac A (source) and iPad B (receiver) exchanging messages.
        var a = SessionCoordinator()
        var b = SessionCoordinator()

        // A closes hand -> arms + advertises.
        XCTAssertEqual(a.reduce(.localGesture(.closedHand)), [.startScreenCapture, .advertiseSourceAvailable])
        // B learns A is available (transport relayed sourceAvailable).
        _ = b.reduce(.remoteSourceBecameAvailable(mac))
        // B opens hand -> requests cast from A.
        XCTAssertEqual(b.reduce(.localGesture(.openHand)), [.requestCastFromPeer(mac), .showRemoteScreen(from: mac)])
        XCTAssertEqual(b.state, .receiving(from: mac))
        // A receives the request -> starts streaming.
        XCTAssertEqual(a.reduce(.remoteRequestedCast(ipad)), [.startStreaming(to: ipad), .withdrawSourceAvailable])
        XCTAssertEqual(a.state, .casting(to: ipad))
    }
}
