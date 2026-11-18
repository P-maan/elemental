import Foundation

/// The scene that is ALREADY on the wall, answering something - a beat, a drop, a
/// message - without being swapped for weather that is not happening.
///
/// Asked for 25 Oct 2026: "if the sun is out make the sun ripples react to that",
/// and "whatever Elemental is there, keep that and use that to message and signal".
/// A preview REPLACES the sky; a pulse only modulates it. One scalar, 0..1, reaches
/// the shader as `Uniforms.pulse`: the solar ripple and glow surge with it when the
/// sun is visible, and every scene gets a soft travelling swell of light, so a clear
/// day, an overcast and a night all signal in their own picture.
///
/// Two sources, and the louder wins:
///  - `feed(level)` - a live level (music). HELD with a fast decay, so a feeder that
///    stops - Mac asleep, app quit - fades to nothing instead of freezing mid-beat.
///  - `play(pattern)` - a short scripted shape for a message.
final class Pulse: @unchecked Sendable {
    static let shared = Pulse()
    private let lock = NSLock()
    private var held: Double = 0
    private var heldAt: CFAbsoluteTime = 0
    private var heldMid: Double = 0
    private var heldHigh: Double = 0
    private var beatAt: CFAbsoluteTime = -100
    private let hold: Double = 0.18
    private var pattern: Pattern?
    private var patternT0: CFAbsoluteTime = 0
    private var lastSignal: CFAbsoluteTime = 0

    enum Pattern: String, CaseIterable {
        case notice, urgent, celebrate, alert, drop
        var seconds: Double {
            switch self {
            case .notice: 1.6
            case .urgent: 4.2
            case .celebrate: 9
            case .alert: 20
            case .drop: 6
            }
        }
        /// The shape over time, 0..1.
        func value(_ t: Double) -> Double {
            switch self {
            case .notice:      // one soft swell
                return sin(.pi * min(1, t / seconds))
            case .urgent:      // three hard beats, twice
                let k = t.truncatingRemainder(dividingBy: 0.42)
                let beat = Int(t / 0.42)
                return (beat % 7 < 3 && k < 0.2) ? 1 : (beat % 7 < 3 ? max(0, 1 - (k - 0.2) / 0.12) : 0)
            case .celebrate:   // rolling, bouncy, fading out
                let env = 1 - max(0, (t - seconds + 2) / 2)
                return env * pow(0.5 + 0.5 * sin(t * 2 * .pi * 2.1), 1.6)
            case .alert:       // slow breathing
                return 0.55 * (0.5 - 0.5 * cos(t * 2 * .pi * 0.8))
            case .drop:        // the hit, then four ringing beats that settle
                let hit = exp(-t * 1.1)
                return hit * (0.55 + 0.45 * pow(0.5 + 0.5 * cos(t * 2 * .pi * 2), 2))
            }
        }
    }

