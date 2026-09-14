import SwiftUI
import QuackCastCore

struct ContentView: View {
    @EnvironmentObject var model: ReceiverModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = model.receivedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                idleView
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 24) {
            Text(glyph)
                .font(.system(size: 90))
                .animation(.spring(duration: 0.25), value: model.currentGesture)

            Text(model.statusLine)
                .font(.title3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(model.handDetected ? "✋ hand detected" : "no hand")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(model.handDetected ? Color.green : Color.gray)

            Text("This device: \(model.identity.name)")
                .font(.caption)
                .foregroundStyle(.gray)

            Button(action: { model.grabFromClipboard() }) {
                Label("Send copied link", systemImage: "link")
                    .font(.subheadline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color.gray.opacity(0.35)))
                    .foregroundStyle(.white)
            }

            if model.availableSource != nil {
                Button(action: { model.tapToReceive() }) {
                    Label("Receive screen", systemImage: "tv")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Capsule().fill(Color.blue))
                        .foregroundStyle(.white)
                }
            }

            if !model.peers.isEmpty {
                Text(model.peers.map(\.displayName).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
        }
        .padding()
    }

    private var glyph: String {
        switch model.currentGesture {
        case .openHand: return "🖐️"
        case .closedHand: return "✊"
        case .peace: return "✌️"
        case .none: return "🦆"
        }
    }
}
