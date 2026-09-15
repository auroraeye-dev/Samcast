import SwiftUI
import AVFoundation
import SamcastPlatform

/// Hosts the H.264 display layer inside SwiftUI.
///
/// A plain `Image` cannot show this stream: the frames are never turned into
/// images at all. They go from the network straight into
/// `AVSampleBufferDisplayLayer`, which decodes and draws them in hardware —
/// the whole point being that nothing lands on the main thread at draw time.
struct VideoLayerView: UIViewRepresentable {
    let stream: H264StreamView

    func makeUIView(context: Context) -> LayerHostingView {
        let view = LayerHostingView()
        view.backgroundColor = .black
        view.layer.addSublayer(stream.layer)
        return view
    }

    func updateUIView(_ view: LayerHostingView, context: Context) {
        // Nothing to push: frames arrive from the network, not from state.
    }

    /// The layer has to be resized by hand — a sublayer does not participate
    /// in Auto Layout, so without this it keeps whatever size it was created
    /// with and the picture sits in a corner.
    final class LayerHostingView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // no animation on rotate
            layer.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}


/// The status line and Stop button, shared by the H.264 and JPEG renderers so
/// they cannot drift apart.
struct StreamHeader: View {
    @ObservedObject var model: ReceiverModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusLine)
                    .font(.caption).foregroundStyle(.gray).lineLimit(1)
                if !model.streamStats.isEmpty {
                    Text(model.streamStats)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.gray.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Stop") { model.stopWatching() }
                .font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
