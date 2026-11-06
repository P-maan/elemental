import Foundation

/// The live things the screen saver cannot see for itself — the music, Zo's
/// reminder, the album cover's tinge — relayed from the app.
///
/// The saver is a separate, sandboxed process (legacyScreenSaver): it cannot
/// tap system audio, has no automation endpoint for Zo to reach and cannot
/// ask Music what is playing. So while it runs, the app posts one small
/// distributed notification about twenty times a second carrying all of it,
/// packed as hex in the notification's `object` (a string — sandboxed
/// receivers get that even where userInfo is withheld). The saver unpacks it
/// into its own Pulse, Signals and SongTint, so its renderer draws exactly
/// what the desktop would. Nothing is sent while no saver is running.
enum LiveRelay {
    static let name = Notification.Name("com.prakritmaan.elemental.live")

    /// App side: everything live right now, packed.
    static func pack() -> String {
        let spec = Pulse.shared.spectrum()
        let b = Pulse.shared.bands()
        let zo = Signals.shared.glow()
        let tint = SongTint.shared.current
        var v: [Float] = (0..<Pulse.bandCount).map { $0 < spec.count ? spec[$0] : 0 }
        v += [b.bass, b.mid, b.high, b.beat, Pulse.shared.message(),
              zo.value, zo.rgb.x, zo.rgb.y, zo.rgb.z,
              tint.rgb.x, tint.rgb.y, tint.rgb.z, min(1, tint.amount / SongTint.strength)]
        return v.map { String(format: "%02x", Int(max(0, min(1, $0)) * 255)) }.joined()
    }

    /// Saver side: unpack into this process's own singletons.
    static func apply(_ s: String) {
        let bytes = Array(s.utf8)
        let n = Pulse.bandCount + 13
        guard bytes.count == n * 2 else { return }
        var v = [Float](repeating: 0, count: n)
        for i in 0..<n {
            guard let x = UInt8(String(decoding: bytes[2 * i..<2 * i + 2], as: UTF8.self), radix: 16) else { return }
            v[i] = Float(x) / 255
        }
        let B = Pulse.bandCount
        let beatNow = v[B + 3] > 0.85 && lastBeat <= 0.85
        lastBeat = v[B + 3]
        if v[0..<B].contains(where: { $0 > 0.01 }) || v[B] > 0.01 {
            Pulse.shared.feedSpectrum(Array(v[0..<B]), bass: Double(v[B]), mid: Double(v[B + 1]),
                                      high: Double(v[B + 2]), beat: beatNow)
        }
        Pulse.shared.relayMessage(v[B + 4])
        Signals.shared.relay(value: v[B + 5], rgb: SIMD3(v[B + 6], v[B + 7], v[B + 8]))
        SongTint.shared.relay(rgb: SIMD3(v[B + 9], v[B + 10], v[B + 11]), amount: v[B + 12] * SongTint.strength)
    }
    nonisolated(unsafe) private static var lastBeat: Float = 0
}
