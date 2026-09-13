import SwiftUI
import QuackCastCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(model.statusLine)
                .font(.headline)
            Spacer()
            // Live view of what the camera believes it sees, so snap gating
            // isn't a black box.
            Text(model.handDetected ? "✋ hand detected" : "no hand")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(model.handDetected ? Color.green : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Text(gestureLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let image = model.receivedImage {
                // Showing a remote screen that was cast to us.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if !model.permissions.allGranted {
                // Guide setup instead of silently doing nothing.
                PermissionsView(permissions: model.permissions)
            } else {
                // No live camera preview — it feels awkward and isn't needed.
                // The camera still runs in the background for gesture detection.
                idleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(idleBackground)
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Text(bigGestureGlyph)
                .font(.system(size: 96))
                .animation(.spring(duration: 0.25), value: model.currentGesture)
            Text(stateHeadline)
                .font(.title2).bold()
                .foregroundStyle(.primary)
            VStack(spacing: 6) {
                gestureHint("✊", "Close your hand", "share this screen")
                gestureHint("🖐️", "Open your hand", "cast to a device in front of you")
                gestureHint("✌️", "Peace sign", "screenshot to your Pictures")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding()
    }

    private func gestureHint(_ glyph: String, _ action: String, _ result: String) -> some View {
        HStack(spacing: 8) {
            Text(glyph).font(.title3)
            Text(action).bold().foregroundStyle(.primary)
            Text("→ \(result)")
        }
    }

    private var idleBackground: some View {
        LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                Color(nsColor: .underPageBackgroundColor)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var bigGestureGlyph: String {
        switch model.currentGesture {
        case .openHand: return "🖐️"
        case .closedHand: return "✊"
        case .peace: return "✌️"
        case .none: return "🦆"
        }
    }

    private var stateHeadline: String {
        switch model.state {
        case .idle: return "Ready"
        case .armedSource: return "Screen armed"
        case .casting(let p): return "Casting to \(p.displayName)"
        case .receiving(let p): return "Receiving from \(p.displayName)"
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label("\(model.peers.count) nearby", systemImage: "dot.radiowaves.left.and.right")
            Text("fingers: \(model.fingerReadout)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(model.peers) { peer in
                Text(peer.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
            if let shot = model.lastScreenshot {
                Label(shot.lastPathComponent, systemImage: "camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var gestureLabel: String {
        switch model.currentGesture {
        case .none: return "—"
        case .openHand: return "🖐️ open"
        case .closedHand: return "✊ closed"
        case .peace: return "✌️ peace"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle: return .gray
        case .armedSource: return .orange
        case .casting: return .green
        case .receiving: return .blue
        }
    }
}
