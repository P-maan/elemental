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

    /// Analyse a screenshot the old way: edges, pairing and calmness, over the
    /// screenshot alone.
    ///
    /// Superseded by `detect(_:reference:cols:rows:)` and kept because it is
    /// the only thing that can run when no reference render is available — and
    /// because the harness measures the two against each other.
    static func detectByEdges(_ image: CGImage) -> DetectedDesktop {
        detect(image)
    }

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

// MARK: - Differencing against our own render
//
//  THE OBSERVATION THAT MAKES THIS WORK: Elemental *is* the wallpaper, so it
//  knows exactly what it drew. Render the same scene at the screenshot's size
//  and the two pictures agree everywhere the user has put nothing — and
//  disagree, in a very specific way, everywhere they have.
//
//  The specific way matters. The dock and the widgets are FROSTED: they do not
//  replace the wallpaper, they blur it. So the signal is not "the colour
//  changed" — the sky drifts between the capture and the compare and that alone
//  changes every colour on the screen. The signal is that OUR RENDER HAS HARD
//  MOSAIC CELL EDGES WHERE THE SCREENSHOT HAS NONE. We know where every one of
//  those edges is, to the pixel, because we chose the grid. Measuring the
//  contrast that survives across each known grout line is therefore a direct
//  question about frosting and nothing else, and it is indifferent to:
//
//    * the sky drifting (a smooth change either side of a grout line leaves the
//      step across it intact),
//    * the widget's own content (text and charts put edges in the middle of
//      cells, not along the grid),
//    * desktop icons (an icon ADDS structure, it does not take it away),
//    * and above all the mosaic's own rectangles, which is the entire class of
//      false positive the edge detector could never get rid of. A grout line is
//      not evidence of furniture here. Its DISAPPEARANCE is.
//
//  ---- Pixel extents, not cells
//
//  Furniture does not land on cell boundaries and must not be reported as
//  though it did: the engine subdivides partial edge cells, and that is exactly
//  what the subdivision is for. So the grid only ever finds a coarse mask; the
//  four edges of every rectangle are then refined against the per-pixel
//  difference field, which steps sharply at the panel's real border.

extension FurnitureDetector {

    /// Long edge of the working image for the differencing path. Larger than
    /// the edge detector's 480: this one is measuring across individual grout
    /// lines, so the cell pitch has to survive the downscale. At 720 across a
    /// 54-row grid a cell is still ~8.5px, which is four resolvable pixels
    /// either side of every boundary.
    static let diffWidth = 720

    /// Analyse a screenshot against our own render of the same scene.
    ///
    /// `cols`/`rows` are the mosaic's grid — ask `SceneSimulation.gridGeometry`
    /// for them so there is one source of truth about where the grout is.
    /// Falls back to the edge detector when there is no reference to compare
    /// against, which is what happens if the renderer could not be built.
    static func detect(_ image: CGImage, reference: CGImage?,
                       cols: Int, rows: Int) -> DetectedDesktop {
        guard let reference, cols > 3, rows > 3,
              let d = DiffGrid(shot: image, reference: reference, cols: cols, rows: rows)
        else {
            var out = detect(image)
            out.log.insert("no reference render — fell back to edge detection", at: 0)
            return out
        }
        let diffed = d.run(pixelSize: CGSize(width: image.width, height: image.height))

        // NEVER WORSE THAN WHAT IT REPLACED.
        //
        // The differencing pass is the better instrument when the reference is
        // contemporaneous with the screenshot, which is the case it is built
        // for: the pane renders it moments after the user hands the picture in.
        // It degrades when it is not — a screenshot saved an hour ago and
        // compared against tonight's sky has rain in one and not the other, and
        // the structure difference that finds a widget also finds every streak
        // that moved. Measured on a pair ten minutes apart it fragments into
        // hundreds of specks and finds nothing.
        //
        // So it has to be able to say it failed. Finding neither a dock nor a
        // pair of widgets, or finding a great many small ones, is that
        // admission, and the edge detector — which needs no reference and is
        // therefore immune to this whole failure — gets the screenshot instead.
        let credible = (diffed.dock != nil || diffed.widgets.count >= 2)
                    && diffed.widgets.count <= 16
        if credible { return diffed }
        var out = detect(image)
        out.log.insert("differencing found "
            + "\(diffed.widgets.count) widgets and \(diffed.dock == nil ? "no" : "a") dock — "
            + "not credible, so this is the edge detector's answer", at: 0)
        out.log.append(contentsOf: diffed.log.map { "  (differencing) " + $0 })
        return out
    }

