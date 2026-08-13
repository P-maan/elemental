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

//  ---------------------------------------------------------------------------
//  SATELLITE — the same argument as radar, made about cloud.
//
//  Radar fixed the placement of PRECIPITATION and left the placement of CLOUD
//  still invented: the deck's density field is noise shaped to hit Open-Meteo's
//  "63% low cloud", so the coverage is right and the arrangement is fiction. On
//  a broken-cloud afternoon that is the most visible remaining lie in the scene,
//  because the one thing you can check by looking up is whether there is a hole
//  where the sky is showing one.
//
//  Geostationary infrared answers it, and answers a second question for free.
//  A thermal-window channel measures how COLD the top of each column is, and in
//  a troposphere that cools with height, cold means high. So one image carries
//  both halves of what the deck needs — where the cloud is, and which deck it
//  belongs to — where the forecast supplies only how much of it there is.
//
//  COVERING THE WHOLE PLANET TAKES FOUR SATELLITES AND TWO PUBLISHERS.
//
//  No single free keyless service carries every sector. NASA GIBS carries the
//  American and Pacific satellites but has no Meteosat at all, which would leave
//  Europe, Africa, the Middle East and western India — including the machine
//  this was written on — with nothing. EUMETSAT publishes exactly that gap.
//  Between them the globe closes:
//
//      GOES-West   137.0°W   GIBS        Pacific, western North America
//      GOES-East    75.2°W   GIBS        the Americas, western Atlantic
//      Meteosat      0.0°    EUMETSAT    Europe, Africa, eastern Atlantic
//      Meteosat     45.5°E   EUMETSAT    Middle East, India, Indian Ocean
//      Himawari    140.7°E   GIBS        east Asia, Australia, west Pacific
//
//  Both publishers speak WMS, which takes a bounding box rather than a tile
//  index, so the two backends differ only in the URL they build — the fetch, the
//  decode and the statistics are one path.
//
//  WHY THE DECODE IS NOT A COLOUR TABLE.
//
//  EUMETSAT serves a plain inverted greyscale. GIBS serves the forecaster's
//  enhancement: grey up to a point, then blue and green for the coldest tops.
//  Inverting a named colour ramp is exactly the scheme-specific fragility the
//  radar decode above refuses, so this does not. It uses the one property every
//  IR enhancement ever drawn shares — colour is spent only on temperatures past
//  the top of the grey ramp — and reads brightness normally while treating any
//  saturated pixel as colder than the greyscale can express. EUMETSAT's
//  greyscale is then just the case where no pixel is ever saturated, and both
//  publishers decode correctly without either being special-cased.
//
//  Degradable in the same way as everything else: nil on any failure, and the
//  deck falls back to the density field it has always used.

/// What one satellite image says about the cloud over a place.
///
/// Codable because this is stored whole on `WeatherState` and crosses into the
/// screen saver through the preferences bridge, which carries JSON.
struct SatelliteLook: Codable, Equatable {

    /// Fraction of the sampled area carrying cloud, 0..1. Comparable with
    /// Open-Meteo's total cloud cover, which is how it gets sanity-checked.
    var coverage: Float = 0

    /// Cloud opacity directly overhead, 0..1 — the presence signal, and the
    /// answer to "is there a hole above me right now".
    var here: Float = 0

    /// Cloud across the sample, west to east, normalised. The placement half:
    /// feeds the deck so a clearance to the west is drawn to the west.
    var profile: [Float] = []

    /// How cold the cloudy pixels are on average, 0..1. A height proxy — thin
    /// warm stratus sits near the bottom of this, deep convection at the top —
    /// used to decide which deck the cloud belongs to rather than trusting the
    /// forecast's split between low, mid and high.
    var topness: Float = 0

    /// Which satellite answered, for the logs and the CLI.
    var sector: String = ""

