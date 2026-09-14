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
        .overlay(GlowBurst(trigger: model.glowTrigger, direction: model.glowDirection)
            .ignoresSafeArea())
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
            Text("fingers: \(model.fingerReadout)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)

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

            if let source = model.availableSource {
                if model.sourceIsKnown {
                    // Already approved: your open hand is the way to take it.
                    // A small tap fallback stays available in case the camera
                    // can't see you, but it is no longer the main path.
                    Button("or tap to take it") { model.tapToReceive() }
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    // First time from this device — approve it once.
                    Button(action: { model.tapToReceive() }) {
                        Label("Allow “\(source.displayName)”", systemImage: "checkmark.shield")
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(Capsule().fill(Color.blue))
                            .foregroundStyle(.white)
                    }
                    Text("Approved once, then your open hand is enough")
                        .font(.caption2)
                        .foregroundStyle(.gray)
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
