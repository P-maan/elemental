import Foundation
import simd

// MARK: - Festivals
//
// Asked for 6 Nov 2026 (Dhanteras): "autumn leaves are a feature for places
// that actually have autumn, so back home there will be none — but you can do
// full festive things like Diwali, and I want all of those too."
//
// The wall keeps the festivals of where its sky is, and — unless turned off —
// the Indian ones wherever that is. Everything is drawn with the mosaic's own
// cells: a festival light is a deposit that GLOWS (Scene.metal, kind 15), so a
// diya on the top of a widget, a spark from a rocket and a kite are all just
// tiles lit in their own colour.
//
//   Lohri                   a bonfire at the foot of the wall, sparks rising
//   Makar Sankranti         kites in the day sky
//   Holika Dahan            the bonfire, the night before Holi
//   Holi                    puffs of gulal in the air, colour left on ledges
//   15 August               kites (Delhi flies them on Independence Day)
//   Navratri                strings of small lights, nine nights
//   Dussehra                Ravan's bonfire, then fireworks
//   Dhanteras .. Bhai Dooj  diyas on every ledge and along the ground;
//                           fireworks, building to Diwali night
//   Gurpurab                diyas, a few fireworks
//   Christmas               strings of coloured lights
//   New Year's Eve          fireworks round midnight
//   4 July (US)             fireworks
//   Halloween (US)          lanterns flickering along the ground
//
// Lunar dates come from the New Delhi panchang (adiveda.in, drikpanchang),
// checked for 2026-2030. Past 2030 the lunar ones simply do not happen until
// the table is extended; the fixed-date ones carry on.

struct FestivalLook: Equatable {
    var name = ""
    /// 0..1 each. Night ones show after sunset; day ones while the sun is up.
    var lamps: Float = 0         // diyas: night
    var fireworks: Float = 0     // night
    var strings: Float = 0       // strings of coloured lights: night
    var lanterns: Float = 0      // night
    var bonfire: Float = 0       // night
    var kites: Float = 0         // day
    var colours: Float = 0       // day
    var any: Bool { lamps + fireworks + strings + lanterns + bonfire + kites + colours > 0 }
}

enum Festivals {
    /// (year, month, day) of each lunar festival, New Delhi panchang.
    private static let diwali: [Int: (Int, Int)] = [2026: (11, 8), 2027: (10, 29), 2028: (10, 17), 2029: (11, 5), 2030: (10, 26)]
    private static let dhanteras: [Int: (Int, Int)] = [2026: (11, 6), 2027: (10, 27), 2028: (10, 15), 2029: (11, 4), 2030: (10, 24)]
    private static let bhaiDooj: [Int: (Int, Int)] = [2026: (11, 11), 2027: (10, 31), 2028: (10, 19), 2029: (11, 7), 2030: (10, 28)]
    private static let holi: [Int: (Int, Int)] = [2026: (3, 4), 2027: (3, 23), 2028: (3, 11), 2029: (3, 1), 2030: (3, 20)]
    private static let sankranti: [Int: (Int, Int)] = [2026: (1, 14), 2027: (1, 14), 2028: (1, 15), 2029: (1, 14), 2030: (1, 14)]
    private static let navratri: [Int: (Int, Int)] = [2026: (10, 11), 2027: (9, 30), 2028: (9, 19), 2029: (10, 8), 2030: (9, 28)]
    private static let dussehra: [Int: (Int, Int)] = [2026: (10, 20), 2027: (10, 9), 2028: (9, 27), 2029: (10, 16), 2030: (10, 6)]
    private static let gurpurab: [Int: (Int, Int)] = [2026: (11, 24), 2027: (11, 14), 2028: (11, 2), 2029: (11, 21), 2030: (11, 10)]

    /// Each place keeps its own festivals (6 Nov 2026: "in America do the
    /// American things, in India the Indian things, in Europe the European
    /// things").
    enum Region: Equatable { case india, us, uk, france, nordic, europe, other }

