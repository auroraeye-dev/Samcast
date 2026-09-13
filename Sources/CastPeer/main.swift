import Foundation
import QuackCastCore
import QuackCastPlatform

/// A headless second peer for testing the cast pipeline without a second
/// device. It joins the same Multipeer service as the app, auto-requests a
/// cast when a source announces itself, and reports the frame rate and
/// bandwidth actually achieved — which is the only way to know whether the
/// stream is genuinely usable.
///
/// Run with:  swift run CastPeer
final class TestReceiver: PeerTransportDelegate {
    private let transport = MultipeerTransport(displayName: "QuackCast Test Receiver", kind: .mac)
    private var frames = 0
    private var bytes = 0
    private var windowStart = Date()

    func start() {
        transport.delegate = self
        transport.start()
        print("🦆 Test receiver running as “QuackCast Test Receiver”.")
        print("   Browsing for QuackCast peers — make a ✊ fist on the Mac app to arm sharing.\n")
    }

    func transport(_ transport: PeerTransport, didUpdate peers: [Peer]) {
        if peers.isEmpty {
            print("… no peers connected")
        } else {
            print("✅ connected peers: \(peers.map(\.displayName).joined(separator: ", "))")
        }
    }

    func transport(_ transport: PeerTransport, didReceive message: ControlMessage, from peer: Peer) {
        print("📨 \(message.rawValue) ← \(peer.displayName)")
        if message == .sourceAvailable {
            print("➡️  requesting cast from \(peer.displayName)")
            transport.send(.requestCast, to: peer)
        }
    }

    func transport(_ transport: PeerTransport, didReceiveFrame frame: Any, from peer: Peer) {
        guard let data = frame as? Data else { return }
        frames += 1
        bytes += data.count

        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            let kb = Double(bytes) / 1024.0
            let fps = Double(frames) / elapsed
            let avg = kb / Double(max(frames, 1))
            print(String(format: "🎞  %.1f fps   %.0f KB/s   avg frame %.0f KB", fps, kb / elapsed, avg))
            frames = 0
            bytes = 0
            windowStart = now
        }
    }
}

// Unbuffered stdout so progress is visible when output is piped to a file.
setvbuf(stdout, nil, _IONBF, 0)

let receiver = TestReceiver()
receiver.start()
RunLoop.main.run()
