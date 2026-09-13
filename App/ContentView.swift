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
                // Showing a remote screen.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Otherwise show our own camera so the user can frame the gesture.
                CameraPreview(tracker: model.handTracker)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label("\(model.peers.count) nearby", systemImage: "dot.radiowaves.left.and.right")
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
        case .snap: return "🫰 snap"
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
