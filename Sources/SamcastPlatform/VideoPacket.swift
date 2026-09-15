import Foundation

/// How an encoded frame is wrapped before it goes on the wire.
///
/// Two codecs have to coexist. H.264 is what makes sharing a window actually
/// good — it sends only what changed, where JPEG re-sends the entire picture
/// every frame — but it cannot start from nothing: a decoder is useless until
/// it has the sequence and picture parameter sets, and a receiver that joins
/// mid-stream has never seen them. So every keyframe carries them again.
/// JPEG stays as the fallback for when an encoder cannot be created at all.
///
/// Layout, all integers big-endian:
///
///     byte 0      codec        0x01 JPEG · 0x02 H.264
///     byte 1      flags        bit0 keyframe · bit1 parameter sets follow
///     [if bit1]   uint16 spsLength, sps bytes
///     [if bit1]   uint16 ppsLength, pps bytes
///     remainder   payload      JPEG bytes, or length-prefixed H.264 NALs
///
public enum VideoPacket {

    public enum Codec: UInt8 {
        case jpeg = 0x01
        case h264 = 0x02
    }

    public struct Decoded {
        public let codec: Codec
        public let isKeyframe: Bool
        public let sps: Data?
        public let pps: Data?
        public let payload: Data
    }

    public static func jpeg(_ data: Data) -> Data {
        var out = Data(capacity: data.count + 2)
        out.append(Codec.jpeg.rawValue)
        out.append(0)
        out.append(data)
        return out
    }

    public static func h264(_ data: Data, isKeyframe: Bool, sps: Data?, pps: Data?) -> Data {
        var out = Data(capacity: data.count + 16)
        out.append(Codec.h264.rawValue)

        let carriesParameterSets = isKeyframe && sps != nil && pps != nil
        var flags: UInt8 = 0
        if isKeyframe { flags |= 0b01 }
        if carriesParameterSets { flags |= 0b10 }
        out.append(flags)

        if carriesParameterSets, let sps, let pps {
            out.append(UInt8(sps.count >> 8)); out.append(UInt8(sps.count & 0xFF))
            out.append(sps)
            out.append(UInt8(pps.count >> 8)); out.append(UInt8(pps.count & 0xFF))
            out.append(pps)
        }
        out.append(data)
        return out
    }

    /// Returns nil for anything malformed. Frames arrive from the network, so
    /// every length read below is bounds-checked before it is used — a
    /// truncated packet must produce nothing, never an out-of-range read.
    public static func decode(_ data: Data) -> Decoded? {
        guard data.count >= 2, let codec = Codec(rawValue: data[data.startIndex]) else { return nil }
        let flags = data[data.index(data.startIndex, offsetBy: 1)]
        var cursor = data.index(data.startIndex, offsetBy: 2)

        func readBlock() -> Data? {
            guard data.distance(from: cursor, to: data.endIndex) >= 2 else { return nil }
            let high = Int(data[cursor])
            let low = Int(data[data.index(cursor, offsetBy: 1)])
            let length = (high << 8) | low
            cursor = data.index(cursor, offsetBy: 2)
            guard length > 0, data.distance(from: cursor, to: data.endIndex) >= length else { return nil }
            let block = data[cursor ..< data.index(cursor, offsetBy: length)]
            cursor = data.index(cursor, offsetBy: length)
            return Data(block)
        }

        var sps: Data?
        var pps: Data?
        if flags & 0b10 != 0 {
            guard let s = readBlock(), let p = readBlock() else { return nil }
            sps = s
            pps = p
        }

        return Decoded(codec: codec,
                       isKeyframe: flags & 0b01 != 0,
                       sps: sps,
                       pps: pps,
                       payload: Data(data[cursor...]))
    }
}