    // MARK: - The differenced pair

    struct DiffGrid {

        let w: Int, h: Int
        let cols: Int, rows: Int
        /// Luminance of the screenshot and of our render, 0...1, y down.
        var S: [Float]
        var R: [Float]

        /// Per pixel: local gradient magnitude of each picture. THE difference
        /// field — not |S - R|, which is a colour difference and therefore
        /// measures the sky drifting between the capture and the compare far
        /// more loudly than it measures a widget. Structure is what frosting
        /// takes away and structure is what a drifting sky leaves alone.
        var gS: [Float]
        var gR: [Float]

        /// Per cell: how much of our grout contrast the screenshot has lost.
        var loss: [Float]
        /// Per cell: how much of our INTERIOR structure it has lost, 0...1.
        var dm: [Float]
        /// Per cell: whether our own render had a grout edge worth measuring.
        var lit: [Bool]
        /// Per cell: how much edge energy the screenshot has that we do not.
        /// Positive means something was drawn ON the wallpaper rather than
        /// blurred over it — an icon, a filename, a chart.
        var added: [Float]

        var dmFloor: Float = 0

        init?(shot: CGImage, reference: CGImage, cols: Int, rows: Int) {
            let ww = FurnitureDetector.diffWidth
            let hh = max(8, Int((Double(shot.height) * Double(ww) / Double(shot.width)).rounded()))
            guard let a = FurnitureDetector.luma(shot, ww, hh),
                  let b = FurnitureDetector.luma(reference, ww, hh) else { return nil }
            w = ww; h = hh
            self.cols = cols; self.rows = rows
            S = a; R = b
            gS = FurnitureDetector.gradient(a, ww, hh)
            gR = FurnitureDetector.gradient(b, ww, hh)
            loss  = [Float](repeating: 0, count: cols * rows)
            dm    = [Float](repeating: 0, count: cols * rows)
            lit   = [Bool](repeating: false, count: cols * rows)
            added = [Float](repeating: 0, count: cols * rows)
            measure()
        }

        // ---- grid geometry, in working pixels

        @inline(__always) func bx(_ i: Int) -> Float { Float(i) * Float(w) / Float(cols) }
        @inline(__always) func by(_ j: Int) -> Float { Float(j) * Float(h) / Float(rows) }

        var pitchX: Float { Float(w) / Float(cols) }
        var pitchY: Float { Float(h) / Float(rows) }

        /// Contrast across a vertical grout line at working column `px`, over
        /// the rows `y0..<y1`. A window of three columns rather than one,
        /// because the downscale puts the line somewhere inside a pixel and a
        /// single-column probe lands beside it as often as on it.
        private func vEdge(_ img: [Float], _ px: Int, _ y0: Int, _ y1: Int) -> Float {
            guard px >= 2, px < w - 2, y1 > y0 else { return 0 }
            var sum: Float = 0
            var n = 0
            for y in y0..<y1 {
                let row = y * w
                var best: Float = 0
                for dx in -1...1 {
                    best = max(best, abs(img[row + px + dx + 1] - img[row + px + dx - 1]))
                }
                sum += best; n += 1
            }
            return n > 0 ? sum / Float(n) : 0
        }

        private func hEdge(_ img: [Float], _ py: Int, _ x0: Int, _ x1: Int) -> Float {
            guard py >= 2, py < h - 2, x1 > x0 else { return 0 }
            var sum: Float = 0
            var n = 0
            for x in x0..<x1 {
                var best: Float = 0
                for dy in -1...1 {
                    let a = img[(py + dy + 1) * w + x], b = img[(py + dy - 1) * w + x]
                    best = max(best, abs(a - b))
                }
                sum += best; n += 1
            }
            return n > 0 ? sum / Float(n) : 0
        }

