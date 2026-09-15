import XCTest
@testable import SamcastCore

final class GestureClassifierTests: XCTestCase {
    // Builds a synthetic hand. `curl` in 0...1 pulls fingertips back toward the
    // palm (1 = fully curled fist), so we can fabricate open/closed hands.
    private func makeHand(curl: Double, thumbIndexGap: Double = 0.6, confidence: Double = 0.9) -> HandLandmarks {
        // Wrist at bottom, fingers pointing "up" (decreasing y).
        let wrist = Point2D(x: 0.5, y: 1.0)
        var pts: [HandJoint: Point2D] = [.wrist: wrist]

        // middleMCP defines palm span (~0.25 above wrist).
        pts[.middleMCP] = Point2D(x: 0.5, y: 0.75)

        // Lay out the four fingers across x, with PIP mid-way and TIP at top.
        let fingers: [(mcp: HandJoint, pip: HandJoint, tip: HandJoint, x: Double)] = [
            (.indexMCP, .indexPIP, .indexTip, 0.40),
            (.middleMCP, .middlePIP, .middleTip, 0.50),
            (.ringMCP, .ringPIP, .ringTip, 0.60),
            (.littleMCP, .littlePIP, .littleTip, 0.68)
        ]
        for f in fingers {
            let mcpY = 0.75
            let pipY = 0.62
            // Extended tip is well above the pip (0.48); curled tip drops back
            // below the pip toward the palm.
            let extendedTipY = 0.48
            let curledTipY = 0.70
            let tipY = extendedTipY + (curledTipY - extendedTipY) * curl
            pts[f.mcp] = Point2D(x: f.x, y: mcpY)
            pts[f.pip] = Point2D(x: f.x, y: pipY)
            pts[f.tip] = Point2D(x: f.x, y: tipY)
        }

        // Thumb: index tip sits at (0.40, tipY). Place thumb tip at a set gap.
        let indexTip = pts[.indexTip]!
        pts[.thumbTip] = Point2D(x: indexTip.x - thumbIndexGap * 0.25, y: indexTip.y + thumbIndexGap * 0.25 * 0.5)

        return HandLandmarks(points: pts, confidence: confidence)
    }

    func testOpenHandIsClassifiedAsOpen() {
        let classifier = GestureClassifier()
        let hand = makeHand(curl: 0.0)
        XCTAssertEqual(classifier.extendedFingerCount(hand), 4)
        XCTAssertEqual(classifier.classify(hand), .openHand)
    }

    func testFistIsClassifiedAsClosed() {
        let classifier = GestureClassifier()
        let hand = makeHand(curl: 1.0)
        XCTAssertEqual(classifier.extendedFingerCount(hand), 0)
        XCTAssertEqual(classifier.classify(hand), .closedHand)
    }

    func testLowConfidenceIsNone() {
        let classifier = GestureClassifier()
        let hand = makeHand(curl: 0.0, confidence: 0.2)
        XCTAssertEqual(classifier.classify(hand), .none)
    }

    func testIndexAndMiddleExtendedIsPeace() {
        let classifier = GestureClassifier()
        // Index + middle extended -> the V sign used for screenshots.
        var hand = makeHand(curl: 0.0)
        // Curl the ring and little fingers by moving their tips below the pip.
        for tip in [HandJoint.ringTip, .littleTip] {
            let pip = tip == .ringTip ? hand[.ringPIP]! : hand[.littlePIP]!
            hand.points[tip] = Point2D(x: pip.x, y: pip.y + 0.1)
        }
        XCTAssertEqual(classifier.extendedFingerCount(hand), 2)
        XCTAssertEqual(classifier.classify(hand), .peace)
    }
}
