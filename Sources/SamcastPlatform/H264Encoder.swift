#if os(macOS)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware H.264 encoding for shared windows.
///
/// JPEG re-encodes the whole picture every frame. For a window where three
/// words changed that is almost entirely waste, and it forced a choice
/// between a sharp picture and a smooth one — at its floor it still needed
/// ~780 KB/s and looked poor. H.264 sends the difference instead, so the same
/// window costs a fraction of that and can be sent at full resolution.
///
/// Configured for screen sharing rather than for video: no frame reordering
/// (B-frames would add latency for no benefit here) and real-time mode, which
/// tells VideoToolbox to favour keeping up over squeezing out the last byte.
public final class H264Encoder {

    /// An encoded frame, ready for `VideoPacket`.
    public struct Frame {
        public let data: Data
        public let isKeyframe: Bool
        public let sps: Data?
        public let pps: Data?
    }

    public var onEncodedFrame: ((Frame) -> Void)?
    public var onError: ((String) -> Void)?

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameIndex: Int64 = 0
    private let queue = DispatchQueue(label: "com.samcast.h264")

    /// Target bitrate. 2.5 Mbit/s is generous for a window: JPEG needed more
    /// than twice this to look worse.
    public var bitsPerSecond: Int = 2_500_000

    public init() {}

    deinit { invalidate() }

    /// A receiver that joins mid-stream has never seen a keyframe, so the
    /// next frame must be one or their screen stays black.
    public func requestKeyframe() {
        queue.async { [weak self] in self?.forceKeyframeOnNextFrame = true }
    }
    private var forceKeyframeOnNextFrame = true

    public func invalidate() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            width = 0
            height = 0
            forceKeyframeOnNextFrame = true
        }
    }

    /// Encode one captured frame. Safe to call from the capture callback.
    public func encode(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let h = Int32(CVPixelBufferGetHeight(pixelBuffer))

            // A window being resized changes the frame size, and a session is
            // fixed to one. Rebuild rather than silently emitting garbage.
            if self.session == nil || w != self.width || h != self.height {
                self.makeSession(width: w, height: h)
            }
            guard let session = self.session else { return }

            var properties: CFDictionary?
            if self.forceKeyframeOnNextFrame {
                self.forceKeyframeOnNextFrame = false
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            }

            self.frameIndex += 1
            let presentationTime = CMTime(value: self.frameIndex, timescale: 600)

            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: properties,
                infoFlagsOut: nil
            ) { [weak self] status, _, sampleBuffer in
                guard let self, status == noErr, let sampleBuffer else { return }
                self.handle(sampleBuffer)
            }
        }
    }

    // MARK: - Session

    private func makeSession(width w: Int32, height h: Int32) {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: w, height: h,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            onError?("H.264 encoder unavailable (status \(status)) — falling back to JPEG")
            return
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(created, key: key, value: value)
        }
        // Keep up rather than squeeze: this is a live screen, not a file.
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // B-frames buy compression at the cost of latency. Wrong trade here.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
        // A keyframe every few seconds bounds how long a receiver that joins
        // late waits, without spending much — most frames stay differences.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 120 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 5 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        width = w
        height = h
        frameIndex = 0
        forceKeyframeOnNextFrame = true
        onError?("H.264 encoder ready at \(w)×\(h)")
    }

    // MARK: - Output

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // A frame is a keyframe unless it is explicitly marked "not sync".
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }

        var sps: Data?
        var pps: Data?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            sps = parameterSet(at: 0, in: format)
            pps = parameterSet(at: 1, in: format)
        }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }

        let data = Data(bytes: pointer, count: totalLength)
        onEncodedFrame?(Frame(data: data, isKeyframe: isKeyframe, sps: sps, pps: pps))
    }

    private func parameterSet(at index: Int, in format: CMFormatDescription) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        guard status == noErr, let pointer, size > 0 else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
#endif