    /// Roughly which country a sky is over. Boxes, not borders: good enough
    /// to tell Greater Noida from Amherst from London. Checked most specific
    /// first.
    static func region(lat: Double, lon: Double) -> Region {
        if lat > 6, lat < 37.5, lon > 68, lon < 97.5 { return .india }
        if lat > 24, lat < 50, lon > -125, lon < -66 { return .us }
        if lat > 51, lat < 72, lon > -170, lon < -129 { return .us }   // Alaska
        if lat > 49.8, lat < 61, lon > -10.8, lon < 1.9 { return .uk } // and Ireland
        if lat > 54.5, lat < 71.5, lon > 4.5, lon < 32 { return .nordic }
        if lat > 42.3, lat < 51.1, lon > -4.9, lon < 8.3 { return .france }
        if lat > 35, lat < 71, lon > -10.5, lon < 40 { return .europe }
        return .other
    }
    static func isEurope(_ r: Region) -> Bool { r == .uk || r == .france || r == .nordic || r == .europe }

    /// What is being celebrated on the evening (for night things) or day of
    /// `date`, in the time zone the wall is in. An evening runs past midnight
    /// until four, so Diwali night does not stop at twelve.
    static func look(at date: Date, lat: Double, lon: Double, indianEverywhere: Bool,
                     calendar: Calendar = .current) -> (night: FestivalLook, day: FestivalLook) {
        let region = region(lat: lat, lon: lon)
        let indian = region == .india || indianEverywhere
        let hour = calendar.component(.hour, from: date)
        let evening = hour < 4 ? calendar.date(byAdding: .day, value: -1, to: date)! : date
        var night = FestivalLook(), day = FestivalLook()

        func ymd(_ d: Date) -> (Int, Int, Int) {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        func offset(_ d: Date, _ table: [Int: (Int, Int)]) -> Int? {
            let (y, _, _) = ymd(d)
            guard let md = table[y],
                  let f = calendar.date(from: DateComponents(year: y, month: md.0, day: md.1)) else { return nil }
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: f),
                                           to: calendar.startOfDay(for: d)).day
        }
        func on(_ d: Date, _ m: Int, _ dd: Int) -> Bool { let (_, mo, da) = ymd(d); return mo == m && da == dd }

        // ---- night
        let e = evening
        if indian {
            if on(e, 1, 13) { night.name = "Lohri"; night.bonfire = 1 }
            if let o = offset(e, holi), o == -1 { night.name = "Holika Dahan"; night.bonfire = 1 }
            if let o = offset(e, navratri), o >= 0, o < 9 { night.name = "Navratri"; night.strings = 0.5 }
            if let o = offset(e, dussehra), o == 0 { night.name = "Dussehra"; night.bonfire = 1; night.fireworks = 0.5; night.strings = 0 }
            if let d0 = offset(e, dhanteras), let d1 = offset(e, diwali), let d2 = offset(e, bhaiDooj),
               d0 >= 0, d2 <= 0 {
                night.name = "Diwali"
                switch d1 {
                case 0:  night.lamps = 1;   night.fireworks = 1
                case -1: night.lamps = 0.9; night.fireworks = 0.5
                case 1:  night.lamps = 0.8; night.fireworks = 0.35
                case ..<(-1): night.lamps = 0.75; night.fireworks = 0.2   // Dhanteras
                default: night.lamps = 0.6; night.fireworks = 0.1         // Bhai Dooj
                }
            }
            if let o = offset(e, gurpurab), o == 0 { night.name = "Gurpurab"; night.lamps = 0.7; night.fireworks = 0.2 }
        }
        if region == .us {
            if on(e, 7, 4) { night.name = "Fourth of July"; night.fireworks = 0.85 }
            if on(e, 10, 31) { night.name = "Halloween"; night.lanterns = 1 }
        }
        if isEurope(region) {
            // The Christmas markets: small lights all through December.
            let (_, mo, da) = ymd(e)
            if mo == 12, da < 24 { night.name = "Advent"; night.strings = 0.4 }
            if region == .uk, on(e, 11, 5) { night.name = "Bonfire Night"; night.bonfire = 1; night.fireworks = 0.7 }
            if region == .france, on(e, 7, 14) { night.name = "Bastille Day"; night.fireworks = 0.9 }
        }
        if indian || region == .us || isEurope(region) {
            if on(e, 12, 24) || on(e, 12, 25) || (isEurope(region) && on(e, 12, 26)) {
                night.name = "Christmas"; night.strings = 1
            }
        }
        // New Year everywhere: the fireworks are at midnight, so they belong
        // to the evening of the 31st and the small hours of the 1st.
        if on(e, 12, 31) {
            night.name = "New Year"
            let m = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let fromMidnight = m >= 12 * 60 ? m - 24 * 60 : m          // minutes, negative before
            night.fireworks = fromMidnight < -45 ? 0.1 : fromMidnight < 0 ? 0.5 : fromMidnight < 40 ? 1 : 0.25
            night.strings = max(night.strings, 0.4)
        }

