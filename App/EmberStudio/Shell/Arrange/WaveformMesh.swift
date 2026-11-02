import CoreGraphics
import DAWModel
import Foundation
import simd

/// One column of a waveform: the rectangle `x0, top, x1, bottom` in view points (y down) and its
/// color. The Metal vertex shader expands each bar (one instance) into a quad, so the CPU writes 32
/// bytes per column and channel. The layout matches the shader's `WaveformBar`.
struct WaveformBar: Equatable {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>

    var x0: Float { rect.x }
    var top: Float { rect.y }
    var x1: Float { rect.z }
    var bottom: Float { rect.w }
}

/// UI-011: turns peak mipmaps into triangles for the waveform layer: one column per pixel, each a
/// min..max bar per channel, scaled by the clip's gain and fades.
enum WaveformMesh {
    /// The clip title band at the top of a clip, left clear of waveform.
    static let headerHeight = 14.0

    /// UI-011: the mipmap level for a zoom: the coarsest whose blocks still fit in one pixel, so a
    /// column aggregates as few blocks as possible without missing peaks. Zoomed in past the finest
    /// level (fewer than 256 samples per pixel), level 0 is drawn block by block.
    static func level(samplesPerPixel: Double) -> Int {
        var level = 0
        for (i, size) in PeakLevel.blockSizes.enumerated() where Double(size) <= samplesPerPixel { level = i }
        return level
    }

    /// The samples one pixel covers around `tick` (tempo-dependent).
    static func samplesPerPixel(at tick: Tick, geometry g: TimelineGeometry, tempoMap: TempoMap) -> Double {
        let ticks = max(Int64((1_000 / g.pixelsPerTick).rounded()), 1)
        let samples = tempoMap.tickToSample(Tick(tick.raw + ticks)) - tempoMap.tickToSample(tick)
        return Double(samples) / (Double(ticks) * g.pixelsPerTick)
    }

    /// Appends the bars of `clip`'s waveform, drawn in `rect` (view points) and clipped to
    /// `0..<width`. Columns past the end of the audio are left empty.
    static func append(
        clip: AudioClip, rect: CGRect, peaks: PeakLevel, geometry g: TimelineGeometry, tempoMap map: TempoMap,
        color: SIMD4<Float>, into bars: inout [WaveformBar]
    ) {
        let channels = max(peaks.channels, 1)
        let laneTop = rect.minY + headerHeight
        let laneHeight = (rect.maxY - 1 - laneTop) / Double(channels)
        guard laneHeight >= 2, peaks.blockCount > 0 else { return }
        let firstX = max(Int(rect.minX.rounded(.down)), 0)
        let lastX = min(Int(rect.maxX.rounded(.up)), Int(g.size.width.rounded(.up)))
        guard firstX < lastX else { return }

        let clipStart = clip.start.raw
        let clipEnd = clipStart + clip.length.raw
        let clipStartSample = map.tickToSample(clip.start)
        let blockSize = Int64(peaks.blockSize)
        let blockCount = Int64(peaks.blockCount)
        let frames = peaks.frames
        let gain = Double(clip.gain)
        let fadeIn = Double(clip.fadeIn.raw), fadeOut = Double(clip.fadeOut.raw), length = Double(clip.length.raw)
        let ticksPerPixel = 1 / g.pixelsPerTick
        let half = laneHeight * 0.48

        bars.reserveCapacity(bars.count + (lastX - firstX) * channels)
        peaks.minMax.withUnsafeBufferPointer { minMax in
            // The source sample at the left edge of column x.
            var tick = (Double(firstX) + g.scrollX) * ticksPerPixel
            var s0 = clip.sourceOffsetSamples + map.tickToSample(Tick(min(max(Int64(tick.rounded()), clipStart), clipEnd))) - clipStartSample
            // Bounded by the clip's visible width in pixels.
            for x in firstX..<lastX {
                let midTick = tick + ticksPerPixel / 2 - Double(clipStart)
                tick += ticksPerPixel
                let s1 = clip.sourceOffsetSamples
                    + map.tickToSample(Tick(min(max(Int64(tick.rounded()), clipStart), clipEnd))) - clipStartSample
                defer { s0 = s1 }
                guard s0 < frames, s1 > 0 else { continue }
                let b0 = max(s0, 0) / blockSize
                let b1 = min(max((s1 + blockSize - 1) / blockSize, b0 + 1), blockCount)
                guard b0 < b1 else { continue }
                var envelope = 1.0
                if fadeIn > 0 { envelope = min(envelope, midTick / fadeIn) }
                if fadeOut > 0 { envelope = min(envelope, (length - midTick) / fadeOut) }
                let scale = gain * min(max(envelope, 0), 1)
                for c in 0..<channels {
                    let base = Int64(min(c, peaks.channels - 1)) * blockCount
                    var lo = minMax[Int((base + b0) * 2)], hi = minMax[Int((base + b0) * 2 + 1)]
                    var b = b0 + 1
                    while b < b1 {
                        lo = min(lo, minMax[Int((base + b) * 2)])
                        hi = max(hi, minMax[Int((base + b) * 2 + 1)])
                        b += 1
                    }
                    let center = laneTop + laneHeight * (Double(c) + 0.5)
                    var top = center - min(max(Double(hi) * scale, -1), 1) * half
                    var bottom = center - min(max(Double(lo) * scale, -1), 1) * half
                    if bottom - top < 1 {  // silence still shows a hairline
                        top = center - 0.5
                        bottom = center + 0.5
                    }
                    bars.append(WaveformBar(rect: SIMD4(Float(x), Float(top), Float(x + 1), Float(bottom)), color: color))
                }
            }
        }
    }
}
