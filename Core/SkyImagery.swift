//  SkyImagery.swift — where the weather actually IS, not just how much of it.
//
//  Every other source in this project is a POINT measurement: Open-Meteo gives
//  "63% low cloud" and "1.0 mm of rain" for one coordinate, and a METAR gives
//  what one observer at one aerodrome can see. Neither says where anything is.
//  So the engine has had to invent the spatial half — `edgeArr` and the deck's
//  density field are noise shaped to hit a measured average, and `precipField`
//  is a synthetic pattern of showers and gaps. That is the one place the scene
//  has been guessing rather than observing, and it is what stops it being what
//  is out of the window rather than something statistically like it.
//
//  Radar answers it. RainViewer publishes global composite radar as web-mercator
//  tiles, free and without a key, refreshed about every ten minutes, and a tile
//  is a picture of where the precipitation IS. Two things fall out of that, and
//  the second matters more than the first:
//
//    PLACEMENT   the horizontal distribution of echo across the tile becomes
//                `precipField` directly, so a shower that is off to the west is
//                drawn off to the west, and the gap between two cells is a real
//                gap rather than a plausible one.
//
//    PRESENCE    a model saying 1 mm/h over a grid box tens of kilometres wide
//                is not evidence that it is raining ON YOU. Radar is. This is
//                the ground truth for "is anything actually falling here", which
//                is the difference between a wallpaper that rains when it rains
//                and one that rains when the forecast thought it might.
//
//  Deliberately degradable. Everything here returns nil rather than throwing,
//  every caller has a working answer without it, and a machine that cannot reach
//  the network — or a screen saver whose sandbox declines — renders exactly as
//  it did before. Radar is evidence that REFINES the model, never a dependency.

import Foundation
import CoreGraphics
import ImageIO

/// What one radar frame says about the sky over a place.
struct RadarLook: Equatable {

    /// Fraction of the sampled area carrying any echo at all, 0..1.
    var coverage: Float = 0

    /// Echo intensity at the centre of the sample — i.e. over the user, 0..1.
    /// This is the presence signal.
    var here: Float = 0

    /// Mean intensity across everything that has echo. Separates "a wide sheet
    /// of light rain" from "one small violent cell", which the totals cannot.
    var meanIntensity: Float = 0

    /// Horizontal profile of echo across the sample, west to east, normalised.
    /// Feeds `precipField` so showers land where they actually are.
    var profile: [Float] = []

    /// When the frame was captured.
    var at: Date = .distantPast

    var isEmpty: Bool { coverage <= 0.001 }
}

enum SkyImagery {

    /// Zoom level for the sample. 7 puts roughly 300 km across the tile at mid
    /// latitudes, which is about the width of sky a person can see weather
    /// arriving from — far enough to catch the shower that is twenty minutes
    /// away, near enough that the pixels still mean something local.
    private static let zoom = 7

    /// How many tiles across to fetch. 3 gives a ~900 km window centred on the
    /// user without the tile boundary landing on them, which matters because
    /// the centre pixel IS the presence signal.
    private static let span = 3

    private static let tilePx = 256

    // MARK: - The index

    private struct Maps: Decodable {
        struct Frame: Decodable { let time: Int; let path: String }
        struct Radar: Decodable { let past: [Frame]? }
        let host: String
        let radar: Radar?
    }

    /// Most recent radar frame, or nil if the service is unreachable.
    private static func latestFrame() async -> (host: String, path: String, at: Date)? {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let maps = try? JSONDecoder().decode(Maps.self, from: data),
              let last = maps.radar?.past?.last else { return nil }
        return (maps.host, last.path, Date(timeIntervalSince1970: TimeInterval(last.time)))
    }

    // MARK: - Web mercator

    /// Tile coordinate, and where inside that tile the point falls.
    private static func tileIndex(lat: Double, lon: Double, z: Int) -> (x: Int, y: Int, fx: Double, fy: Double) {
        let n = Double(1 << z)
        let clampedLat = max(-85.05, min(85.05, lat))
        let rad = clampedLat * .pi / 180
        let xf = (lon + 180) / 360 * n
        let yf = (1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n
        return (Int(floor(xf)), Int(floor(yf)), xf - floor(xf), yf - floor(yf))
    }

    // MARK: - Reading a tile

    /// Decode one radar tile into intensity per pixel, 0..1.
    ///
    /// RainViewer's colour scheme 2 is a continuous ramp, so rather than trying
    /// to invert it back to dBZ — which is lossy and scheme-specific — intensity
    /// is taken from ALPHA, which the tiles use directly for echo strength and
    /// which is scheme-independent. A pixel with no precipitation is fully
    /// transparent, and that is exactly the question being asked.
    private static func readTile(host: String, path: String,
                                 x: Int, y: Int, z: Int) async -> [Float]? {
        let s = "\(host)\(path)/\(tilePx)/\(z)/\(x)/\(y)/2/1_1.png"
        guard let url = URL(string: s) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &raw, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = Float(raw[i * 4 + 3]) / 255 }
        return out
    }