        // ---- day
        // Midsummer in the north: bonfires on the eve, the Friday between
        // the 19th and 25th of June — when the sun hardly sets, so they burn
        // in the light.
        if region == .nordic {
            let c = calendar.dateComponents([.month, .day, .weekday], from: date)
            if c.month == 6, let d = c.day, d >= 19, d <= 25, c.weekday == 6 {
                day.name = "Midsummer"; day.bonfire = 1
            }
        }
        if indian {
            if let o = offset(date, sankranti), o == 0 { day.name = "Makar Sankranti"; day.kites = 1 }
            if on(date, 8, 15) { day.name = "Independence Day"; day.kites = 0.8 }
            if let o = offset(date, holi), o == 0 { day.name = "Holi"; day.colours = 1 }
        }
        return (night, day)
    }
}

// MARK: - The effects

/// The festival's things on the wall: particles in the air and lights on the
/// ledges, stamped into the glass layer each frame as glowing cells. Owned by
/// the simulation; nothing here touches the GPU.
final class FestivalFX {
    var nightLook = FestivalLook()
    var dayLook = FestivalLook()
    /// 0..1: how far into the night (sun below the horizon) / day it is.
    var nightK: Float = 0
    var dayK: Float = 0

    private struct Spark { var x, y, vx, vy, life, maxLife: Float; var rgb: SIMD3<Float>; var rocket: Bool; var burst: Int }
    private var sparks: [Spark] = []
    private struct Kite { var x, y, phase, size: Float; var rgb: SIMD3<Float>; var tail: SIMD3<Float> }
    private var kites: [Kite] = []
    private struct Puff { var x, y, r, life, maxLife: Float; var rgb: SIMD3<Float> }
    private var puffs: [Puff] = []
    /// Gulal left lying on the ledges: per surface index, cell column -> colour, life (s).
    private var gulal: [Int: [Int: (rgb: SIMD3<Float>, life: Float)]] = [:]
    private var rng = SystemRandomNumberGenerator()
    private func rnd() -> Float { Float.random(in: 0..<1, using: &rng) }

    var hasParticles: Bool { !sparks.isEmpty || !puffs.isEmpty }
    var active: Bool { (nightK > 0 && nightLook.any) || (dayK > 0 && dayLook.any) || hasParticles }

    /// Packs a colour for the shader: five bits a channel, in a float.
    static func code(_ c: SIMD3<Float>) -> Float {
        func q(_ v: Float) -> Float { (max(0, min(1, v)) * 31).rounded() }
        return q(c.x) * 1024 + q(c.y) * 32 + q(c.z)
    }

    private static let burstColours: [[SIMD3<Float>]] = [
        [SIMD3(1.0, 0.80, 0.35)],                                // gold
        [SIMD3(1.0, 0.30, 0.25), SIMD3(1.0, 0.80, 0.35)],        // red and gold
        [SIMD3(0.35, 1.0, 0.45)],                                // green
        [SIMD3(1.0, 0.35, 0.85), SIMD3(0.55, 0.45, 1.0)],        // magenta and violet
        [SIMD3(0.45, 0.70, 1.0), SIMD3(1, 1, 1)],                // blue and white
        [SIMD3(1.0, 0.55, 0.15)],                                // orange
        [SIMD3(1, 1, 1)],                                        // white crackle
    ]
    private static let gulalColours: [SIMD3<Float>] = [
        SIMD3(1.0, 0.25, 0.60), SIMD3(0.20, 0.85, 0.35), SIMD3(1.0, 0.85, 0.15),
        SIMD3(0.25, 0.50, 1.0), SIMD3(1.0, 0.50, 0.10), SIMD3(0.65, 0.25, 0.90),
    ]
    private static let kiteColours: [SIMD3<Float>] = [
        SIMD3(1.0, 0.25, 0.30), SIMD3(1.0, 0.80, 0.15), SIMD3(0.25, 0.75, 0.40),
        SIMD3(0.30, 0.50, 1.0), SIMD3(1.0, 0.45, 0.80), SIMD3(1.0, 0.55, 0.10),
    ]

