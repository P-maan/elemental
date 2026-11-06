import Foundation

/// The colour of the song that is playing, laid over the wall as the
/// faintest tinge. Asked for 3 Nov 2026: "a wallpaper tinge for what song is
/// playing" — then "very very subtle, like just telling the album cover".
///
/// ALBUM ART ONLY. When Music or Spotify is playing, the host (NowPlaying, in
/// the app) reads the cover and hands over its dominant colour — the hue that
/// covers the most of it with real saturation, not the average, which for
/// almost every cover is a muddy brown. No cover, no tinge: guessing a colour
/// from the sound would be telling something the cover does not.
///
/// It fades in over a couple of seconds while the music is heard and out over
/// a few once it stops. Luminance is preserved in the shader, so the sky only
/// leans toward the cover's hue; it never gets lighter or darker.
final class SongTint: @unchecked Sendable {
    static let shared = SongTint()
    private let lock = NSLock()

    private var art: SIMD3<Float>?
    private var lastHeard: CFAbsoluteTime = -100
    private var lastStep: CFAbsoluteTime = 0
    private var cur = SIMD3<Float>(1, 1, 1)
    private var amt: Float = 0
    /// Render tool only: a fixed colour (0..1) at full strength.
    var forced: SIMD3<Float>?
    private var trust = false

    /// On battery the meter does not run, so nothing is "heard": the player
    /// saying it is playing (NowPlaying only sets a cover then) is enough.
    var trustPlayer: Bool {
        get { lock.lock(); defer { lock.unlock() }; return trust }
        set { lock.lock(); trust = newValue; lock.unlock() }
    }

    /// How strong the tinge is at most: a hint, not a filter.
    static let strength: Float = 0.07

    /// The cover's colour, 0..1, or nil when there is no cover to read.
    func setArt(_ c: SIMD3<Float>?) {
        lock.lock(); art = c; lock.unlock()
    }

    /// What is showing now, without stepping — for LiveRelay.
    var current: (rgb: SIMD3<Float>, amount: Float) {
        lock.lock(); defer { lock.unlock() }; return (cur, amt)
    }

    /// The screen saver: the tinge relayed from the app (LiveRelay).
    private var relayed: (rgb: SIMD3<Float>, amount: Float, at: CFAbsoluteTime)?
    func relay(rgb: SIMD3<Float>, amount: Float) {
        lock.lock(); relayed = (rgb, amount, CFAbsoluteTimeGetCurrent()); lock.unlock()
    }

    /// Called once per frame per surface. Easing is on wall-clock time since the
    /// last call from ANY surface, so two displays do not ease twice as fast.
    func step(spectrum: [Float]) -> (rgb: SIMD3<Float>, amount: Float) {
        lock.lock(); defer { lock.unlock() }
        if let f = forced { return (f, Self.strength) }
        if let r = relayed, CFAbsoluteTimeGetCurrent() - r.at < 1 { return (r.rgb, r.amount) }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(min(0.5, max(0, now - lastStep)))
        lastStep = now
        if spectrum.reduce(0, +) > 0.3 { lastHeard = now }
        let on = art != nil && (trust || now - lastHeard < 2)
        if let a = art { cur += (1 - exp(-dt / 1.5)) * (a - cur) }
        let goal: Float = on ? Self.strength : 0
        amt += (1 - exp(-dt / (on ? 1.5 : 4))) * (goal - amt)
        return (cur, amt)
    }
}