        /// Fill `loss`, `dm` and `lit`.
        private mutating func measure() {
            // Our own grout contrast is what sets the scale. On a bright day it
            // is large; on a clear night the whole wall is nearly black and the
            // step across a grout line is a couple of levels. A fixed floor
            // tuned on one is meaningless on the other, so the floor is a
            // fraction of what THIS render actually has.
            var refEdges: [Float] = []
            refEdges.reserveCapacity(cols * rows)

            var vS = [Float](repeating: 0, count: cols * rows)
            var vR = [Float](repeating: 0, count: cols * rows)
            var busyR = [Float](repeating: 0, count: cols * rows)

            for j in 0..<rows {
                let y0 = max(1, Int(by(j).rounded()) + 1)
                let y1 = min(h - 1, Int(by(j + 1).rounded()) - 1)
                for i in 0..<cols {
                    let x0 = max(1, Int(bx(i).rounded()) + 1)
                    let x1 = min(w - 1, Int(bx(i + 1).rounded()) - 1)
                    guard x1 > x0, y1 > y0 else { continue }

                    // Use the cell's own left and top boundary; the outermost
                    // rank has only the far one to work with.
                    let vx = i > 0 ? Int(bx(i).rounded()) : Int(bx(i + 1).rounded())
                    let hy = j > 0 ? Int(by(j).rounded()) : Int(by(j + 1).rounded())
                    let eSv = vEdge(S, vx, y0, y1), eRv = vEdge(R, vx, y0, y1)
                    let eSh = hEdge(S, hy, x0, x1), eRh = hEdge(R, hy, x0, x1)
                    let eS = (eSv + eSh) * 0.5, eR = (eRv + eRh) * 0.5

                    let k = j * cols + i
                    vS[k] = eS; vR[k] = eR
                    refEdges.append(eR)

                    // Interior structure, in both pictures. The cell's whole
                    // area, not just its border: a frosted panel flattens
                    // everything under it, and the grout lines are only the
                    // part of that we happen to know the position of.
                    var bS: Float = 0, bR: Float = 0
                    var n = 0
                    for y in stride(from: y0, to: y1, by: 2) {
                        let row = y * w
                        for x in stride(from: x0, to: x1, by: 2) {
                            bS += gS[row + x]; bR += gR[row + x]; n += 1
                        }
                    }
                    if n > 0 {
                        bS /= Float(n); bR /= Float(n)
                        busyR[k] = bR
                        // Normalised, so it is a FRACTION of the structure that
                        // was there rather than an absolute amount — the dark
                        // corners of a night frame have very little of it and
                        // still lose all of it under a widget.
                        dm[k] = max(0, bR - bS) / max(bR, 0.004)
                        added[k] = max(0, bS - bR)
                    }
                }
            }

            // A cell is worth judging on STRUCTURE when our render put a real
            // step across its boundary. At night, in the dark corners of the
            // frame, the grout is a level or two of 255 and the ratio of two
            // such numbers is quantisation noise, not evidence — those cells are
            // marked unlit and judged a different way below.
            refEdges.sort()
            let medEdge = refEdges.isEmpty ? 0 : refEdges[refEdges.count / 2]
            let floorE = max(0.012, medEdge * 0.55)

            for k in 0..<(cols * rows) {
                lit[k] = vR[k] >= floorE
                loss[k] = lit[k] ? max(0, 1 - vS[k] / max(vR[k], 1e-5)) : 0
                // A cell where our own render has almost no structure at all
                // cannot report having lost any: the ratio is quantisation
                // noise. Say nothing rather than something random.
                if busyR[k] < 0.006 { dm[k] = 0; added[k] = 0 }
            }

            // Everything above is a FRACTION of what was there, so the bar is
            // an absolute one and the median only guards against a reference
            // that is systematically softer than the screenshot — a resample,
            // a colour profile, a frame of motion blur.
            var sorted = dm.sorted()
            let med = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            dmFloor = min(0.60, max(0.32, med + 0.22))
        }

        // MARK: - Mask, components, rectangles

