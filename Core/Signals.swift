import Foundation

/// Zo's reminders, shown by the sky with what it already has.
///
/// Asked for 5 Nov 2026, after several tries that drew new things on the sky
/// (coloured rays, rings, comets, an aurora): "use already existing effects
/// to show info; if they are not, don't show that info — just show Zo info".
/// So there is no gauge and no system reading. A reminder from Zo is a value
/// 0..1 (how pressing) and a colour, and it drives the effects the scene
/// already has, in whatever weather is up (Scene.metal, ZO):
///
///   clear day        the sun's ripple and glow, the way a message moves them
///   overcast         the deck's light from within, as the music lights it
///   night, moon up   the moon's halo
///   night, no moon   the stars' shimmer
///
/// Its colour only leans that glow toward it, luminance kept. With several up
/// at once the sky turns from one to the next every few seconds.
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

    /// The reminder showing now, eased: its strength 0..1 and colour 0..1.
    /// Several take turns, eight seconds each, fading through each other.
    /// The screen saver: Zo's glow relayed from the app (LiveRelay).
    private var relayed: (value: Float, rgb: SIMD3<Float>, at: CFAbsoluteTime)?
    func relay(value: Float, rgb: SIMD3<Float>) {
        lock.lock(); relayed = (value, rgb, CFAbsoluteTimeGetCurrent()); lock.unlock()
    }

    func glow() -> (value: Float, rgb: SIMD3<Float>) {
        lock.lock()
        if let r = relayed, CFAbsoluteTimeGetCurrent() - r.at < 1 { lock.unlock(); return (r.value, r.rgb) }
        prune()
        let zo = map.filter { $0.key.hasPrefix("zo.") }.sorted { $0.value.setAt < $1.value.setAt }
        lock.unlock()
        guard !zo.isEmpty else { return (0, SIMD3(1, 1, 1)) }
        let t = CFAbsoluteTimeGetCurrent() / 8
        let k = Int(t) % zo.count
        let s = zo[k].value
        // In and out of each turn over a second and a half, so one reminder
        // hands to the next rather than switching.
        let f = Float(t - floor(t))
        let fade = zo.count > 1 ? min(1, min(f, 1 - f) * 5.3) : 1
        return (s.value * fade, s.color ?? SIMD3(0.55, 0.85, 1.0))
    }


}