    func step(dt: Float, W: Float, H: Float, SP: Float, crossWind: Float, surfaces: [Surface]) {
        guard SP > 0, W > 0 else { return }
        let fw = nightLook.fireworks * nightK
        // ---- fireworks: a rocket climbs, slows and bursts
        if fw > 0.01 {
            let perMin = 2 + 22 * fw
            if rnd() < perMin / 60 * dt, sparks.count < 900 {
                let x = W * (0.08 + rnd() * 0.84)
                let pal = Self.burstColours[Int(rnd() * Float(Self.burstColours.count)) % Self.burstColours.count]
                sparks.append(Spark(x: x, y: H, vx: (rnd() - 0.5) * SP * 3, vy: -H * (0.55 + rnd() * 0.25),
                                    life: 0, maxLife: 1.1 + rnd() * 0.6, rgb: pal[0], rocket: true,
                                    burst: Int(rnd() * Float(Self.burstColours.count))))
            }
        }
        // ---- the bonfire's sparks
        let fire = max(nightLook.bonfire * nightK, dayLook.bonfire * dayK)
        if fire > 0.01, rnd() < fire * 6 * dt, sparks.count < 900 {
            let x = W * 0.5 + (rnd() - 0.5) * SP * 4
            sparks.append(Spark(x: x, y: H - SP * 3, vx: (rnd() - 0.5) * SP * 2, vy: -SP * (4 + rnd() * 5),
                                life: 0, maxLife: 1.5 + rnd() * 1.5,
                                rgb: SIMD3(1.0, 0.55 + rnd() * 0.3, 0.15), rocket: false, burst: -1))
        }
        var born: [Spark] = []
        for k in sparks.indices.reversed() {
            var s = sparks[k]
            s.life += dt
            if s.rocket {
                s.vy += H * 0.32 * dt                       // slowing as it climbs
                s.x += s.vx * dt; s.y += s.vy * dt
                if s.vy > -H * 0.08 || s.life > s.maxLife {
                    // BURST: a sphere of sparks, seen flat — a ring of fast
                    // ones and a fill of slower ones, in one or two colours.
                    let pal = Self.burstColours[s.burst % Self.burstColours.count]
                    let n = 28 + Int(rnd() * 22), speed = SP * (9 + rnd() * 7)
                    for i in 0..<n {
                        let a = Float(i) / Float(n) * 2 * .pi + rnd() * 0.2
                        let v = speed * (i % 3 == 0 ? 0.55 + rnd() * 0.3 : 0.9 + rnd() * 0.15)
                        born.append(Spark(x: s.x, y: s.y, vx: cos(a) * v, vy: sin(a) * v, life: 0,
                                          maxLife: 1.3 + rnd() * 0.9, rgb: pal[i % pal.count], rocket: false, burst: -1))
                    }
                    sparks.remove(at: k); continue
                }
            } else {
                s.vx *= 1 - min(1, dt * 1.6); s.vy *= 1 - min(1, dt * 1.6)   // air drag
                s.vy += SP * 5 * dt                                           // and they fall
                s.vx += crossWind * SP * 0.02 * dt
                s.x += s.vx * dt; s.y += s.vy * dt
                if s.life > s.maxLife || s.y > H || s.x < -SP || s.x > W + SP { sparks.remove(at: k); continue }
            }
            sparks[k] = s
        }
        sparks += born

        // ---- kites: a handful, swaying, tugged by the wind
        let kiteN = Int((dayLook.kites * dayK * 7).rounded())
        while kites.count < kiteN {
            kites.append(Kite(x: W * (0.1 + rnd() * 0.8), y: H * (0.10 + rnd() * 0.32), phase: rnd() * 6.28,
                              size: rnd() < 0.3 ? 2 : 1,
                              rgb: Self.kiteColours[Int(rnd() * 6) % 6], tail: Self.kiteColours[Int(rnd() * 6) % 6]))
        }
        if kites.count > kiteN { kites.removeLast(kites.count - kiteN) }
        for k in kites.indices {
            kites[k].phase += dt * (0.7 + Float(k) * 0.13)
            kites[k].x += (sin(kites[k].phase) * SP * 0.6 + crossWind * SP * 0.01) * dt
            kites[k].y += cos(kites[k].phase * 1.3) * SP * 0.4 * dt
            kites[k].x = min(W * 0.95, max(W * 0.05, kites[k].x))
            kites[k].y = min(H * 0.5, max(H * 0.06, kites[k].y))
        }

        // ---- Holi: gulal thrown into the air, and what settles on ledges
        let col = dayLook.colours * dayK
        if col > 0.01, rnd() < col * 0.7 * dt, puffs.count < 30 {
            let rgb = Self.gulalColours[Int(rnd() * 6) % 6]
            puffs.append(Puff(x: W * (0.05 + rnd() * 0.9), y: H * (0.45 + rnd() * 0.45), r: SP * (1.5 + rnd() * 2),
                              life: 0, maxLife: 4 + rnd() * 4, rgb: rgb))
        }
        for k in puffs.indices.reversed() {
            puffs[k].life += dt
            puffs[k].x += crossWind * SP * 0.03 * dt
            puffs[k].y -= SP * 0.25 * dt
            puffs[k].r += SP * 0.35 * dt
            if puffs[k].life > puffs[k].maxLife {
                // What falls out of it lands on a ledge under it.
                let p = puffs[k]
                for (i, s) in surfaces.enumerated() where s.kind != .menuBar && p.x > s.left && p.x < s.right && p.y < s.top {
                    let c0 = Int((p.x - p.r) / SP), c1 = Int((p.x + p.r) / SP)
                    for c in c0...max(c0, c1) where rnd() < 0.6 { gulal[i, default: [:]][c] = (p.rgb, 3 * 3600) }
                    break
                }
                puffs.remove(at: k)
            }
        }
        if !gulal.isEmpty {
            for (i, m) in gulal {
                var n = m
                for (c, g) in m { let l = g.life - dt; if l <= 0 { n[c] = nil } else { n[c] = (g.rgb, l) } }
                gulal[i] = n.isEmpty ? nil : n
            }
        }
    }

