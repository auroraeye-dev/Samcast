import SwiftUI
import AVFoundation
import QuackCastPlatform

/// Shows the live camera feed using an AVCaptureVideoPreviewLayer, mirrored so
/// it feels like a mirror to the user.
struct CameraPreview: NSViewRepresentable {
    let tracker: VisionHandTracker

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = tracker.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
