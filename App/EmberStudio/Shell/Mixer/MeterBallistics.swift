import DAWModel
import Foundation

/// UI-031: what a channel meter shows, from the engine's linear readings (post-fader, MIX-005):
/// instant attack and a falling peak bar, a peak-hold line, and a clip indicator that stays until
/// cleared. Pure state, advanced once per display frame on the main thread.
struct MeterBallistics: Equatable, Sendable {
    /// The bottom and top of the meter's scale.
    static let floorDB = -60.0
    static let ceilingDB = 6.0
    /// The peak bar falls at this rate after its attack.
    static let releaseDBPerSecond = 24.0
    /// How long the hold line stays before it falls.
    static let holdSeconds = 1.5
    /// A reading over this is a clip: beyond full scale (the engine's "overs", MIX-009).
    static let clipLevel: Float = 1

    private(set) var peakDB = floorDB
    private(set) var rmsDB = floorDB
    private(set) var holdDB = floorDB
    private(set) var clipped = false
    private var holdUntil: TimeInterval = 0
    private var lastFrame: TimeInterval?

    /// One display frame's reading at `now`; nil (no meter for this channel yet) reads as silence.
    mutating func advance(_ reading: MeterReading?, now: TimeInterval) {
        let dt = max(0, now - (lastFrame ?? now))
        lastFrame = now
        let peak = Self.decibels(reading?.peak ?? 0)
        peakDB = max(peak, peakDB - Self.releaseDBPerSecond * dt)
        rmsDB = Self.decibels(reading?.rms ?? 0)
        if peak >= holdDB {
            holdDB = peak
            holdUntil = now + Self.holdSeconds
        } else if now >= holdUntil {
            holdDB = max(peak, holdDB - Self.releaseDBPerSecond * dt)
        }
        if (reading?.peak ?? 0) > Self.clipLevel { clipped = true }
    }

    mutating func clearClip() { clipped = false }

    /// Linear amplitude in dB, no lower than the scale's floor; a bad value reads as silence.
    static func decibels(_ linear: Float) -> Double {
        guard linear.isFinite, linear > 0 else { return floorDB }
        return max(20 * log10(Double(linear)), floorDB)
    }

    /// Where `db` falls on the scale: 0 at the floor, 1 at the ceiling.
    static func position(db: Double) -> Double {
        min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }
}
