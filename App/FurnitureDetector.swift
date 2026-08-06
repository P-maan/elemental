//  FurnitureDetector.swift — finding the dock and the widgets in a screenshot.
//
//  macOS publishes no API for where the user's desktop widgets are, and the
//  dock's extent is only approximable from com.apple.dock. So the Elements pane
//  asks for a screenshot instead, and this reads it.
//
//  ---- What the picture actually looks like
//
//  A desktop screenshot is the WALLPAPER — in our case a mosaic of hard-edged
//  blocks, which is the worst possible background for an edge detector — with a
//  handful of translucent rounded slabs sitting on it. Everything here is built
//  around telling those two apart, and the three cues that do it are:
//
//    1. LENGTH. A widget's border is one straight line 40-90 px long in the
//       working image. A mosaic cell's border is 8-10 px. A minimum segment
//       length an order of magnitude above the cell pitch removes the entire
//       grid in one step.
//    2. SIGN. A slab is darker (or lighter) than what it covers, so its top
//       edge is a transition one way and its bottom edge is the transition
//       back. Requiring opposite signs kills pairs made of two unrelated lines.
//    3. CALM. A slab is a blur-and-tint of what is behind it, so the wallpaper's
//       texture inside it is quieter than the texture around it. This is what
//       rejects a rectangle that is genuinely in the wallpaper — there the
//       inside is exactly as busy as the outside.
//
//  ---- Honesty
//
//  This is a heuristic and it is wrong sometimes. That is a deliberate design
//  position, not an excuse: detection exists to save the user from placing eight
//  rectangles by hand, and the editable grid next to it exists to fix whatever
//  detection got wrong. A rough detector with a good editor beats an elaborate
//  detector with no editor. Measured numbers are in the header of
//  ElementsSelfTest.swift.
//
//  ---- Where it runs
//
//  NEVER on a thread that draws. `detect` is pure computation over a bitmap and
//  takes tens of milliseconds; the pane calls it on a background queue and
//  hands the result back to the main thread. See the note in Settings.swift
//  about the exporter that froze the wallpaper for 337ms a minute.

import AppKit
import CoreGraphics

/// Everything one screenshot yielded. Rectangles are FRACTIONS of the screen
/// with y increasing downward, which is the convention `WidgetRect` and the
/// simulation already use — so the result survives a resolution change and can
/// be stored straight into the config.
struct DetectedDesktop {
    var dock: CGRect?
    var widgets: [CGRect] = []
    /// Height of the menu bar as a fraction, if one was found.
    var menuBar: CGFloat?
    /// Pixel size of the image this came from.
    var pixelSize: CGSize = .zero
    /// Human-readable trace, shown in the pane and printed by the harness.
    var log: [String] = []

    var isEmpty: Bool { dock == nil && widgets.isEmpty }

    var summary: String {
        var parts: [String] = []
        if dock != nil { parts.append("the dock") }
        if !widgets.isEmpty { parts.append("\(widgets.count) widget\(widgets.count == 1 ? "" : "s")") }
        if menuBar != nil { parts.append("the menu bar") }
        guard !parts.isEmpty else { return "Nothing that looks like furniture." }
        return "Found " + parts.joined(separator: ", ") + "."
    }
}

enum FurnitureDetector {

    // MARK: - Tunables
    //
    // All in units of the WORKING image, which is a fixed width whatever the
    // screenshot's resolution — so a Retina capture and a 1x capture tune the
    // same way and one set of numbers serves both.

    /// Long edge of the working image. 480 keeps a 180pt widget about 42px
    /// across, which is plenty to fit a rectangle to, while a mosaic cell drops
    /// to 9px and falls straight out of the length test.
    static let workWidth = 480

    /// Shortest run of consecutive strong-gradient pixels that counts as an
    /// edge of something. ~5% of the width, i.e. four times the cell pitch.
    static var minSegment: Int { workWidth / 20 }

    // MARK: - Entry point

