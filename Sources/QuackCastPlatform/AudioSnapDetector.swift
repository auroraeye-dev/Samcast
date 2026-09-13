import Foundation
import AVFoundation

/// Detects a finger snap from the microphone. A snap is a sharp, short
/// broadband transient, so we look for a sudden spike in the audio peak level
/// that far exceeds the recent background level (an onset detector). This is
/// independent of hand shape, which is why it avoids the fist/snap confusion
/// that pure vision suffers from.
///
/// It is deliberately simple and will also react to other sharp transients
/// (claps, knocks). Tune `triggerFactor` / `minPeak` to taste.
public final class AudioSnapDetector {
    /// Called on the main queue when a snap-like transient is detected.
    public var onSnap: (() -> Void)?

    /// Peak must exceed background * this factor to count as an onset.
    public var triggerFactor: Float = 6.0
    /// Absolute floor so quiet-room noise can't trigger via the ratio alone.
    public var minPeak: Float = 0.10
    /// Minimum time between reported snaps.
    public var cooldown: TimeInterval = 0.4

    private let engine = AVAudioEngine()
    private var background: Float = 0.02
    private var lastSnap = Date.distantPast
    private var running = false

    public init() {}

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var peak: Float = 0
        for i in 0..<count {
            let v = abs(channel[i])
            if v > peak { peak = v }
        }

        let now = Date()
        let isOnset = peak > minPeak
            && peak > background * triggerFactor
            && now.timeIntervalSince(lastSnap) > cooldown
        if isOnset {
            lastSnap = now
            let handler = onSnap
            DispatchQueue.main.async { handler?() }
        }

        // Slowly track the background level from every frame.
        background = background * 0.95 + peak * 0.05
    }
}
