import Foundation
import AVFoundation
import Vision
import QuackCastCore

/// Apple adapter for `HandTracker`: owns the camera capture session and runs
/// Vision's hand-pose request on every frame, translating Vision's joint names
/// into the core's neutral `HandLandmarks`.
///
/// The `onHand` callback is invoked on a background queue; hop to the main
/// queue before touching UI.
public final class VisionHandTracker: NSObject, HandTracker, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var onHand: ((HandLandmarks?, TimeInterval) -> Void)?

    /// Vision points below this confidence are dropped from the landmark set.
    public var minPointConfidence: Float = 0.3

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.quackcast.vision.video")
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    /// Maps Vision joint names to our neutral joint enum (1:1).
    private static let jointMap: [VNHumanHandPoseObservation.JointName: HandJoint] = [
        .wrist: .wrist,
        .thumbCMC: .thumbCMC, .thumbMP: .thumbMP, .thumbIP: .thumbIP, .thumbTip: .thumbTip,
        .indexMCP: .indexMCP, .indexPIP: .indexPIP, .indexDIP: .indexDIP, .indexTip: .indexTip,
        .middleMCP: .middleMCP, .middlePIP: .middlePIP, .middleDIP: .middleDIP, .middleTip: .middleTip,
        .ringMCP: .ringMCP, .ringPIP: .ringPIP, .ringDIP: .ringDIP, .ringTip: .ringTip,
        .littleMCP: .littleMCP, .littlePIP: .littlePIP, .littleDIP: .littleDIP, .littleTip: .littleTip
    ]

    public override init() { super.init() }

    public func start() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            throw TrackerError.noCamera
        }
        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TrackerError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw TrackerError.cannotAddOutput }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()
    }

    public func stop() {
        session.stopRunning()
    }

    /// Exposes the live capture session so the app can show a preview layer.
    public var captureSession: AVCaptureSession { session }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handRequest])
        } catch {
            onHand?(nil, timestamp)
            return
        }

        guard let observation = handRequest.results?.first else {
            onHand?(nil, timestamp)
            return
        }
        onHand?(landmarks(from: observation), timestamp)
    }

    private func landmarks(from observation: VNHumanHandPoseObservation) -> HandLandmarks? {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
        var points: [HandJoint: Point2D] = [:]
        for (visionJoint, joint) in Self.jointMap {
            guard let p = recognized[visionJoint], p.confidence >= minPointConfidence else { continue }
            // Vision uses a bottom-left origin; flip y to a top-left origin so
            // "up" in the image is decreasing y, matching the core's fixtures.
            points[joint] = Point2D(x: Double(p.location.x), y: Double(1.0 - p.location.y))
        }
        guard !points.isEmpty else { return nil }
        return HandLandmarks(points: points, confidence: Double(observation.confidence))
    }

    public enum TrackerError: Error { case noCamera, cannotAddInput, cannotAddOutput }
}