    /// How much this view is worth believing, 0..1, from how far off nadir the
    /// place sits.
    ///
    /// A geostationary satellite looks straight down at one point and at an
    /// increasingly grazing angle everywhere else. Near the limb a cloud is
    /// smeared across the ground far from where it actually is, its top is
    /// measured through a long slant path, and the pixel under a place may be
    /// looking at the side of a cloud several tens of kilometres away. Reported
    /// rather than hidden, because the alternative is to believe a limb view as
    /// firmly as a nadir one — which was measured doing real damage: Reykjavik
    /// at 66° off nadir had a fully overcast deck cut to 55% on the strength of
    /// an image too foreshortened to support it.
    var confidence: Float = 1

    /// When this was FETCHED, not when it was observed. These feeds run about
    /// ten to twenty minutes behind, and neither publisher returns the true
    /// scan time on a WMS GetMap, so claiming otherwise would be inventing
    /// precision. Cloud fields move slowly enough that it does not matter.
    var at: Date = .distantPast

    var isEmpty: Bool { coverage <= 0.001 }
}

extension SkyImagery {

    /// A geostationary satellite and the service that publishes it.
    private struct Sector {
        let name: String
        /// Sub-satellite longitude — the point it hangs over.
        let subLon: Double
        /// Builds a GetMap URL for a web-mercator bounding box.
        let url: (String, Int) -> String
    }

    private static func gibs(_ layer: String) -> (String, Int) -> String {
        { bbox, px in
            "https://gibs.earthdata.nasa.gov/wms/epsg3857/best/wms.cgi?"
            + "service=WMS&version=1.3.0&request=GetMap&layers=\(layer)"
            + "&styles=&format=image/png&transparent=true&crs=EPSG:3857"
            + "&bbox=\(bbox)&width=\(px)&height=\(px)"
        }
    }

    private static func eumetsat(_ layer: String) -> (String, Int) -> String {
        let group = layer.split(separator: ":").first.map(String.init) ?? layer
        let leaf = layer.split(separator: ":").last.map(String.init) ?? layer
        return { bbox, px in
            "https://view.eumetsat.int/geoserver/\(group)/\(leaf)/ows?"
            + "service=WMS&version=1.3.0&request=GetMap&layers=\(layer)"
            + "&styles=&format=image/png&transparent=true&crs=EPSG:3857"
            + "&bbox=\(bbox)&width=\(px)&height=\(px)"
        }
    }

    /// The five satellites, in no particular order — the nearest is chosen by
    /// longitude below. All are thermal-window channels around 10.5 µm: clean
    /// day and night, unlike the 3.9 µm band, which carries reflected sunlight
    /// and would read a sunlit desert as cloud every afternoon.
    private static var sectors: [Sector] {
        [
            Sector(name: "GOES-West", subLon: -137.0,
                   url: gibs("GOES-West_ABI_Band13_Clean_Infrared")),
            Sector(name: "GOES-East", subLon: -75.2,
                   url: gibs("GOES-East_ABI_Band13_Clean_Infrared")),
            Sector(name: "Meteosat-0", subLon: 0.0,
                   url: eumetsat("msg_fes:ir108")),
            Sector(name: "Meteosat-IODC", subLon: 45.5,
                   url: eumetsat("msg_iodc:ir108")),
            Sector(name: "Himawari", subLon: 140.7,
                   url: gibs("Himawari_AHI_Band13_Clean_Infrared")),
        ]
    }

    /// Angle between a place and the point a satellite hangs directly over,
    /// in degrees. 0 is straight down, 90 is the edge of the visible disc.
    ///
    /// This is a GREAT-CIRCLE distance and it has to be, because latitude and
    /// longitude do not trade off independently. Checking them separately —
    /// "within 70° of the sub-satellite longitude AND below 70° latitude" —
    /// admits Reykjavik at 64°N and 22°W, which is 66° off nadir and only just
    /// inside the limit, and admits 69°N/70°E as though it were fine when it is
    /// actually 71° and past it. One angle answers it correctly.
    private static func offNadir(lat: Double, lon: Double, subLon: Double) -> Double {
        let a = lat * .pi / 180
        var dl = (lon - subLon).truncatingRemainder(dividingBy: 360)
        if dl > 180 { dl -= 360 }
        if dl < -180 { dl += 360 }
        // Sub-satellite point is on the equator, so its latitude term is 1.
        let c = max(-1, min(1, cos(a) * cos(dl * .pi / 180)))
        return acos(c) * 180 / .pi
    }

