import Foundation

/// Live values the wall can SHOW — system readings, and anything Zo sends.
///
/// Asked for 5 Nov 2026: "use the elements themselves to show information …
/// system information, critical information, literally everything" — then
/// "don't number signals, be really creative with it", and "when it's cloudy
/// use the clouds". Settings turns SOURCES on; nothing is numbered or laid
/// out by hand. Each one is a value 0..1 and a colour, and the sky shows it in
/// whatever it has (Scene.metal, SIGNALS): rays from the sun on a clear day,
/// lights inside the cloud on an overcast, the moon's rings at night, an
/// aurora when there is no moon.
///
/// Sources, by id:
///   battery   charge, red when low through to green
///   cpu       load across all cores
///   memory    how much of RAM is in use
///   day       how far through the local day it is
///   zo        every signal Zo has set, each its own
///   zo:NAME   one of Zo's signals by name
///   music.bass / music.mid / music.high   the music, if the meter is running
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

    /// At most this many shown at once — the sky has room for that many.
    static let maxShown = 8
    static let maxRays = 12      // stored ids, for Config
    static let sources: [(id: String, title: String, detail: String)] = [
        ("zo", "Reminders from Zo", "Whatever Zo puts on the wall, until Zo clears it."),
        ("battery", "Battery", "Red when low, green when full."),
        ("cpu", "CPU load", "Amber, reaching out as the Mac works harder."),
        ("memory", "Memory in use", "Violet."),
        ("day", "Time of day", "Gold, growing from midnight to midnight."),
        ("music.bass", "Music — bass", "Rose, with the low notes."),
        ("music.mid", "Music — mids", "Green, with the voice and the chords."),
        ("music.high", "Music — highs", "Blue, with the cymbals."),
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
        let zoDefault = SIMD3<Float>(0.45, 0.85, 1.0)
        var out: [(Float, SIMD3<Float>)] = []
        for id in layout {
            switch id {
            case "battery":
                let v = snapshot["sys.battery"]?.value ?? 0
                out.append((v, Self.hsv(0.33 * v, 0.85, 1)))       // red when low, green when full
            case "cpu":    out.append((snapshot["sys.cpu"]?.value ?? 0, SIMD3(1.0, 0.68, 0.25)))
            case "memory": out.append((snapshot["sys.memory"]?.value ?? 0, SIMD3(0.72, 0.5, 1.0)))
            case "day":    out.append((Self.dayFraction(), SIMD3(1.0, 0.86, 0.45)))
            case "music.bass": out.append((music.bass, SIMD3(1.0, 0.45, 0.55)))
            case "music.mid":  out.append((music.mid, SIMD3(0.55, 1.0, 0.6)))
            case "music.high": out.append((music.high, SIMD3(0.6, 0.75, 1.0)))
            case "zo":
                // Every reminder Zo has up, each its own — nothing while
                // there are none, so a quiet day shows nothing from Zo.
                for z in zo { out.append((z.value.value, z.value.color ?? zoDefault)) }
            default:
                if id.hasPrefix("zo:"), let s = snapshot["zo." + id.dropFirst(3)] {
                    out.append((s.value, s.color ?? zoDefault))
                }
            }
        }
        return Array(out.prefix(Self.maxShown))
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