    /// Lay the festival into the glass layer. `put(cx, cy, strength, colourCode, glows)`
    /// writes a kind-15 cell if it is stronger than what is there.
    func stamp(W: Float, H: Float, SP: Float, cols: Int, rows: Int, time: Float, surfaces: [Surface],
               marks: (Surface.Kind) -> Bool, put: (Int, Int, Float, Float, Bool) -> Void) {
        guard SP > 0, cols > 0, rows > 0 else { return }
        @inline(__always) func hash(_ n: Float) -> Float { let s = sin(n * 12.9898) * 43758.5453; return s - floor(s) }
        // The flicker of a flame, in steps a few times a second — enough to
        // live, not so fast it asks for frames.
        @inline(__always) func flicker(_ seed: Float) -> Float {
            let t = floor(time * 5 + seed * 3)
            return 0.72 + 0.28 * hash(t * 1.7 + seed * 31)
        }
        let night = nightK, n = nightLook

        // ---- diyas: on every ledge, and along the ground. A diya is a
        // shallow clay lamp, wider than it is tall, with the wick at one end
        // and a flame standing up out of it — so, in tiles:
        //
        //        .  ^  .        the flame's tip, only when it flares
        //        :  *  :        the flame, a faint warm glow either side
        //        b  o  b        the bowl's rim, oil dark in the middle
        //        .  b  .        its foot, resting on the ledge
        //
        // ("those diyas don't look like diyas", 6 Nov 2026 — the first ones
        // were a single brown tile with a dot over it.)
        if n.lamps * night > 0.02 {
            let a = n.lamps * night
            let clay = Self.code(SIMD3(0.78, 0.36, 0.16)), clayDark = Self.code(SIMD3(0.56, 0.24, 0.10))
            let oil = Self.code(SIMD3(0.30, 0.14, 0.06))
            func diya(_ cx: Int, _ foot: Int, _ seed: Float) {
                let fl = flicker(seed)
                put(cx, foot, 0.95 * a, clayDark, false)
                put(cx - 1, foot - 1, 0.95 * a, clay, false)
                put(cx, foot - 1, 0.95 * a, oil, false)
                put(cx + 1, foot - 1, 0.95 * a, clay, false)
                // The flame: a hot core, its colour wandering with the flicker.
                put(cx, foot - 2, a * (0.70 + 0.30 * fl), Self.code(SIMD3(1.0, 0.78 + 0.14 * fl, 0.34 + 0.2 * fl)), true)
                // A warm halo on the air beside it.
                put(cx - 1, foot - 2, a * 0.22 * fl, Self.code(SIMD3(1.0, 0.55, 0.15)), true)
                put(cx + 1, foot - 2, a * 0.22 * fl, Self.code(SIMD3(1.0, 0.55, 0.15)), true)
                // When it flares, the tip licks up a tile.
                if fl > 0.86 { put(cx, foot - 3, a * 0.55, Self.code(SIMD3(1.0, 0.52, 0.12)), true) }
            }
            // ORDERED, as they are set out on a real ledge: one at each end,
            // the rest evenly between, the row symmetric about the middle
            // ("diyas should be at the edges and organised", 6 Nov 2026).
            func row(_ first: Int, _ last: Int, _ foot: Int, _ seed: Float) {
                guard last - first >= 0 else { return }
                let n = max(1, (last - first) / 7 + 1)
                for k in 0..<n {
                    let cx = n == 1 ? (first + last) / 2
                                    : first + Int((Float(k) * Float(last - first) / Float(n - 1)).rounded())
                    diya(cx, foot, Float(cx) * 0.37 + seed)
                }
            }
            for (i, s) in surfaces.enumerated() where marks(s.kind) && s.kind != .menuBar {
                // The bowl is three tiles wide, so its middle sits one in
                // from each end of the ledge.
                let c0 = Int((s.left / SP).rounded(.up)), c1 = Int((s.right / SP).rounded(.down)) - 1
                let foot = Int(s.top / SP)
                guard c1 - c0 >= 2, foot > 2 else { continue }
                row(c0 + 1, c1 - 1, foot, Float(i))
            }
            row(1, cols - 2, rows - 1, 0.5)
        }
        // ---- strings of small coloured lights along the ledges and the top
        if n.strings * night > 0.02 {
            let a = n.strings * night
            let pal: [SIMD3<Float>] = [SIMD3(1, 0.25, 0.25), SIMD3(0.3, 1, 0.4), SIMD3(1, 0.8, 0.3), SIMD3(0.4, 0.6, 1)]
            func bulb(_ cx: Int, _ cy: Int, _ k: Int) {
                let on = hash(floor(time * 1.5 + Float(k) * 0.7) + Float(k)) > 0.25
                put(cx, cy, a * (on ? 0.95 : 0.35), Self.code(pal[k % pal.count]), true)
            }
            for (i, s) in surfaces.enumerated() where marks(s.kind) && s.kind != .menuBar {
                let c0 = Int(s.left / SP), c1 = Int((s.right - 0.001) / SP), row = Int(s.top / SP)
                guard row > 0 else { continue }
                var c = c0, k = i
                while c <= c1 { bulb(c, row, k); c += 2; k += 1 }
            }
            var c = 1, k = 0
            while c < cols { bulb(c, 0, k); c += 3; k += 1 }
        }
        // ---- lanterns along the ground (Halloween)
        if n.lanterns * night > 0.02 {
            let a = n.lanterns * night
            var c = 4
            while c < cols - 1 {
                put(c, rows - 1, a * flicker(Float(c)), Self.code(SIMD3(1.0, 0.50, 0.08)), true)
                put(c + 1, rows - 1, a * 0.8 * flicker(Float(c) + 9), Self.code(SIMD3(1.0, 0.42, 0.05)), true)
                c += 9
            }
        }
        // ---- the bonfire: a heap of flame cells at the foot, tallest in
        // the middle, every column flickering to its own height
        let fireA = max(n.bonfire * night, dayLook.bonfire * dayK)
        if fireA > 0.02 {
            let a = fireA
            let mid = cols / 2
            for d in -3...3 {
                let cx = mid + d
                let tall = (4.5 - Float(abs(d))) * (0.6 + 0.6 * flicker(Float(cx) * 1.3))
                for k in 0..<Int(tall.rounded(.up)) {
                    let t = Float(k) / max(1, tall)
                    let rgb = SIMD3<Float>(1.0, 0.25 + 0.6 * t, 0.05 + 0.25 * t * t)
                    put(cx, rows - 1 - k, a * (1 - t * 0.35), Self.code(rgb), true)
                }
            }
        }
        // ---- sparks and rockets
        for s in sparks {
            let cx = Int(s.x / SP), cy = Int(s.y / SP)
            guard cx >= 0, cx < cols, cy >= 0, cy < rows else { continue }
            let f = s.rocket ? 0.85 : max(0, 1 - s.life / s.maxLife)
            // A burst's last moments crackle.
            let crack: Float = !s.rocket && f < 0.3 ? (hash(Float(cx * 7 + cy) + floor(time * 12)) > 0.5 ? 1 : 0.2) : 1
            put(cx, cy, min(1, (0.25 + 0.85 * f) * crack), Self.code(s.rgb), true)
        }
        // ---- kites, and their strings down toward the ground
        for k in kites {
            let cx = Int(k.x / SP), cy = Int(k.y / SP)
            let a = dayK * dayLook.kites
            put(cx, cy - 1, a, Self.code(k.rgb), false)
            put(cx - 1, cy, a, Self.code(k.rgb), false)
            put(cx + 1, cy, a, Self.code(k.rgb * 0.8), false)
            put(cx, cy, a, Self.code(k.tail), false)
            put(cx, cy + 1, a, Self.code(k.rgb * 0.85), false)
            if k.size > 1 { put(cx, cy - 2, a, Self.code(k.rgb), false); put(cx, cy + 2, a, Self.code(k.rgb * 0.8), false) }
            // The string: every other cell down and away, faint.
            var x = Float(cx), y = Float(cy + 2)
            for _ in 0..<6 { x -= 0.6; y += 1.4; put(Int(x), Int(y), a * 0.35, Self.code(SIMD3(0.92, 0.92, 0.95)), false) }
        }
        // ---- Holi
        for p in puffs {
            let f = 1 - p.life / p.maxLife
            let r = p.r / SP
            let c0 = Int(p.x / SP - r), c1 = Int(p.x / SP + r), r0 = Int(p.y / SP - r), r1 = Int(p.y / SP + r)
            guard c1 >= c0, r1 >= r0 else { continue }
            for cy in r0...r1 {
                for cx in c0...c1 {
                    let dx = (Float(cx) + 0.5) - p.x / SP, dy = (Float(cy) + 0.5) - p.y / SP
                    let d = (dx * dx + dy * dy).squareRoot() / max(0.5, r)
                    guard d < 1 else { continue }
                    let g = hash(Float(cx) * 3.1 + Float(cy) * 7.3)
                    guard g > d * 0.8 else { continue }
                    // Powder in sunlight is the most saturated thing in the sky.
                    put(cx, cy, f * (1 - d * 0.6) * 0.9, Self.code(p.rgb), true)
                }
            }
        }
        for (i, m) in gulal where i < surfaces.count {
            let row = Int(surfaces[i].top / SP)
            for (c, g) in m { put(c, row, min(0.8, g.life / 1800) * 0.8, Self.code(g.rgb), false) }
        }
    }
}
