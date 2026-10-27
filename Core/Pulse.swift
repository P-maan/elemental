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
    }

    func play(_ p: Pattern) {
        lock.lock(); defer { lock.unlock() }
        pattern = p; patternT0 = CFAbsoluteTimeGetCurrent(); lastSignal = patternT0 + p.seconds
    }

    /// The value for THIS frame.
    func value() -> Float {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        var v = held * exp(-(now - heldAt) / 0.18)
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

    /// Something is pulsing, or did within the last two seconds - the frame rate
    /// should be up, because a beat drawn at six frames a second is not a beat.
    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - lastSignal < 2
    }
}
