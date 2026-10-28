@preconcurrency import AVFoundation
import DAWModel
import Foundation

/// A whole audio file in memory, deinterleaved float32 (`audio.analyze`, `audio.compare`).
public struct AudioData: Sendable {
    public var sampleRate: Double
    /// One array per channel, all the same length.
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int { channels.first?.count ?? 0 }

    /// Reads any file Core Audio can (WAV, CAF, AIFF, …), converted to float32.
    public init(contentsOf url: URL) throws(DAWError) {
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(clamping: file.length)
            let channelCount = Int(format.channelCount)
            var channels = [[Float]](repeating: [], count: channelCount)
            if frames > 0 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                    throw DAWError.engine(code: .outOfMemory, detail: "no buffer for \(frames) frames")
                }
                try file.read(into: buffer, frameCount: frames)
                let read = Int(buffer.frameLength)
                if let data = buffer.floatChannelData {
                    for c in 0..<channelCount {
                        channels[c] = Array(UnsafeBufferPointer(start: data[c], count: read))
                    }
                }
            }
            self.init(sampleRate: format.sampleRate, channels: channels)
        } catch let error as DAWError {
            throw error
        } catch {
            throw .engine(code: .io, detail: "cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Frames [start, end), clamped to the file.
    func slice(_ range: FrameRange?) throws(DAWError) -> AudioData {
        guard let range else { return self }
        guard range.start >= 0, range.end >= range.start else {
            throw .invalidArgument("range [\(range.start), \(range.end)) is not a frame range")
        }
        let start = Int(min(range.start, Int64(frameCount)))
        let end = Int(min(range.end, Int64(frameCount)))
        return AudioData(sampleRate: sampleRate, channels: channels.map { Array($0[start..<end]) })
    }

    /// The average of all channels.
    func mono() -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var out = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channels.count)
        for channel in channels {
            for i in 0..<out.count { out[i] += channel[i] * scale }
        }
        return out
    }
}
