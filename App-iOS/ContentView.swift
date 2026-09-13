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
        case .snap: return "🫰"
        case .none: return "🦆"
        }
    }
}
