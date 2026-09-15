import Foundation
import AVFoundation
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

/// Displays an incoming H.264 stream.
///
/// Uses `AVSampleBufferDisplayLayer`, which decodes and draws in hardware.
/// The JPEG path had to decode each frame into a `UIImage` and hand it to
/// SwiftUI, which put the work on the main thread at draw time and was what
/// froze the iPad. Here the frames never become images at all.
public final class H264StreamView {

    public let layer = AVSampleBufferDisplayLayer()

    /// Set when the stream cannot be shown, so the app can say why instead of
    /// presenting a black rectangle.
    public var onError: ((String) -> Void)?

    /// Fires the first time a frame is successfully enqueued, so the UI can
    /// stop saying "connecting".
    public var onFirstFrame: (() -> Void)?

    private var formatDescription: CMFormatDescription?
    private var hasShownFrame = false
    /// Frames before the first keyframe cannot be decoded — there is nothing
    /// to decode them against. Counted rather than logged each time.
    private var framesSkippedBeforeKeyframe = 0

    public init() {
        layer.videoGravity = .resizeAspect
        if #available(iOS 17.0, macOS 14.0, *) {
            // Without this the layer silently stops after an interruption
            // (a backgrounded app, a display change) and never resumes.
            layer.sampleBufferRenderer.requestMediaDataWhenReady(on: .main) {}
        }
    }

    /// Feed one decoded `VideoPacket`.
    public func enqueue(_ packet: VideoPacket.Decoded) {
        guard packet.codec == .h264 else { return }

        // Parameter sets describe the stream's shape. They ride with every
        // keyframe precisely so a receiver that joined late can start here.
        if let sps = packet.sps, let pps = packet.pps {
            rebuildFormat(sps: sps, pps: pps)
        }
        guard let formatDescription else {
            framesSkippedBeforeKeyframe += 1
            if framesSkippedBeforeKeyframe == 1 {
                onError?("Waiting for a keyframe…")
            }
            return
        }

        guard let sampleBuffer = makeSampleBuffer(from: packet.payload, format: formatDescription) else {
            return
        }

        // Display immediately: this is a live screen, so there is no clock to
        // schedule against and any delay is pure latency.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if layer.status == .failed {
            // A failed layer never recovers on its own.
            layer.flush()
            onError?("Display layer failed; resetting")
        }
        layer.enqueue(sampleBuffer)

        if !hasShownFrame {
            hasShownFrame = true
            onFirstFrame?()
        }
    }

    public func reset() {
        layer.flushAndRemoveImage()
        formatDescription = nil
        hasShownFrame = false
        framesSkippedBeforeKeyframe = 0
    }

    // MARK: - Internals

    private func rebuildFormat(sps: Data, pps: Data) {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        guard status == noErr, let format else {
            onError?("Could not read the stream's format (status \(status))")
            return
        }
        // A changed format means the shared window resized; start clean.
        if formatDescription != nil, !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: format) {
            layer.flush()
        }
        formatDescription = format
    }

    private func makeSampleBuffer(from payload: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        // The payload is copied because CMBlockBuffer keeps the pointer, and
        // `payload` is a temporary that will be gone by the time it is read.
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: payload.count, alignment: 1)
        payload.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: payload.count)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,   // frees `bytes` with the buffer
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            bytes.deallocate()
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }
}
