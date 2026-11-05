import Foundation

/// Live values the wall can SHOW — system readings, and anything Zo sends.
///
/// Asked for 5 Nov 2026: "use the elements themselves to show information …
/// a page in settings to lay out what all the rays show, allowing users to
/// customise each ray … system information, critical information, literally
/// everything." The sun's rays (the moon's, at night) become gauges: each ray
/// is given a SOURCE in Settings, and reaches out as far as that source's
/// value, in that source's colour.
///
/// Sources, by id:
///   music.bass / music.mid / music.high   the music, if the meter is running
///   battery   charge, red when low through to green
///   cpu       load across all cores
///   memory    how much of RAM is in use
///   day       how far through the local day it is
///   zo        the next of Zo's signals not already on another ray
///   zo:NAME   one of Zo's signals by name
///   off       an empty ray
///
/// Zo sets a signal with a value, an optional colour and label, and clears it
/// when it is done (POST / DELETE /v1/signal). It stays until cleared, or until
/// its optional `seconds` run out.
final class Signals: @unchecked Sendable {
    static let shared = Signals()
    private let lock = NSLock()

    struct Signal {
        var value: Float
        var color: SIMD3<Float>?
        var label: String?
        var setAt: CFAbsoluteTime
        var expires: CFAbsoluteTime?
    }
    private var map: [String: Signal] = [:]

    static let maxRays = 12
    /// What a fresh "Signals" layout starts with, ray by ray.
    static let defaultLayout = ["battery", "cpu", "memory", "day", "zo", "zo",
                                "zo", "zo", "music.bass", "music.mid", "music.high", "off"]
    static let sources: [(id: String, title: String)] = [
        ("battery", "Battery"), ("cpu", "CPU load"), ("memory", "Memory in use"),
        ("day", "Time through the day"), ("zo", "Zo — next signal"),
        ("music.bass", "Music — bass"), ("music.mid", "Music — mids"), ("music.high", "Music — highs"),
        ("off", "Off"),
    ]

    func set(_ name: String, value: Float, color: SIMD3<Float>? = nil, label: String? = nil,
             seconds: Double? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        let setAt = map[name]?.setAt ?? now
        map[name] = Signal(value: max(0, min(1, value)), color: color, label: label, setAt: setAt,
                           expires: seconds.map { now + $0 })
    }

    func clear(_ name: String) {
        lock.lock(); map[name] = nil; lock.unlock()
    }

    /// Zo's live signals, oldest first, without the "zo." prefix.
    func zoSignals() -> [(name: String, signal: Signal)] {
        lock.lock(); defer { lock.unlock() }
        prune()
        return map.filter { $0.key.hasPrefix("zo.") }
            .sorted { $0.value.setAt < $1.value.setAt }
            .map { (String($0.key.dropFirst(3)), $0.value) }
    }

    private func prune() {
        let now = CFAbsoluteTimeGetCurrent()
        for (k, s) in map where (s.expires ?? .infinity) < now { map[k] = nil }
    }

    /// Each ray's value 0..1 and colour 0..1, for this frame.
    func resolve(_ layout: [String], music: (bass: Float, mid: Float, high: Float))
        -> [(value: Float, rgb: SIMD3<Float>)] {
        guard !layout.isEmpty else { return [] }
        lock.lock(); prune()
        let snapshot = map
        lock.unlock()
        let zo = snapshot.filter { $0.key.hasPrefix("zo.") }.sorted { $0.value.setAt < $1.value.setAt }
        let named = Set(layout.filter { $0.hasPrefix("zo:") }.map { "zo." + $0.dropFirst(3) })
        var free = zo.filter { !named.contains($0.key) }.makeIterator()

        let zoDefault = SIMD3<Float>(0.45, 0.85, 1.0)
        return layout.prefix(Self.maxRays).map { id -> (Float, SIMD3<Float>) in
            switch id {
            case "battery":
                let v = snapshot["sys.battery"]?.value ?? 0
                return (v, Self.hsv(0.33 * v, 0.85, 1))       // red when low, green when full
            case "cpu":    return (snapshot["sys.cpu"]?.value ?? 0, SIMD3(1.0, 0.68, 0.25))
            case "memory": return (snapshot["sys.memory"]?.value ?? 0, SIMD3(0.72, 0.5, 1.0))
            case "day":    return (Self.dayFraction(), SIMD3(1.0, 0.86, 0.45))
            case "music.bass": return (music.bass, SIMD3(1.0, 0.45, 0.55))
            case "music.mid":  return (music.mid, SIMD3(0.55, 1.0, 0.6))
            case "music.high": return (music.high, SIMD3(0.6, 0.75, 1.0))
            case "zo":
                guard let s = free.next()?.value else { return (0, zoDefault) }
                return (s.value, s.color ?? zoDefault)
            default:
                if id.hasPrefix("zo:"), let s = snapshot["zo." + id.dropFirst(3)] {
                    return (s.value, s.color ?? zoDefault)
                }
                return (0, zoDefault)
            }
        }
    }

    static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let i = Int(h * 6) % 6, f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return [v, t, p]
        case 1: return [q, v, p]
        case 2: return [p, v, t]
        case 3: return [p, q, v]
        case 4: return [t, p, v]
        default: return [v, p, q]
        }
    }

    static func dayFraction(_ date: Date = Date()) -> Float {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Float((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440
    }
}