        /// Cells that are behind something frosted.
        ///
        /// Two tiers, because the frame has two kinds of place in it and one
        /// rule cannot serve both:
        ///
        ///   LIT — our render has real grout contrast here, so the question can
        ///     be asked directly: did the screenshot keep it? A frosted panel
        ///     loses most of it. An icon keeps it and adds more.
        ///   UNLIT — our render is nearly flat here (a dark corner at night,
        ///     the bottom of the frame), so there is no contrast to lose and
        ///     the ratio is noise. All that is left is that the picture changed
        ///     a great deal AND nothing sharp was drawn on it. That second half
        ///     is what keeps the icon field out: an icon changes the pixels and
        ///     ADDS structure, and frosting never does the latter.
        func mask() -> [Bool] {
            var m = [Bool](repeating: false, count: cols * rows)
            for k in 0..<(cols * rows) {
                let changed = dm[k] > dmFloor
                guard changed else { continue }
                m[k] = lit[k] ? (loss[k] > 0.30 || dm[k] > dmFloor + 0.20)
                              : (dm[k] > dmFloor + 0.15 && added[k] < 0.010)
            }
            // Close single-cell holes: a widget with a hard graphic in it can
            // keep one cell's worth of contrast and punch a pinhole in an
            // otherwise solid slab.
            var out = m
            for j in 1..<(rows - 1) {
                for i in 1..<(cols - 1) {
                    let k = j * cols + i
                    guard !m[k] else { continue }
                    let n = (m[k - 1] ? 1 : 0) + (m[k + 1] ? 1 : 0)
                          + (m[k - cols] ? 1 : 0) + (m[k + cols] ? 1 : 0)
                    if n >= 3 { out[k] = true }
                }
            }
            return out
        }

        /// Four-connected components of the mask, as cell-space boxes.
        func components(_ m: [Bool]) -> [(cells: [Int], box: (Int, Int, Int, Int))] {
            var seen = [Bool](repeating: false, count: cols * rows)
            var out: [(cells: [Int], box: (Int, Int, Int, Int))] = []
            var stack: [Int] = []
            for start in 0..<(cols * rows) where m[start] && !seen[start] {
                stack.removeAll(keepingCapacity: true)
                stack.append(start); seen[start] = true
                var cells: [Int] = []
                var i0 = cols, i1 = 0, j0 = rows, j1 = 0
                while let k = stack.popLast() {
                    cells.append(k)
                    let i = k % cols, j = k / cols
                    i0 = min(i0, i); i1 = max(i1, i); j0 = min(j0, j); j1 = max(j1, j)
                    if i > 0, m[k - 1], !seen[k - 1] { seen[k - 1] = true; stack.append(k - 1) }
                    if i < cols - 1, m[k + 1], !seen[k + 1] { seen[k + 1] = true; stack.append(k + 1) }
                    if j > 0, m[k - cols], !seen[k - cols] { seen[k - cols] = true; stack.append(k - cols) }
                    if j < rows - 1, m[k + cols], !seen[k + cols] { seen[k + cols] = true; stack.append(k + cols) }
                }
                out.append((cells, (i0, j0, i1, j1)))
            }
            return out
        }

        // MARK: - Pixel-accurate edges
        //
        // The mask is cell-resolution and the furniture is not, so every box
        // that survives has its four sides walked back onto the real border.
        // The difference field is what carries that border: inside a frosted
        // panel it is high and roughly level, outside it collapses to the sky's
        // drift, and the step between the two is one or two pixels wide.

        /// Mean structure LOST down a column, over the rows `y0..<y1`. The same
        /// drift-tolerant quantity the mask is built on, at pixel resolution:
        /// high inside a frosted panel, near zero on bare wallpaper however far
        /// the sky has moved on, and it steps within a pixel or two at the
        /// panel's border — which is what makes a pixel-accurate edge possible
        /// at all.
        private func colDiff(_ x: Int, _ y0: Int, _ y1: Int) -> Float {
            guard x >= 0, x < w, y1 > y0 else { return 0 }
            var s: Float = 0
            for y in y0..<y1 { s += max(0, gR[y * w + x] - gS[y * w + x]) }
            return s / Float(y1 - y0)
        }

        private func rowDiff(_ y: Int, _ x0: Int, _ x1: Int) -> Float {
            guard y >= 0, y < h, x1 > x0 else { return 0 }
            let row = y * w
            var s: Float = 0
            for x in x0..<x1 { s += max(0, gR[row + x] - gS[row + x]) }
            return s / Float(x1 - x0)
        }

