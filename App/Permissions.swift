import Foundation
import AVFoundation
import CoreGraphics
import AppKit

/// Tracks the macOS privacy permissions Samcast needs and provides the
/// actions to resolve them. Users should never have to guess which System
/// Settings pane to open, or that a relaunch is required.
@MainActor
final class Permissions: ObservableObject {
    enum State: Equatable {
        case granted, denied, notDetermined
    }

    @Published private(set) var camera: State = .notDetermined
    @Published private(set) var screenRecording: State = .notDetermined

    /// Set when a capture attempt actually fails, which is more trustworthy
    /// than the preflight check (that can misreport inside a sandbox).
    @Published var screenRecordingFailed = false

    /// Enough to use the app at all.
    ///
    /// Only the camera is essential — without it there are no gestures and
    /// nothing works. Screen Recording is needed solely to share a window or
    /// take a screenshot, and requiring it hid the whole interface from a
    /// machine that only wanted to pass links. That matters most on a Mac
    /// that is not yours to configure: privacy permissions are tied to an
    /// app's signature, so every rebuild of an ad-hoc signed build asks
    /// again, and there is no reason to ask for something the user is not
    /// going to use.
    var essentialGranted: Bool {
        camera == .granted
    }

    /// Everything, including the optional capture permission.
    var allGranted: Bool {
        essentialGranted && screenRecording == .granted && !screenRecordingFailed
    }

    /// True when links work but sharing a window does not.
    var canShareWindows: Bool {
        screenRecording == .granted && !screenRecordingFailed
    }

    init() { refresh() }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = .granted
        case .notDetermined: camera = .notDetermined
        default: camera = .denied
        }
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
        if screenRecording == .granted { screenRecordingFailed = false }
    }

    func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Raises the system prompt (first time) and opens the right settings pane.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openSettings(pane: "Privacy_ScreenCapture")
    }

    func openCameraSettings() { openSettings(pane: "Privacy_Camera") }

    private func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording only takes effect after a restart, so offer to do it
    /// rather than leaving the user to work that out.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
