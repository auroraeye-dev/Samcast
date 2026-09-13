import Foundation
import AVFoundation

/// Detects a finger snap from the microphone.
///
/// Detecting "a loud sharp sound" is easy but useless — a table tap, a knock
/// and a snap are all sharp. What separates them is **tone**:
///
/// * a finger snap is a *bright* click: most of its energy sits well above
///   ~1 kHz and it decays almost instantly;
/// * a table tap / knock is a *dull* thud: most of its energy is low frequency
///   because the surface resonates.
///
/// So on every sharp onset we split the signal into low and high bands with a
/// one-pole filter and require the high band to dominate. (A one-pole split is
/// used instead of an FFT because it is cheap, allocation-free and plenty to
/// separate "bright click" from "low thud".)
public final class AudioSnapDetector {
    /// Called on the main queue when a snap is accepted.
    public var onSnap: (() -> Void)?

    /// Diagnostics for *every* sharp sound heard: (accepted, tone ratio).
    /// A higher tone ratio means a brighter sound. Surfaced in the UI so the
    /// threshold can be tuned against real snaps rather than guessed.
    public var onSound: ((Bool, Float) -> Void)?

    /// Peak must exceed background * this factor to count as an onset.
    public var triggerFactor: Float = 6.0
    /// Absolute floor so quiet-room noise can't trigger via the ratio alone.
    public var minPeak: Float = 0.08
    /// Minimum time between reported snaps.
    public var cooldown: TimeInterval = 0.4
    /// High-band / low-band energy ratio required to call a sound a snap.
    /// Raise → stricter (rejects more taps). Lower → laxer.
    public var minToneRatio: Float = 1.0
    /// Split point between "low thud" and "bright click" energy, in Hz.
    public var crossoverHz: Float = 1200

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
        let sampleRate = Float(buffer.format.sampleRate)
        guard sampleRate > 0 else { return }

        // Peak for onset detection, plus a low/high band split for tone.
        // One-pole low-pass coefficient for the chosen crossover frequency.
        let dt: Float = 1.0 / sampleRate
        let rc: Float = 1.0 / (2.0 * .pi * crossoverHz)
        let alpha: Float = dt / (rc + dt)

        var peak: Float = 0
        var lowEnergy: Float = 0
        var highEnergy: Float = 0
        var lowPass: Float = channel[0]

        for i in 0..<count {
            let x = channel[i]
            let a = abs(x)
            if a > peak { peak = a }
            lowPass += alpha * (x - lowPass)   // low band
            let high = x - lowPass             // whatever is left is high band
            lowEnergy += lowPass * lowPass
            highEnergy += high * high
        }

        let toneRatio: Float = lowEnergy > 1e-9 ? highEnergy / lowEnergy : (highEnergy > 0 ? 99 : 0)

        let now = Date()
        let isSharp = peak > minPeak
            && peak > background * triggerFactor
            && now.timeIntervalSince(lastSnap) > cooldown

        if isSharp {
            let isBright = toneRatio >= minToneRatio
            if isBright {
                lastSnap = now
                let handler = onSnap
                DispatchQueue.main.async { handler?() }
            }
            let diag = onSound
            DispatchQueue.main.async { diag?(isBright, toneRatio) }
        }

        // Slowly track the background level from every frame.
        background = background * 0.95 + peak * 0.05
    }
}