    /// A live level from a feeder, 0..1. Decays with a ~0.18 s time constant.
    func feed(_ level: Double) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        held = max(0, min(1, level)); heldAt = now; lastSignal = now
        // A bare level (the endpoint) carries no bands of its own; lend the
        // others a share of it so every scene still answers.
        heldMid = held * 0.6; heldHigh = held * 0.4
        for k in 0..<Self.bandCount {
            heldSpectrum[k] = Float(held) * (1 - 0.6 * Float(k) / Float(Self.bandCount))
        }
    }

    /// Music, split: bass (`level`), mids, highs, and whether this buffer is a
    /// beat. Each kind of weather answers a different part of it — see the
    /// music section of the cell pass in Scene.metal.
    func feedBands(bass: Double, mid: Double, high: Double, beat: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        held = max(0, min(1, bass)); heldMid = max(0, min(1, mid)); heldHigh = max(0, min(1, high))
        heldAt = now; lastSignal = now
        if beat { beatAt = now }
    }

    // ---- the full spectrum, 24 log-spaced bands, 40 Hz to 16 kHz
    static let bandCount = 24
    private var heldSpectrum = [Float](repeating: 0, count: Pulse.bandCount)

    /// Music from the system-audio meter: every band, plus the three summaries
    /// and the beat derived from them.
    ///
    /// `after` holds the frame back so the picture lands with what is HEARD
    /// (AirPods play ~170 ms after the tap hears it). 16 Nov 2026: this used to
    /// be a `DispatchQueue.main.asyncAfter` per frame, throttled to thirty a
    /// second - up to 33 ms of waiting, the main queue's own lateness and the
    /// timer's leeway (a tenth of the delay, so ±16 ms of jitter on AirPods) on
    /// top of the intended delay. Now the audio thread hands every analysis
    /// frame straight here with the moment it is DUE, and whoever draws next
    /// takes the newest one whose moment has come. No queue hop, no throttle,
    /// no jitter beyond the frame itself.
    func feedSpectrum(_ s: [Float], bass: Double, mid: Double, high: Double, beat: Bool, after: Double = 0,
                      bands7: [Float] = []) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        lastSignal = now                       // the frame rate lifts at once, ahead of the sound
        pending.append(Timed(due: now + max(0, after), spec: s, bass: bass, mid: mid, high: high, beat: beat, b7: bands7))
        if pending.count > 512 { pending.removeFirst(pending.count - 512) }   // nobody is drawing
        drainLocked(now)
    }

    private struct Timed { let due: CFAbsoluteTime; let spec: [Float]; let bass, mid, high: Double; let beat: Bool; let b7: [Float] }
    /// The seven listening bands (passive, active, pan, width - 7 each), newest due frame.
    private var heldB7 = [Float](repeating: 0, count: 29)
    private var pending: [Timed] = []

    /// Apply every frame whose moment has come; the newest one wins, a beat
    /// among them is kept with its own time. Call with the lock held.
    private func drainLocked(_ now: CFAbsoluteTime) {
        var n = 0
        while n < pending.count, pending[n].due <= now { n += 1 }
        guard n > 0 else { return }
        for i in 0..<n where pending[i].beat { beatAt = pending[i].due }
        let f = pending[n - 1]
        for k in 0..<min(f.spec.count, Self.bandCount) { heldSpectrum[k] = max(0, min(1, f.spec[k])) }
        if f.b7.count == 29 { heldB7 = f.b7 }
        held = max(0, min(1, f.bass)); heldMid = max(0, min(1, f.mid)); heldHigh = max(0, min(1, f.high))
        heldAt = f.due; lastSignal = now
        pending.removeFirst(n)
    }

    /// The spectrum for THIS frame, faded with the same hold as the level and
    /// quieted under a message pattern. A bare level (the endpoint) lends every
    /// band a share of itself, low bands most, so the wall still answers.
    func spectrum() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        drainLocked(now)
        let fade = Float(exp(-(now - heldAt) / hold))
        let k: Float = (pattern != nil && pattern != .drop) ? 0.25 : 1
        return heldSpectrum.map { $0 * fade * k }
    }

    /// Everything the shader reads, for THIS frame. A message pattern replaces
    /// the bass while it plays and quiets the music's other bands, so it reads
    /// as itself.
    /// 28 floats: passive 0..6, active 7..13 (both faded like the spectrum when the
    /// sound stops), pan 14..20 and width 21..27 (as they are).
    func bands7() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        drainLocked(now)
        let fade = Float(exp(-(now - heldAt) / hold))
        let k: Float = (pattern != nil && pattern != .drop) ? 0.25 : 1
        var o = heldB7
        for i in 0..<14 { o[i] = max(0, min(1, o[i] * fade * k)) }
        o[28] = max(0, min(1, o[28] * fade))
        return o
    }

    func bands() -> (bass: Float, mid: Float, high: Float, beat: Float) {
        let bass = value()
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let fade = exp(-(now - heldAt) / hold)
        let message = pattern != nil && pattern != .drop
        let k = message ? 0.25 : 1.0
        let mid = Float(heldMid * fade * k), high = Float(heldHigh * fade * k)
        let beat = Float(exp(-(now - beatAt) / 0.11) * k)
        return (bass, max(0, min(1, mid)), max(0, min(1, high)), max(0, min(1, beat)))
    }

    func play(_ p: Pattern) {
        lock.lock(); defer { lock.unlock() }
        pattern = p; patternT0 = CFAbsoluteTimeGetCurrent(); lastSignal = patternT0 + p.seconds
    }

    /// The value for THIS frame.
    func value() -> Float {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        drainLocked(now)
        var v = held * exp(-(now - heldAt) / hold)
        if let p = pattern {
            let t = now - patternT0
            if t >= p.seconds { pattern = nil }
            // A MESSAGE wins over music while it plays: Zo's notice or alert
            // has to read as itself, not be drowned by whatever is playing.
            // A drop is the music's own, so it rides on top of it.
            else if p == .drop { v = max(v, p.value(t)) }
            else { v = p.value(t) }
        }
        return Float(max(0, min(1, v)))
    }

    /// A message pattern's value right now, music excluded; 0 when none plays.
    func message() -> Float {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let relayed = now - relayedAt < 0.5 ? relayed : 0
        guard let p = pattern, p != .drop else { return relayed }
        let t = now - patternT0
        return max(relayed, t < p.seconds ? Float(max(0, min(1, p.value(t)))) : 0)
    }

    /// The screen saver: a message's value relayed from the app (LiveRelay).
    private var relayed: Float = 0
    private var relayedAt: CFAbsoluteTime = 0
    func relayMessage(_ v: Float) {
        lock.lock(); relayed = v; relayedAt = CFAbsoluteTimeGetCurrent(); lock.unlock()
    }

    /// Something is pulsing, or did within the last two seconds - the frame rate
    /// should be up, because a beat drawn at six frames a second is not a beat.
    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - lastSignal < 2
    }
}