        /// Walk outward from `from` in `step`s while the profile stays above
        /// half the inside level, and return the last position that did.
        /// `probe` gives the profile value at a position.
        private func walk(from: Int, step: Int, limit: Int,
                          inside: Float, outside: Float,
                          probe: (Int) -> Float) -> Int {
            let half = (inside + outside) * 0.5
            var best = from
            var p = from
            var slack = 0
            while p != limit {
                let next = p + step
                if next < 0 || next >= max(w, h) { break }
                let v = probe(next)
                if v >= half { best = next; slack = 0 }
                else {
                    slack += 1
                    // One pixel of noise must not end the walk, but three
                    // consecutive pixels below half is the border.
                    if slack >= 3 { break }
                }
                p = next
            }
            return best
        }

        /// Turn a cell box into a pixel-accurate rectangle in working pixels.
        func refine(_ box: (Int, Int, Int, Int)) -> CGRect {
            let (i0, j0, i1, j1) = box
            var x0 = Int(bx(i0).rounded()), x1 = Int(bx(i1 + 1).rounded())
            var y0 = Int(by(j0).rounded()), y1 = Int(by(j1 + 1).rounded())
            x0 = max(0, min(w - 2, x0)); x1 = max(x0 + 1, min(w - 1, x1))
            y0 = max(0, min(h - 2, y0)); y1 = max(y0 + 1, min(h - 1, y1))

            // Sample the interior over the middle 60% of the far axis, so a
            // rounded corner or a neighbour abutting one end cannot set the
            // level for the whole side.
            let iy0 = y0 + (y1 - y0) * 2 / 10, iy1 = y1 - (y1 - y0) * 2 / 10
            let ix0 = x0 + (x1 - x0) * 2 / 10, ix1 = x1 - (x1 - x0) * 2 / 10
            let reachX = Int(pitchX.rounded()) + 2
            let reachY = Int(pitchY.rounded()) + 2

            func level(_ vals: [Float]) -> Float {
                guard !vals.isEmpty else { return 0 }
                let s = vals.sorted()
                return s[s.count / 2]
            }

            // Inside level, measured a little way in from every side.
            let insideV = level((ix0..<ix1).map { colDiff($0, iy0, iy1) })
            let insideH = level((iy0..<iy1).map { rowDiff($0, ix0, ix1) })

            // Outside level, measured a little way beyond every side.
            let outL = level(((x0 - reachX)..<max(x0 - reachX + 1, x0 - 2)).map { colDiff($0, iy0, iy1) })
            let outR = level((min(w - 1, x1 + 2)..<min(w, x1 + reachX)).map { colDiff($0, iy0, iy1) })
            let outT = level(((y0 - reachY)..<max(y0 - reachY + 1, y0 - 2)).map { rowDiff($0, ix0, ix1) })
            let outB = level((min(h - 1, y1 + 2)..<min(h, y1 + reachY)).map { rowDiff($0, ix0, ix1) })

            let nx0 = walk(from: max(1, x0 + 1), step: -1, limit: max(0, x0 - reachX),
                           inside: insideV, outside: outL) { colDiff($0, iy0, iy1) }
            let nx1 = walk(from: min(w - 2, x1 - 1), step: 1, limit: min(w - 1, x1 + reachX),
                           inside: insideV, outside: outR) { colDiff($0, iy0, iy1) }
            let ny0 = walk(from: max(1, y0 + 1), step: -1, limit: max(0, y0 - reachY),
                           inside: insideH, outside: outT) { rowDiff($0, ix0, ix1) }
            let ny1 = walk(from: min(h - 2, y1 - 1), step: 1, limit: min(h - 1, y1 + reachY),
                           inside: insideH, outside: outB) { rowDiff($0, ix0, ix1) }

            return CGRect(x: CGFloat(nx0), y: CGFloat(ny0),
                          width: CGFloat(max(1, nx1 - nx0)), height: CGFloat(max(1, ny1 - ny0)))
        }

        // MARK: - Splitting a slab into the widgets that make it up
        //
        // macOS stacks widgets edge to edge: on the test desktop the seven of
        // them form one contiguous frosted column with no wallpaper between
        // them at all, so the mask sees one slab. What separates them is a
        // hairline in the SCREENSHOT — each panel has its own border. Looking
        // for that inside a region already known to be furniture is safe in a
        // way that looking for it over the whole wallpaper never was: the
        // mosaic's own rectangles cannot get in, because the mosaic is not
        // here.

