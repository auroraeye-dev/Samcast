import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import QuackCastCore

/// Apple adapter for `ScreenSource`, backed by ScreenCaptureKit for the live
/// stream and CoreGraphics for one-shot stills. Emitted frames are
/// `CVPixelBuffer`s handed back as `Any` (the core stays pixel-format-neutral);
/// the app encodes them (e.g. to JPEG) before sending over the transport.
@available(macOS 12.3, *)
public final class ScreenCaptureKitSource: NSObject, ScreenSource, SCStreamOutput, SCStreamDelegate {
    public var onFrame: ((Any, TimeInterval) -> Void)?

    /// Target capture frame rate.
    public var framesPerSecond: Int = 30

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.quackcast.sck.samples")

    public override init() { super.init() }

    public func startCapture() throws {
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.framesPerSecond))
            config.queueDepth = 5

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
            } catch {
                return
            }
            self.stream = stream
            stream.startCapture { _ in }
        }
    }

    public func stopCapture() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    /// One-shot still of the main display, written to a temp PNG. Uses
    /// CoreGraphics so it stays synchronous and works back to macOS 12.
    public func captureStill() throws -> URL {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw CaptureError.stillFailed
        }
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("QuackCast-\(Int(Date().timeIntervalSince1970)).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.stillFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.stillFailed }
        return url
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(pixelBuffer, time)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
    }

    public enum CaptureError: Error { case stillFailed }
}