    /// Which satellite sees this place best, and how well.
    ///
    /// The nearest one by true viewing angle. Past about 70° a geostationary
    /// view is so foreshortened that a cloud is smeared well away from where it
    /// actually is, and beyond that it is better to admit there is no usable
    /// image than to place cloud confidently in the wrong part of the sky.
    private static func sector(forLon lon: Double, lat: Double) -> (Sector, Double)? {
        var best: Sector?
        var bestAngle = Double.greatestFiniteMagnitude
        for s in sectors {
            let d = offNadir(lat: lat, lon: lon, subLon: s.subLon)
            if d < bestAngle { bestAngle = d; best = s }
        }
        guard let b = best, bestAngle <= 70 else { return nil }
        return (b, bestAngle)
    }

    /// How much a view from this angle is worth believing.
    ///
    /// Flat out to 45°, where the slant path is still short and displacement is
    /// small, then falling to nothing by 70°. Smooth rather than stepped, so
    /// that moving a location does not snap the sky between two readings.
    private static func confidence(offNadir d: Double) -> Float {
        let t = max(0, min(1, (d - 45) / 25))
        let s = t * t * (3 - 2 * t)          // smoothstep
        return Float(1 - s)
    }

    /// Web-mercator bounding box of a window `halfMetres` either side of a point.
    private static func mercatorBox(lat: Double, lon: Double, halfMetres: Double) -> String {
        let clamped = max(-85.05, min(85.05, lat))
        let x = lon * 20037508.34 / 180
        let y = log(tan((90 + clamped) * .pi / 360)) / (.pi / 180) * 20037508.34 / 180
        return "\(x - halfMetres),\(y - halfMetres),\(x + halfMetres),\(y + halfMetres)"
    }