        /// Rows (or columns) inside `r` where the screenshot has a straight
        /// line right across it. Working-pixel coordinates.
        private func seams(in r: CGRect, horizontal: Bool) -> [Int] {
            let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
            let n = horizontal ? (y1 - y0) : (x1 - x0)
            guard n > 12 else { return [] }
            var profile = [Float](repeating: 0, count: n)
            for t in 0..<n {
                var s: Float = 0
                var m = 0
                if horizontal {
                    let y = y0 + t
                    guard y > 1, y < h - 2 else { continue }
                    for x in x0..<x1 {
                        s += abs(S[(y + 1) * w + x] - S[(y - 1) * w + x]); m += 1
                    }
                } else {
                    let x = x0 + t
                    guard x > 1, x < w - 2 else { continue }
                    for y in y0..<y1 {
                        s += abs(S[y * w + x + 1] - S[y * w + x - 1]); m += 1
                    }
                }
                profile[t] = m > 0 ? s / Float(m) : 0
            }
            let sorted = profile.sorted()
            let med = sorted[sorted.count / 2]
            let top = sorted[Int(Double(sorted.count) * 0.98)]
            guard top > med * 2.2, top > 0.012 else { return [] }
            let cut = med + (top - med) * 0.55
            // Peaks only, and never within a widget's minimum size of the ends
            // or of each other — a border is one line, and a chart inside a
            // widget can put a run of strong rows anywhere.
            let guardBand = max(6, Int((horizontal ? pitchY : pitchX) * 2.5))
            // A slab has to be wider than two guard bands before there is any
            // room left in the middle for a seam. Without this the range below
            // is inverted and Swift traps — which is a crash, not a miss.
            guard n > guardBand * 2 + 2 else { return [] }
            var picks: [Int] = []
            for t in guardBand..<(n - guardBand) where profile[t] >= cut {
                if profile[t] < profile[t - 1] || profile[t] < profile[t + 1] { continue }
                if let last = picks.last, t - last < guardBand { 
                    if profile[t] > profile[last] { picks[picks.count - 1] = t }
                    continue
                }
                picks.append(t)
            }
            return picks.map { (horizontal ? y0 : x0) + $0 }
        }

        /// Cut one slab into the panels it is made of, recursively, alternating
        /// axes. Returns working-pixel rectangles.
        func split(_ r: CGRect, depth: Int = 0) -> [CGRect] {
            guard depth < 4, r.width > 12, r.height > 12 else { return [r] }
            for horizontal in [true, false] {
                let cuts = seams(in: r, horizontal: horizontal)
                guard !cuts.isEmpty else { continue }
                var parts: [CGRect] = []
                var prev = horizontal ? Int(r.minY) : Int(r.minX)
                let end = horizontal ? Int(r.maxY) : Int(r.maxX)
                for c in cuts + [end] {
                    guard c - prev > 6 else { prev = c; continue }
                    let piece = horizontal
                        ? CGRect(x: r.minX, y: CGFloat(prev), width: r.width, height: CGFloat(c - prev))
                        : CGRect(x: CGFloat(prev), y: r.minY, width: CGFloat(c - prev), height: r.height)
                    parts.append(piece)
                    prev = c
                }
                guard parts.count > 1 else { continue }
                return parts.flatMap { split($0, depth: depth + 1) }
            }
            return [r]
        }

        // MARK: - The dock
        //
        // Its own pass, for the same reason the edge detector needed one: the
        // dock is not a slab of frosting over wallpaper, it is a slab of
        // frosting with two dozen high-contrast icons sitting ON it. The
        // structure test therefore says "something was added here", which is
        // true and which is exactly wrong — so the dock is found by what makes
        // it the dock instead: it is the band along the bottom edge of the
        // display where the picture stops agreeing with ours.
        func dockBand() -> CGRect? {
            var rowsHit: [Int] = []
            var j = rows - 1
            let need = Int(Double(cols) * 0.20)
            while j >= 0 {
                var n = 0
                for i in 0..<cols where dm[j * cols + i] > dmFloor { n += 1 }
                if n < need { break }
                rowsHit.append(j)
                j -= 1
            }
            guard let top = rowsHit.last, rowsHit.count >= 1 else { return nil }
            // A dock is shallow. Anything deeper is a window, or a wallpaper
            // that simply disagrees down there, and taking it would swallow
            // half the screen.
            guard Double(rowsHit.count) / Double(rows) < 0.20 else { return nil }

            // Horizontal extent: the columns that are actually part of it,
            // taken over the whole band rather than any single row — the dock's
            // separator gaps leave individual rows short.
            var lo = cols, hi = -1
            for i in 0..<cols {
                var n = 0
                for r in rowsHit where dm[r * cols + i] > dmFloor { n += 1 }
                if n >= max(1, rowsHit.count / 3) { lo = min(lo, i); hi = max(hi, i) }
            }
            guard hi >= lo, hi - lo >= Int(Double(cols) * 0.15) else { return nil }
            return refine((lo, top, hi, rows - 1))
        }

