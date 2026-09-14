#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import QuackCastCore

/// Apple adapter for `ScreenSource`, backed by ScreenCaptureKit for the live
/// stream and CoreGraphics for one-shot stills. Emitted frames are
/// `CVPixelBuffer`s handed back as `Any` (the core stays pixel-format-neutral);
/// the app encodes them (e.g. to JPEG) before sending over the transport.
@available(macOS 12.3, *)
public final class ScreenCaptureKitSource: NSObject, ScreenSource, SCStreamOutput, SCStreamDelegate {
    public var onFrame: ((Any, TimeInterval) -> Void)?

    /// Reports what is being cast, e.g. "Safari — Example Page", so the user
    /// can see exactly which window left their screen.
    public var onCaptureTarget: ((String) -> Void)?

    /// Reports why capture could not start. Without this the failure is
    /// invisible: SCShareableContent simply returns an error and the stream
    /// never produces a frame.
    public var onCaptureError: ((String) -> Void)?

    /// Target capture frame rate. 15 is plenty for sharing a screen and halves
    /// the bytes compared with 30.
    public var framesPerSecond: Int = 15

    /// Capture is downscaled to at most this width before encoding. A Retina
    /// display is far too large to push over a peer-to-peer link frame by
    /// frame; scaling here (rather than after capture) also saves the encode
    /// and copy cost of the full-size image.
    public var maxCaptureWidth: Int = 1800

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

        // NOTE: deliberately NOT gating on CGPreflightScreenCaptureAccess().
        // In sandboxed apps it can report false even when capture is actually
        // permitted, which would block capture no matter how often the user
        // grants it. SCShareableContent raises the system prompt by itself when
        // access really is missing, so just attempt the capture.
        isRunning = true
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.isRunning = false
                self.report("Screen capture blocked: \(error.localizedDescription). Enable Screen Recording for QuackCast in System Settings ▸ Privacy & Security, then reopen the app.")
                return
            }
            guard let content, !content.displays.isEmpty else {
                self.isRunning = false
                self.report("Screen capture failed: no display available.")
                return
            }

            // Cast the window the user is working in. There is deliberately no
            // whole-desktop fallback: casting the desktop would include any
            // window showing the cast, creating a feedback loop.
            guard let window = self.frontmostWindow(in: content) else {
                self.isRunning = false
                self.report("Nothing to cast — open an app window first, then make a fist while it's in front.")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let sourceWidth = Int(window.frame.width)
            let sourceHeight = Int(window.frame.height)
            let app = window.owningApplication?.applicationName ?? "Window"
            let title = window.title ?? ""
            let label = title.isEmpty ? app : "\(app) — \(title)"
            let targetHandler = self.onCaptureTarget
            DispatchQueue.main.async { targetHandler?(label) }

            let config = SCStreamConfiguration()
            // Downscale, preserving aspect ratio, to keep frames small enough
            // to actually stream. Dimensions are kept even for the encoder.
            let scale = min(1.0, Double(self.maxCaptureWidth) / Double(max(sourceWidth, 1)))
            config.width = max(2, (Int(Double(sourceWidth) * scale) / 2) * 2)
            config.height = max(2, (Int(Double(sourceHeight) * scale) / 2) * 2)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.framesPerSecond))
            // Shallow queue: for live sharing a fresh frame beats a backlog.
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
            } catch {
                self.isRunning = false
                self.report("Screen capture failed to start: \(error.localizedDescription)")
                return
            }
            self.stream = stream
            stream.startCapture { [weak self] error in
                guard let self, let error else { return }
                self.isRunning = false
                self.report("Screen capture could not start: \(error.localizedDescription)")
            }
        }
    }

    /// The window the user was last working in — the topmost normal window
    /// that isn't QuackCast's own.
    ///
    /// Uses CGWindowListCopyWindowInfo because it is genuinely front-to-back
    /// z-ordered (SCShareableContent's order is not documented), and skips our
    /// own windows so arming the cast while looking at QuackCast still picks
    /// the app you came from rather than falling back to the whole desktop.
    private func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infos {
            // Skip every QuackCast-family window — the app itself and any
            // viewer/receiver process. Capturing a window that is *displaying*
            // the cast feeds the stream back into itself and produces an
            // infinite mirror tunnel.
            let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            if owner.contains("quackcast") || owner.contains("castpeer") { continue }

            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  // Layer 0 is a normal window; higher layers are menu bar,
                  // Dock, overlays and so on.
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 120, (bounds["Height"] ?? 0) > 120
            else { continue }
            if let match = content.windows.first(where: { $0.windowID == windowID }) {
                return match
            }
        }
        return nil
    }

    private func report(_ message: String) {
        let handler = onCaptureError
        DispatchQueue.main.async { handler?(message) }
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
        // Attempt the capture and report the *real* outcome. We don't pre-check
        // CGPreflightScreenCaptureAccess() because it can wrongly report false
        // in a sandboxed app and would then block a capture that would succeed.
        let cgImage: CGImage
        if #available(macOS 14.0, *) {
            cgImage = try await mainDisplayImage()
        } else if let legacy = CGDisplayCreateImage(CGMainDisplayID()) {
            cgImage = legacy
        } else {
            throw CaptureError.stillFailed
        }

        // Saved to the Desktop, where screenshots are expected to appear.
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
        isRunning = false
        report("Screen capture stopped: \(error.localizedDescription)")
    }

    public enum CaptureError: Error { case stillFailed, permissionRequired }
}
#endif