    /// Fetch one image and decode it to cloud-ness per pixel.
    ///
    /// Returns the decoded values and a parallel validity mask. Off-disc and
    /// no-data pixels come back transparent and MUST NOT be counted as clear
    /// sky — at the edge of a satellite's view that would read half the window
    /// as a guaranteed clearance, which is the one wrong answer that would look
    /// most convincing.
    private static func readIR(url: String, px: Int) async -> (v: [Float], ok: [Bool])? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // EUMETSAT's gateway rejects a request with no agent string.
        req.setValue("Elemental (macOS live wallpaper)", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let w = img.width, h = img.height
        guard w == px, h == px else { return nil }
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Premultiplied, because CGBitmapContext does not accept anything else
        // with an alpha channel — unpremultiplied `.last` is a valid CGImage
        // format but not a valid CONTEXT format, and asking for it just returns
        // a nil context and no image at all. The channels are divided back out
        // below, which the decode needs: saturation is a ratio between colour
        // channels, and leaving alpha folded into them would drag every
        // partly-transparent pixel toward grey and lose exactly the coldest
        // tops at the edge of the disc.
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &raw, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        var v = [Float](repeating: 0, count: w * h)
        var ok = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let a = Float(raw[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            // Undo the premultiplication so the channels are true colour again.
            let r = Float(raw[i * 4]) / 255 / a
            let g = Float(raw[i * 4 + 1]) / 255 / a
            let b = Float(raw[i * 4 + 2]) / 255 / a
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            let sat = mx > 0.001 ? (mx - mn) / mx : 0
            // Colour is spent only past the top of the grey ramp, so a saturated
            // pixel is colder than the greyscale can say. Greyscale services
            // never reach this branch.
            v[i] = sat > 0.25 ? 1.0 : mx
            ok[i] = true
        }
        return (v, ok)
    }

    /// Fetch the current satellite picture of the cloud around a coordinate.
    ///
    /// Nil for no network, no satellite covering the place, or an image that
    /// will not decode. Callers treat nil as "no extra information".
    static func satellite(lat: Double, lon: Double) async -> SatelliteLook? {
        guard let (sec, angle) = sector(forLon: lon, lat: lat) else { return nil }

        // The same ~900 km window radar uses, so the two profiles describe the
        // same piece of sky and can be read against each other.
        let px = 256
        let box = mercatorBox(lat: lat, lon: lon, halfMetres: 450_000)
        guard let (v, ok) = await readIR(url: sec.url(box, px), px: px) else { return nil }

        // ---- Where is the warm ground?
        //
        // Infrared brightness has no absolute zero to measure cloud against: a
        // summer desert, a winter ocean and a cool night all put the cloud-free
        // surface at a different level, so any fixed threshold is right in one
        // climate and wrong in the rest. The scene supplies its own reference —
        // the coldest tenth-percentile of what is present is the surface, and
        // cloud is what stands above it.
        //
        // With one guard, because that argument inverts under complete overcast:
        // if every pixel is cloud then the tenth percentile is cloud too, and
        // normalising against it would report a solid deck as a clear sky. So
        // the reference is not allowed to rise past the level where an inverted
        // IR ramp stops being able to mean warm ground at all.
        var valid = [Float]()
        valid.reserveCapacity(v.count)
        for i in 0..<v.count where ok[i] { valid.append(v[i]) }
        // Half the window has to be real. Less than that is a limb view or a
        // failed tile, and the statistics stop meaning anything.
        guard valid.count > (px * px) / 2 else { return nil }
        valid.sort()
        let base = min(valid[valid.count / 10], 0.35)
        let span = max(0.15, 1 - base)

        var look = SatelliteLook()
        look.sector = sec.name
        look.at = Date()
        look.confidence = confidence(offNadir: angle)

        let cols = px / 8
        look.profile = [Float](repeating: 0, count: cols)
        var colSum = [Float](repeating: 0, count: cols)
        var colN = [Float](repeating: 0, count: cols)

        var cloudy = 0, total = 0
        var topSum: Float = 0

        for y in 0..<px {
            for x in 0..<px {
                let i = y * px + x
                guard ok[i] else { continue }
                let c = max(0, min(1, (v[i] - base) / span))
                total += 1
                if c > 0.15 { cloudy += 1; topSum += c }
                let gx = x / 8
                if gx < cols { colSum[gx] += c; colN[gx] += 1 }
            }
        }
        guard total > 0 else { return nil }
        look.coverage = Float(cloudy) / Float(total)
        look.topness = cloudy > 0 ? topSum / Float(cloudy) : 0
        for i in 0..<cols where colN[i] > 0 { look.profile[i] = colSum[i] / colN[i] }

        // Cloud overhead, averaged over a few pixels rather than taken from the
        // single centre one. At this scale a pixel is a couple of kilometres and
        // the navigation is not perfect to the pixel; a small neighbourhood is
        // the honest resolution of "is there cloud above me".
        let c0 = px / 2
        var acc: Float = 0, accN: Float = 0
        for dy in -3...3 {
            for dx in -3...3 {
                let gx = c0 + dx, gy = c0 + dy
                guard gx >= 0, gx < px, gy >= 0, gy < px else { continue }
                let i = gy * px + gx
                guard ok[i] else { continue }
                acc += max(0, min(1, (v[i] - base) / span))
                accN += 1
            }
        }
        look.here = accN > 0 ? acc / accN : 0
        return look
    }

    /// One-line summary for the CLI and the logs.
    static func describe(_ s: SatelliteLook) -> String {
        String(format: "satellite %@  cover %.1f%%  here %.2f  tops %.2f  trust %.2f",
               s.sector, s.coverage * 100, s.here, s.topness, s.confidence)
    }
}