    // MARK: - The look

    /// Fetch the current radar picture around a coordinate.
    ///
    /// Returns nil on any failure at all — no network, a service outage, a tile
    /// that will not decode. Callers treat nil as "no extra information" and
    /// carry on with the model, which is the whole contract.
    static func radar(lat: Double, lon: Double) async -> RadarLook? {
        guard let frame = await latestFrame() else { return nil }
        let centre = tileIndex(lat: lat, lon: lon, z: zoom)
        let half = span / 2

        // Fetch the window concurrently — nine small PNGs, and doing them in
        // series is nine round trips of latency for no reason.
        var tiles: [Int: [Float]] = [:]
        await withTaskGroup(of: (Int, [Float]?).self) { group in
            for row in -half...half {
                for col in -half...half {
                    let key = (row + half) * span + (col + half)
                    let tx = centre.x + col, ty = centre.y + row
                    group.addTask {
                        (key, await readTile(host: frame.host, path: frame.path,
                                             x: tx, y: ty, z: zoom))
                    }
                }
            }
            for await (k, v) in group { if let v { tiles[k] = v } }
        }
        // A window with nothing decoded is a failure; a window with holes is
        // still usable, and the holes read as "no echo there", which is the
        // safest wrong answer available.
        guard !tiles.isEmpty else { return nil }

        let W = tilePx * span, H = tilePx * span
        var look = RadarLook()
        look.at = frame.at
        look.profile = [Float](repeating: 0, count: W / 8)

        var wet = 0, total = 0
        var sum: Float = 0
        var colSum = [Float](repeating: 0, count: W / 8)
        var colN = [Float](repeating: 0, count: W / 8)

        for row in 0..<span {
            for col in 0..<span {
                guard let t = tiles[row * span + col] else { continue }
                for py in 0..<tilePx {
                    for px in 0..<tilePx {
                        let v = t[py * tilePx + px]
                        total += 1
                        if v > 0.04 { wet += 1; sum += v }
                        let gx = (col * tilePx + px) / 8
                        if gx < colSum.count { colSum[gx] += v; colN[gx] += 1 }
                    }
                }
            }
        }
        guard total > 0 else { return nil }
        look.coverage = Float(wet) / Float(total)
        look.meanIntensity = wet > 0 ? sum / Float(wet) : 0
        for i in 0..<colSum.count where colN[i] > 0 { look.profile[i] = colSum[i] / colN[i] }

        // Intensity over the user. Averaged over a small neighbourhood rather
        // than taken from the single centre pixel: one pixel at this zoom is
        // about a kilometre, and radar has speckle. A few kilometres is the
        // honest resolution of "is it raining here".
        let cxp = (half * tilePx) + Int(centre.fx * Double(tilePx))
        let cyp = (half * tilePx) + Int(centre.fy * Double(tilePx))
        var acc: Float = 0, accN: Float = 0
        for dy in -3...3 {
            for dx in -3...3 {
                let gx = cxp + dx, gy = cyp + dy
                guard gx >= 0, gx < W, gy >= 0, gy < H else { continue }
                let col = gx / tilePx, row = gy / tilePx
                guard let t = tiles[row * span + col] else { continue }
                acc += t[(gy % tilePx) * tilePx + (gx % tilePx)]
                accN += 1
            }
        }
        look.here = accN > 0 ? acc / accN : 0
        return look
    }

    /// One-line summary for the CLI and the logs.
    static func describe(_ r: RadarLook) -> String {
        String(format: "radar %@  cover %.1f%%  here %.2f  mean %.2f  age %.0f min",
               r.isEmpty ? "clear" : "echo", r.coverage * 100, r.here, r.meanIntensity,
               Date().timeIntervalSince(r.at) / 60)
    }
}