    /// Analyse a screenshot. Pure computation; safe on any background queue,
    /// and belongs on one.
    static func detect(_ image: CGImage) -> DetectedDesktop {
        var out = DetectedDesktop()
        out.pixelSize = CGSize(width: image.width, height: image.height)
        guard image.width > 32, image.height > 32 else {
            out.log.append("image too small")
            return out
        }
        guard let g = Grid(image: image) else {
            out.log.append("could not read the image's pixels")
            return out
        }
        out.log.append(String(format: "working image %dx%d from %dx%d, texture %.4f, threshold %.4f",
                              g.w, g.h, image.width, image.height, g.meanBusy, g.edgeThreshold))

        let hs = g.horizontalSegments()
        let vs = g.verticalSegments()
        out.log.append("edges: \(hs.count) horizontal (longest \(hs.map(\.length).max() ?? 0)), "
                     + "\(vs.count) vertical (longest \(vs.map(\.length).max() ?? 0)), "
                     + "minimum \(minSegment)")

        out.menuBar = g.menuBar(hs)
        out.dock = g.dock(hs, vs, log: &out.log)
        out.widgets = g.widgets(hs, vs, excluding: out.dock, menuBar: out.menuBar, log: &out.log)

        if let d = out.dock { out.log.append("dock \(pretty(d))") }
        for (i, w) in out.widgets.enumerated() { out.log.append("widget \(i + 1) \(pretty(w))") }
        if let m = out.menuBar { out.log.append(String(format: "menu bar %.1f%% tall", m * 100)) }
        return out
    }

    static func pretty(_ r: CGRect) -> String {
        String(format: "x %.1f%% y %.1f%% w %.1f%% h %.1f%%",
               r.minX * 100, r.minY * 100, r.width * 100, r.height * 100)
    }

    // MARK: - A straight edge

    /// A run of pixels along one row (or column) where the image steps from one
    /// tone to another. `sign` is which way it steps, which is what lets a top
    /// edge be told from a bottom edge.
    struct Seg {
        /// Row for a horizontal segment, column for a vertical one.
        var pos: Int
        var a: Int, b: Int
        var strength: Float
        var sign: Float
        var length: Int { b - a + 1 }
    }

    // MARK: - The working bitmap

    struct Grid {

        let w: Int, h: Int
        /// Luminance, 0...1, row-major, y down.
        var lum: [Float]
        /// |d/dy| and |d/dx| of luminance, same layout.
        var gy: [Float]
        var gx: [Float]
        /// Mean of |gy| + |gx|: how busy the picture is here. Used for the
        /// "calm inside" test.
        var busy: [Float]
        var meanBusy: Float = 0

        init?(image: CGImage) {
            // Locals throughout, and the properties assigned from them at the
            // end: a closure that touches `self.w` before every stored property
            // has a value does not compile.
            let scale = Double(FurnitureDetector.workWidth) / Double(image.width)
            let ww = FurnitureDetector.workWidth
            let hh = max(8, Int((Double(image.height) * scale).rounded()))
            w = ww
            h = hh
            let bytes = ww * 4
            var pixels = [UInt8](repeating: 0, count: bytes * hh)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let ok: Bool = pixels.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(
                    data: buf.baseAddress, width: ww, height: hh, bitsPerComponent: 8,
                    bytesPerRow: bytes, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.interpolationQuality = .medium
                // The screenshot's own origin is top-left; CGContext's is
                // bottom-left. Flip on the way in, so every index below is
                // y-down and matches WidgetRect without a second flip later.
                ctx.translateBy(x: 0, y: CGFloat(hh))
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(ww), height: CGFloat(hh)))
                return true
            }
            guard ok else { return nil }

