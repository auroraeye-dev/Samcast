import Foundation
import AppKit
import SamcastCore
import SamcastPlatform

/// A second Samcast receiver you can run on the *same* Mac, so casting can be
/// developed and demoed without owning a second machine. It joins the same
/// Multipeer service as the app, auto-accepts a cast, shows the incoming window
/// live, and reports the frame rate and bandwidth actually achieved.
///
/// Run with:  swift run CastPeer
@MainActor
final class ViewerReceiver: NSObject, PeerTransportDelegate, NSApplicationDelegate {
    private let transport = MultipeerTransport(displayName: "Samcast Viewer", kind: .mac)
    private var window: NSWindow!
    private var imageView: NSImageView!
    private var statusLabel: NSTextField!

    private var frames = 0
    private var bytes = 0
    private var windowStart = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        transport.delegate = self
        transport.start()
        setStatus("Waiting for a cast — make a ✊ fist in Samcast")
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Samcast Viewer (test receiver)"
        window.center()

        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(imageView)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        // Also log, so connection state is visible without reading the window.
        print(text)
    }

    // MARK: PeerTransportDelegate

    nonisolated func transport(_ transport: PeerTransport, didUpdate peers: [Peer]) {
        Task { @MainActor in
            setStatus(peers.isEmpty
                      ? "No peers — waiting for Samcast…"
                      : "Connected: \(peers.map(\.displayName).joined(separator: ", "))")
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer) {
        Task { @MainActor in
            switch message {
            case .sourceAvailable:
                setStatus("\(peer.displayName) is sharing — requesting…")
                transport.send(.requestCast, to: peer)
            case .handoff:
                // A page was handed over: open it natively, nothing streams.
                if let payload, let url = URL(string: payload) {
                    NSWorkspace.shared.open(url)
                    setStatus("Opened handed-over page from \(peer.displayName): \(url.absoluteString)")
                }
            case .endCast, .sourceWithdrawn:
                setStatus("Cast ended by \(peer.displayName)")
            case .requestCast:
                break
            }
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceiveFrame frame: Any, from peer: Peer) {
        guard let data = frame as? Data else { return }
        Task { @MainActor in
            if let image = NSImage(data: data) { imageView.image = image }

            frames += 1
            bytes += data.count
            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= 1.0 {
                let kbps = Double(bytes) / 1024.0 / elapsed
                let fps = Double(frames) / elapsed
                let avg = Double(bytes) / 1024.0 / Double(max(frames, 1))
                setStatus(String(format: "%@  •  %.1f fps  •  %.0f KB/s  •  avg frame %.0f KB",
                                 peer.displayName, fps, kbps, avg))
                frames = 0; bytes = 0; windowStart = Date()
            }
        }
    }
}

// Top-level code is nonisolated, so hop to the main actor to build the
// main-actor-isolated delegate before handing it to AppKit.
// Unbuffered stdout so status is visible immediately when piped to a file.
setvbuf(stdout, nil, _IONBF, 0)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ViewerReceiver()
    // AppKit holds the delegate weakly; keep it alive for the process lifetime.
    objc_setAssociatedObject(app, "samcast.viewer", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.delegate = delegate
    app.run()
}
