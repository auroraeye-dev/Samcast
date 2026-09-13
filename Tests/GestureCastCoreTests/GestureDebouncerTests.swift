import XCTest
@testable import GestureCastCore

final class GestureDebouncerTests: XCTestCase {
    func testGestureMustBeHeldBeforeFiring() {
        var d = GestureDebouncer(holdDuration: 0.25)
        XCTAssertNil(d.update(.openHand, at: 0.0))   // first frame: candidate set
        XCTAssertNil(d.update(.openHand, at: 0.1))   // held 0.1s: not yet
        XCTAssertEqual(d.update(.openHand, at: 0.3), .openHand) // held 0.3s: fires
        XCTAssertEqual(d.current, .openHand)
    }

    func testDoesNotRefireWhileHeld() {
        var d = GestureDebouncer(holdDuration: 0.2)
        _ = d.update(.closedHand, at: 0.0)
        XCTAssertEqual(d.update(.closedHand, at: 0.25), .closedHand)
        XCTAssertNil(d.update(.closedHand, at: 0.5)) // still held: no re-fire
        XCTAssertNil(d.update(.closedHand, at: 1.0))
    }

    func testJitterResetsCandidate() {
        var d = GestureDebouncer(holdDuration: 0.2)
        _ = d.update(.openHand, at: 0.0)
        _ = d.update(.none, at: 0.1)      // flicker resets the timer
        XCTAssertNil(d.update(.openHand, at: 0.25)) // only 0.15s since restart
        XCTAssertEqual(d.update(.openHand, at: 0.5), .openHand)
    }

    func testTransitionBetweenTwoStableGestures() {
        var d = GestureDebouncer(holdDuration: 0.1)
        _ = d.update(.closedHand, at: 0.0)
        XCTAssertEqual(d.update(.closedHand, at: 0.2), .closedHand)
        _ = d.update(.openHand, at: 0.3)
        XCTAssertEqual(d.update(.openHand, at: 0.5), .openHand)
    }
}