            lum = [Float](repeating: 0, count: ww * hh)
            for i in 0..<(ww * hh) {
                let r = Float(pixels[i * 4]) / 255
                let g = Float(pixels[i * 4 + 1]) / 255
                let b = Float(pixels[i * 4 + 2]) / 255
                lum[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
            gy = [Float](repeating: 0, count: w * h)
            gx = [Float](repeating: 0, count: w * h)
            busy = [Float](repeating: 0, count: w * h)
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let dy = lum[i + w] - lum[i - w]
                    let dx = lum[i + 1] - lum[i - 1]
                    gy[i] = dy
                    gx[i] = dx
                    busy[i] = abs(dy) + abs(dx)
                }
            }
            meanBusy = busy.reduce(0, +) / Float(max(1, w * h))
        }

        // ---- thresholds
        //
        // Adaptive, because a screenshot of a dark mosaic and a screenshot of a
        // pale photograph have completely different gradient scales. A fixed
        // threshold tuned on one finds nothing at all on the other.

        var edgeThreshold: Float {
            max(0.03, min(0.25, meanBusy * 0.85))
        }

        /// How many weak pixels in a row may be tolerated before a straight edge
        /// is considered to have ended.
        ///
        /// This one number decided whether the detector worked at all. A widget
        /// border crosses a mosaic of light and dark cells, and where a dark
        /// cell sits behind a dark panel there is no step to find — so a real,
        /// unbroken border arrives as a dotted line. At a tolerance of 3 every
        /// border in the test screenshot shattered into sub-minimum fragments
        /// and NOTHING was found; at 8 they survive as one segment each.
        var gapTolerance: Int { max(4, FurnitureDetector.workWidth / 60) }

        func at(_ x: Int, _ y: Int) -> Int { y * w + x }

        // MARK: - Segment extraction

        /// Runs along rows where the image steps in y: the top and bottom edges
        /// of anything lying on the wallpaper.
        /// `signAgnostic` keeps a run going through a change of direction.
        ///
        /// Widgets need the sign held: it is what says "this line is the top of
        /// a slab" rather than "this line is a thing in the wallpaper". The DOCK
        /// needs it dropped: it is a pale translucent slab over a mosaic with
        /// both lighter and darker cells in it, so its top edge steps up in some
        /// places and down in others, and holding the sign shatters a 95%-wide
        /// dock into a dozen 7%-wide crumbs — which is exactly what it did.
        func horizontalSegments(signAgnostic: Bool = false) -> [Seg] {
            var found: [Seg] = []
            let t = edgeThreshold
            for y in 2..<(h - 2) {
                var x = 1
                while x < w - 1 {
                    let s = gy[at(x, y)]
                    guard abs(s) >= t else { x += 1; continue }
                    let sign: Float = s > 0 ? 1 : -1
                    var end = x
                    var sum: Float = 0
                    var gaps = 0
                    var probe = x
                    // A rounded corner and an icon crossing the border both put
                    // short holes in an otherwise straight edge, so tolerate a
                    // couple of weak pixels rather than cutting the run.
                    while probe < w - 1 {
                        let v = gy[at(probe, y)]
                        if abs(v) >= t && (signAgnostic || (v > 0 ? 1 : -1) == sign) {
                            end = probe; sum += abs(v); gaps = 0
                        } else {
                            gaps += 1
                            if gaps > gapTolerance { break }
                        }
                        probe += 1
                    }
                    let len = end - x + 1
                    if len >= FurnitureDetector.minSegment {
                        found.append(Seg(pos: y, a: x, b: end,
                                         strength: sum / Float(len), sign: sign))
                    }
                    x = max(end + 1, x + 1)
                }
            }
            return thin(found)
        }

        /// The same along columns: the left and right edges.
        func verticalSegments() -> [Seg] {
            var found: [Seg] = []
            let t = edgeThreshold
            for x in 2..<(w - 2) {
                var y = 1
                while y < h - 1 {
                    let s = gx[at(x, y)]
                    guard abs(s) >= t else { y += 1; continue }
                    let sign: Float = s > 0 ? 1 : -1
                    var end = y
                    var sum: Float = 0
                    var gaps = 0
                    var probe = y
                    while probe < h - 1 {
                        let v = gx[at(x, probe)]
                        if abs(v) >= t && (v > 0 ? 1 : -1) == sign {
                            end = probe; sum += abs(v); gaps = 0
                        } else {
                            gaps += 1
                            if gaps > gapTolerance { break }
                        }
                        probe += 1
                    }
                    let len = end - y + 1
                    if len >= FurnitureDetector.minSegment {
                        found.append(Seg(pos: x, a: y, b: end,
                                         strength: sum / Float(len), sign: sign))
                    }
                    y = max(end + 1, y + 1)
                }
            }
            return thin(found)
        }

        /// One edge is two or three pixels thick, so it is found on two or three
        /// consecutive rows. Keep the strongest and drop its neighbours,
        /// otherwise every rectangle is found nine times.
        private func thin(_ segs: [Seg]) -> [Seg] {
            let sorted = segs.sorted { $0.strength * Float($0.length) > $1.strength * Float($1.length) }
            var kept: [Seg] = []
            for s in sorted {
                let clash = kept.contains { k in
                    abs(k.pos - s.pos) <= 2 && k.sign == s.sign
                        && overlap(k.a, k.b, s.a, s.b) > 0.5
                }
                if !clash { kept.append(s) }
            }
            return kept
        }

        /// Overlap of two spans as a fraction of the shorter one.
        private func overlap(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Double {
            let lo = max(a0, b0), hi = min(a1, b1)
            guard hi > lo else { return 0 }
            return Double(hi - lo) / Double(max(1, min(a1 - a0, b1 - b0)))
        }

        // MARK: - The menu bar

        /// A single straight line right across the top of the screen. It is a
        /// strip rather than a slab: nothing bounds it above but the display
        /// edge, so only its underside is there to be found.
        func menuBar(_ hs: [Seg]) -> CGFloat? {
            let limit = max(4, Int(Double(h) * 0.075))
            let candidates = hs.filter {
                $0.pos <= limit && $0.length >= Int(Double(w) * 0.55)
            }
            // TOPMOST, not longest. The first long line down from the top of the
            // screen is the menu bar's underside; the longest is whichever of
            // the several lines up there happens to have run furthest, which in
            // the test screenshot was a row of widget tops 2% lower and gave a
            // menu bar nearly twice its real height.
            guard let best = candidates.min(by: { $0.pos < $1.pos }) else { return nil }
            return CGFloat(best.pos + 1) / CGFloat(h)
        }

        // MARK: - The dock

        /// A wide slab pinned to one edge of the screen.
        ///
        /// Not found by pairing two edges the way a widget is: the dock sits on
        /// the display edge, so the far side of it is off the screen and there
        /// is only ONE line to work with. That single line — long, near an edge,
        /// and the strongest thing down there — is the whole detection.
        func dock(_ hs: [Seg], _ vs: [Seg], log: inout [String]) -> CGRect? {
            // Bottom or top dock: a long horizontal edge low down with a CALM
            // slab under it.
            //
            // The calm test is not optional here. A mosaic wallpaper has a
            // cell boundary every 2.8% of the screen's height, and those run
            // the full width at full contrast — by pure edge strength or edge
            // length a wallpaper row beats the real dock, which is translucent
            // and soft-edged, and that is exactly what it did. What the dock
            // has and a wallpaper row does not is a blurred interior.
            let band = Int(Double(h) * 0.80)
            let runs = horizontalSegments(signAgnostic: true)
            var best: (rect: CGRect, score: Double)?
            for seg in runs where seg.pos >= band {
                // The top edge of a translucent dock breaks into pieces
                // wherever the wallpaper behind it happens to match its tone,
                // so take the union of everything on this line rather than the
                // longest single run of it.
                let (a, b) = span(runs, at: seg.pos)
                guard b - a >= Int(Double(w) * 0.35) else { continue }
                // The slab runs from this line to the BOTTOM OF THE SCREEN.
                // Not to whatever edge is found underneath: on this desktop the
                // next line down is the dock's own row of icons, and cutting
                // there produced a two-pixel sliver. The dock sits on the
                // display edge — that is what makes it the dock — so the edge
                // is the far side.
                let floor = max(6, h / 40)
                let y1 = h - 1
                guard y1 - seg.pos >= floor,
                      Double(y1 - seg.pos) / Double(h) < 0.16 else { continue }
                let px = CGRect(x: a, y: seg.pos, width: b - a, height: y1 - seg.pos)
                guard Double(px.width) / Double(max(1, px.height)) >= 2.5 else { continue }
                let calm = calmness(px)
                guard calm < 0.95 else { continue }
                // LOWEST wins, not widest or calmest.
                //
                // This was the one that took measuring to get right. A mosaic
                // wallpaper offers up smooth wide bands all the way down the
                // screen, and the band 7% above the dock in the test screenshot
                // was both wider and calmer than the dock itself — the dock is
                // full of icons, which are not calm. What the dock has that a
                // band of wallpaper does not is that nothing wide lies below
                // it. Everything lower than the dock's top edge is INSIDE the
                // dock, and the minimum slab height above already excludes
                // that. So: of everything wide, calm and low enough to be a
                // dock, take the bottom one. Scored width is only the tie-break.
                let s = Double(seg.pos) * 1000 + Double(b - a)
                if best == nil || s > best!.score { best = (frac(px), s) }
            }
            if let b = best { return b.rect }

            // A dock on the left or right edge is the same idea rotated. No
            // calm test: a side dock is narrow enough that its interior is
            // mostly icons, and there is far less down that edge to confuse it
            // with.
            let leftBand = Int(Double(w) * 0.22), rightBand = Int(Double(w) * 0.78)
            let tall = vs.filter {
                ($0.pos <= leftBand || $0.pos >= rightBand) && $0.length >= Int(Double(h) * 0.20)
            }
            if let side = tall.max(by: { $0.length < $1.length }) {
                let onLeft = side.pos <= leftBand
                let x0 = onLeft ? 0 : CGFloat(side.pos) / CGFloat(w)
                let x1 = onLeft ? CGFloat(side.pos + 1) / CGFloat(w) : 1
                let r = CGRect(x: x0, y: CGFloat(side.a) / CGFloat(h),
                               width: x1 - x0, height: CGFloat(side.length) / CGFloat(h))
                if r.width > 0.008 && r.height / r.width >= 2.5 { return r }
            }
            return nil
        }

        /// The full extent of a broken line: every run on this row, give or take
        /// a pixel, taken together.
        private func span(_ hs: [Seg], at pos: Int) -> (Int, Int) {
            var a = Int.max, b = Int.min
            for s in hs where abs(s.pos - pos) <= 1 {
                a = min(a, s.a); b = max(b, s.b)
            }
            return a <= b ? (a, b) : (0, 0)
        }

        private func score(_ s: Seg) -> Float { s.strength * Float(s.length) }

        // MARK: - Widgets

        /// Closed rounded rectangles lying on the wallpaper.
        ///
        /// Built by pairing a top edge with a bottom edge that steps the other
        /// way over the same span, then checking that the two sides are there
        /// too and that the wallpaper inside is calmer than the wallpaper
        /// around it.
        func widgets(_ hs: [Seg], _ vs: [Seg], excluding dock: CGRect?,
                     menuBar: CGFloat?, log: inout [String]) -> [CGRect] {

            let minSide = FurnitureDetector.minSegment            // ~24px
            let maxH = Int(Double(h) * 0.75)
            var scored: [(rect: CGRect, score: Double)] = []
            var pairs = 0
            // Why candidates died. Without this the only thing a failed
            // detection tells you is that it failed.
            var lost = ["sign": 0, "overlap": 0, "length": 0, "narrow": 0,
                        "aspect": 0, "sides": 0, "calm": 0]

            for (i, top) in hs.enumerated() {
                for j in hs.indices where j != i {
                    let bot = hs[j]
                    guard bot.pos > top.pos + minSide, bot.pos - top.pos <= maxH else { continue }
                    pairs += 1
                    // A slab is a tint: it steps one way going in and the other
                    // way coming out. Two edges that step the same way are two
                    // different things.
                    guard bot.sign != top.sign else { lost["sign"]! += 1; continue }
                    let ov = overlap(top.a, top.b, bot.a, bot.b)
                    guard ov > 0.75 else { lost["overlap"]! += 1; continue }
                    let lenRatio = Double(min(top.length, bot.length)) / Double(max(top.length, bot.length))
                    guard lenRatio > 0.6 else { lost["length"]! += 1; continue }

                    let x0 = max(top.a, bot.a), x1 = min(top.b, bot.b)
                    let y0 = top.pos, y1 = bot.pos
                    guard x1 - x0 >= minSide else { lost["narrow"]! += 1; continue }
                    let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)

                    // Aspect. Widgets are square, 2:1 or 1:2 on macOS; anything
                    // outside that band is a stripe of wallpaper or a window.
                    // macOS widgets come in three sizes — small is square,
                    // medium is 2:1 wide, large is square or 2:1 — so anything
                    // outside a narrow band around those is not one. This is
                    // what removes the tall thin rectangles a mosaic wallpaper
                    // offers up by the dozen: they run 0.2 to 0.4.
                    let aspect = Double(rect.width) / Double(max(1, rect.height))
                    guard aspect > 0.62, aspect < 2.9 else { lost["aspect"]! += 1; continue }

                    // Sides.
                    let left = sideSupport(vs, at: x0, from: y0, to: y1)
                    let right = sideSupport(vs, at: x1, from: y0, to: y1)
                    guard left > 0.3, right > 0.3 else { lost["sides"]! += 1; continue }

                    // Calm. The decisive test: a slab blurs and tints what is
                    // behind it, so the wallpaper's own texture is quieter
                    // inside it than just outside. A rectangle that is simply
                    // part of the wallpaper scores ~1 here and is dropped.
                    let calm = calmness(rect)
                    guard calm < 0.90 else { lost["calm"]! += 1; continue }

                    let strength = Double(top.strength + bot.strength) / 2
                    let s = strength * (left + right) / 2 * (1.6 - calm) * ov * lenRatio
                    scored.append((frac(rect), s))
                }
            }
            log.append("\(pairs) edge pairs, \(scored.count) candidates; "
                     + "rejected " + lost.sorted { $0.key < $1.key }
                        .filter { $0.value > 0 }
                        .map { "\($0.key) \($0.value)" }.joined(separator: ", "))

            // Strongest first, then drop anything overlapping something already
            // taken — the same slab is usually found two or three ways.
            scored.sort { $0.score > $1.score }

            // Two widgets stacked with a hairline between them also pair the top
            // of the upper with the bottom of the lower, giving one box over
            // both — and that merged box often scores higher than either real
            // one, because its edges are the same edges. So a candidate that
            // swallows another respectable candidate is dropped in favour of the
            // parts.
            let swallowed: Set<Int> = {
                var out: Set<Int> = []
                for (i, a) in scored.enumerated() {
                    for (j, b) in scored.enumerated() where i != j {
                        let inside = a.rect.insetBy(dx: -0.004, dy: -0.004).contains(b.rect)
                        let smaller = b.rect.width * b.rect.height < a.rect.width * a.rect.height * 0.8
                        if inside && smaller && b.score > a.score * 0.4 { out.insert(i); break }
                    }
                }
                return out
            }()

            var kept: [CGRect] = []
            for (i, c) in scored.enumerated() {
                if swallowed.contains(i) { continue }
                if let d = dock, c.rect.intersects(d.insetBy(dx: -0.01, dy: -0.01)) { continue }
                if let m = menuBar, c.rect.minY < m + 0.005 { continue }
                let clash = kept.contains { iou($0, c.rect) > 0.18 || $0.contains(centre(c.rect)) }
                if !clash { kept.append(c.rect) }
                if kept.count >= 24 { break }
            }
            return kept.sorted {
                $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
            }
        }

        /// How much of the span from `y0` to `y1` has a vertical edge sitting
        /// within a couple of pixels of column `x`. Rounded corners cost the
        /// top and bottom tenth, so this never reaches 1.
        private func sideSupport(_ vs: [Seg], at x: Int, from y0: Int, to y1: Int) -> Double {
            var rows = Set<Int>()
            for s in vs where abs(s.pos - x) <= 2 {
                let lo = max(y0, s.a), hi = min(y1, s.b)
                // A segment in the right column need not overlap the span at
                // all, and `lo...hi` with lo > hi is a trap, not an empty range.
                guard lo <= hi else { continue }
                for y in lo...hi { rows.insert(y) }
            }
            let covered = rows.count
            return Double(covered) / Double(max(1, y1 - y0))
        }

        /// Mean business inside the rectangle over mean business in a ring just
        /// outside it. Below 1 means the inside is smoother than its
        /// surroundings, which is what a translucent panel does to a wallpaper.
        private func calmness(_ r: CGRect) -> Double {
            let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
            var inside: Float = 0, insideN = 0
            let ix0 = min(w - 1, x0 + 3), ix1 = max(0, x1 - 3)
            let iy0 = min(h - 1, y0 + 3), iy1 = max(0, y1 - 3)
            guard ix1 > ix0, iy1 > iy0 else { return 1 }
            for y in stride(from: iy0, through: iy1, by: 2) {
                for x in stride(from: ix0, through: ix1, by: 2) {
                    inside += busy[at(x, y)]; insideN += 1
                }
            }
            var out: Float = 0, outN = 0
            let pad = 6
            let ox0 = max(1, x0 - pad), ox1 = min(w - 2, x1 + pad)
            let oy0 = max(1, y0 - pad), oy1 = min(h - 2, y1 + pad)
            for y in stride(from: oy0, through: oy1, by: 2) {
                for x in stride(from: ox0, through: ox1, by: 2) {
                    if x > x0 && x < x1 && y > y0 && y < y1 { continue }
                    out += busy[at(x, y)]; outN += 1
                }
            }
            guard insideN > 0, outN > 0 else { return 1 }
            let a = inside / Float(insideN), b = out / Float(outN)
            guard b > 1e-5 else { return 1 }
            return Double(a / b)
        }

        private func frac(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / CGFloat(w), y: r.minY / CGFloat(h),
                   width: r.width / CGFloat(w), height: r.height / CGFloat(h))
        }

        private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

        private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
            let ia = i.width * i.height
            return ia / (a.width * a.height + b.width * b.height - ia)
        }
    }
}
