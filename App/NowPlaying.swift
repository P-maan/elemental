import AppKit

/// Reads the cover of what Music or Spotify is playing and hands its colour to
/// `SongTint`. Runs only while the music meter is listening, every four
/// seconds, and only asks an app that is ALREADY running — `tell application`
/// would otherwise launch it.
///
/// There is no public "now playing" for other apps (MediaRemote is closed to
/// third parties since macOS 15.4), so this asks the two players that answer
/// AppleScript. macOS asks once per player for permission to control it
/// (NSAppleEventsUsageDescription). Anything else playing — a browser, a video —
/// falls back to SongTint's colour from the sound itself.
final class NowPlaying {
    private let queue = DispatchQueue(label: "com.elemental.nowplaying", qos: .utility)
    private var timer: Timer?
    private var lastTrack: String?      // touched only on `queue`

    /// Every four seconds, or fifteen on battery: each poll is an Apple Event
    /// that wakes the player too.
    private var every: TimeInterval = 4

    func update(shouldRun: Bool, economy: Bool = false) {
        let want: TimeInterval = economy ? 15 : 4
        if want != every { every = want; timer?.invalidate(); timer = nil }
        if shouldRun, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.poll() }
            timer?.tolerance = 1
            poll()
        } else if !shouldRun, let t = timer {
            t.invalidate(); timer = nil
            queue.async { [weak self] in self?.lastTrack = nil }
            SongTint.shared.setArt(nil)
        }
    }

    private func poll() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let spotify = ids.contains("com.spotify.client"), music = ids.contains("com.apple.Music")
        queue.async { [weak self] in self?.read(spotify: spotify, music: music) }
    }

    // MARK: on `queue`

    private func read(spotify: Bool, music: Bool) {
        if spotify, let r = Self.run("""
            tell application "Spotify"
                if player state is playing then return (id of current track) & linefeed & (artwork url of current track)
            end tell
            return ""
            """)?.stringValue, !r.isEmpty {
            let parts = r.split(separator: "\n", maxSplits: 1).map(String.init)
            if parts.first != lastTrack {
                lastTrack = parts.first
                SongTint.shared.setArt(nil)
                if parts.count > 1, let url = URL(string: parts[1]) { fetch(url, for: parts[0]) }
            }
            return
        }
        if music, let id = Self.run("""
            tell application "Music"
                if player state is playing then return persistent ID of current track
            end tell
            return ""
            """)?.stringValue, !id.isEmpty {
            if id != lastTrack {
                lastTrack = id
                let data = Self.run("""
                    tell application "Music" to return raw data of artwork 1 of current track
                    """)?.data
                SongTint.shared.setArt(data.flatMap { NSImage(data: $0) }.flatMap(Self.dominant))
            }
            return
        }
        if lastTrack != nil { lastTrack = nil; SongTint.shared.setArt(nil) }
    }

    private func fetch(_ url: URL, for track: String) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            let c = Self.dominant(img)
            self?.queue.async {
                guard self?.lastTrack == track else { return }
                SongTint.shared.setArt(c)
            }
        }.resume()
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    /// The cover's dominant COLOURFUL hue: pixels are binned by hue and
    /// weighted by saturation and brightness, so a big black border or a grey
    /// sky does not win; the heaviest bin's average is lifted to a clear,
    /// bright colour. A greyscale cover gives nil — the sound decides instead.
    static func dominant(_ img: NSImage) -> SIMD3<Float>? {
        let n = 24
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var weight = [Float](repeating: 0, count: 12)
        var sum = [SIMD3<Float>](repeating: .zero, count: 12)
        var total: Float = 0
        for i in 0..<(n * n) {
            let c = SIMD3<Float>(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255
            let mx = c.max(), mn = c.min()
            guard mx > 0.08 else { continue }
            let s = (mx - mn) / mx
            var h: Float
            if mx == mn { h = 0 }
            else if mx == c.x { h = ((c.y - c.z) / (mx - mn)).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = (c.z - c.x) / (mx - mn) + 2 }
            else { h = (c.x - c.y) / (mx - mn) + 4 }
            h = (h / 6 + 1).truncatingRemainder(dividingBy: 1)
            let w = s * s * mx.squareRoot()
            let b = min(11, Int(h * 12))
            weight[b] += w; sum[b] += c * w; total += w
        }
        guard total > 4, let best = weight.indices.max(by: { weight[$0] < weight[$1] }) else { return nil }
        let avg = sum[best] / weight[best]
        let mx = avg.max(), mn = avg.min()
        guard mx > 0.01 else { return nil }
        // Same hue, lifted to full brightness and at least moderate saturation.
        let s = max(0.45, (mx - mn) / mx)
        let norm = (avg - mn) / max(mx - mn, 1e-3)          // 0..1 per channel, hue only
        return SIMD3<Float>(repeating: 1 - s) + norm * s
    }
}
