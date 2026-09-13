#if os(macOS)
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
    private var isRunning = false
    private var didRequestPermission = false
    private let sampleQueue = DispatchQueue(label: "com.quackcast.sck.samples")

    public override init() { super.init() }

    /// Whether Screen Recording permission is currently granted.
    public var hasScreenPermission: Bool { CGPreflightScreenCaptureAccess() }

    public func startCapture() throws {
        // Already capturing — don't start a second stream.
        guard !isRunning else { return }

        // Gate on permission so we prompt AT MOST ONCE rather than on every
        // arming gesture. macOS only makes a fresh grant effective after the
        // app relaunches, so we surface a clear error instead of retrying.
        guard CGPreflightScreenCaptureAccess() else {
            if !didRequestPermission {
                didRequestPermission = true
                CGRequestScreenCaptureAccess() // shows the prompt once
            }
            throw CaptureError.permissionRequired
        }

        isRunning = true
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
        isRunning = false
    }

    /// One-shot still of the main display, saved as a PNG on the Desktop.
    /// Uses ScreenCaptureKit's screenshot API (reliable on modern macOS;
    /// CGDisplayCreateImage is deprecated and increasingly returns nil).
    public func captureStill() async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionRequired }

        let cgImage: CGImage
        if #available(macOS 14.0, *) {
            cgImage = try await mainDisplayImage()
        } else if let legacy = CGDisplayCreateImage(CGMainDisplayID()) {
            cgImage = legacy
        } else {
            throw CaptureError.stillFailed
        }

        // Save to ~/Desktop so the user can actually find it.
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = Self.filenameFormatter.string(from: Date())
        let url = desktop.appendingPathComponent("QuackCast Screenshot \(stamp).png")

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.stillFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.stillFailed }
        return url
    }

    @available(macOS 14.0, *)
    private func mainDisplayImage() async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw CaptureError.stillFailed }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

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

    public enum CaptureError: Error { case stillFailed, permissionRequired }
}
#endif