        // MARK: - Run

        func run(pixelSize: CGSize) -> DetectedDesktop {
            var out = DetectedDesktop()
            out.pixelSize = pixelSize
            out.log.append(String(format:
                "differencing %dx%d against our own render, grid %dx%d, "
              + "cell %.1fx%.1f px, background |Δ| floor %.4f",
                w, h, cols, rows, pitchX, pitchY, dmFloor))

            @inline(__always)
            func toFrac(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX / CGFloat(w), y: r.minY / CGFloat(h),
                       width: r.width / CGFloat(w), height: r.height / CGFloat(h))
            }

            // The dock first, so its rows can be kept out of everything else.
            var dockTopPx = CGFloat(h)
            if let band = dockBand() {
                out.dock = toFrac(band)
                dockTopPx = band.minY
                out.log.append("dock \(FurnitureDetector.pretty(out.dock!)) (bottom band)")
            }

            let m = mask()
            let comps = components(m)
            let masked = m.filter { $0 }.count
            out.log.append("\(masked) of \(cols * rows) cells lost their grout "
                         + "(\(comps.count) connected regions)")

            // A widget is 180pt on its short side, which is a third of the
            // screen height's tenth — four cells at any sane row count. Below
            // that it is a desktop icon, and an icon is not furniture.
            let minCells = 3
            var kept: [(kind: String, rect: CGRect)] = []

            for c in comps {
                let (i0, j0, i1, j1) = c.box
                let cw = i1 - i0 + 1, ch = j1 - j0 + 1
                guard c.cells.count >= 8, cw >= minCells, ch >= 2 else { continue }
                // Solidity: a real slab fills its box. A scatter of unrelated
                // cells that happen to touch does not.
                let fill = Double(c.cells.count) / Double(cw * ch)
                guard fill > 0.55 else { continue }

                let px = refine(c.box)
                let r = toFrac(px)

                // Anything inside the dock's band is the dock.
                if px.midY >= dockTopPx { continue }

                // The menu bar is the strip along the very top: it is bounded
                // above by the display edge and by nothing else.
                if r.minY < 0.012 && r.width > 0.5 && r.height < 0.09 {
                    out.menuBar = r.maxY
                    out.log.append(String(format: "menu bar %.2f%% tall", r.maxY * 100))
                    continue
                }
                // Everything else is one or more widgets stacked together.
                for piece in split(px) {
                    let pr = toFrac(piece)
                    guard pr.width > 0.02, pr.height > 0.02 else { continue }
                    out.widgets.append(pr)
                    kept.append(("widget", pr))
                }
            }

            out.widgets.sort { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
            for (i, wr) in out.widgets.enumerated() {
                out.log.append("widget \(i + 1) \(FurnitureDetector.pretty(wr))")
            }
            return out
        }
    }

    // MARK: - Shared rasteriser

    /// Draw `image` into a `w` x `h` luminance buffer, y down.
    static func luma(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        let bytes = w * 4
        var pixels = [UInt8](repeating: 0, count: bytes * h)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok: Bool = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bytes, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard ok else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            out[i] = 0.2126 * Float(pixels[i * 4]) / 255
                   + 0.7152 * Float(pixels[i * 4 + 1]) / 255
                   + 0.0722 * Float(pixels[i * 4 + 2]) / 255
        }
        return out
    }
}

extension FurnitureDetector {
    /// |d/dx| + |d/dy| of a luminance buffer. The one measurement everything in
    /// the differencing detector is built on.
    static func gradient(_ img: [Float], _ w: Int, _ h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        guard w > 2, h > 2 else { return g }
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                g[i] = abs(img[i + 1] - img[i - 1]) + abs(img[i + w] - img[i - w])
            }
        }
        return g
    }
}
