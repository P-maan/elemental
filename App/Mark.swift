//  Mark.swift — the "El" logotype, as geometry.
//
//  The status item used to be `circle.grid.3x3.fill`, a stand-in SF Symbol
//  chosen because it looks like a mosaic. This draws the real mark instead.
//
//  ---- Why the path is in here rather than the SVG being loaded
//
//  `NSImage(contentsOfFile:)` DOES read Custom/El.svg on macOS 27 — it comes
//  back as a vector `_NSSVGImageRep` at 54x41 and rasterises correctly at menu
//  bar size, which was worth checking before writing any of this. It was not
//  worth depending on:
//
//    * it needs the .svg copied into the bundle, so the menu-bar item — the
//      only way into Settings — acquires a runtime file read and a resource
//      that can go missing from a hand-assembled bundle. Every other visual in
//      this project is compiled in for exactly that reason.
//    * `_NSSVGImageRep` is not API. The support arrived without documentation
//      and there is no promised behaviour to rely on for hinting, for the size
//      an SVG with no width attribute reports, or for template tinting.
//    * the whole file is 187 bytes of M/H/V/Z with no curves in it at all.
//
//  So the path data is embedded verbatim from Custom/El.svg and turned into an
//  NSBezierPath. If the artwork changes, paste the new `d` attribute and its
//  viewBox in below — nothing else here knows what the shape is.
//
//  ---- Template images
//
//  The mark is drawn as flat opaque black on transparent, and the image is
//  marked `isTemplate`. AppKit then ignores the colour entirely and uses only
//  the coverage: black in a light menu bar, white in a dark one, and correctly
//  contrasted when the bar is translucent over a bright wallpaper — which is
//  the normal case for a wallpaper app and the whole reason this matters.

import AppKit

enum Mark {

    /// The `d` attribute of Custom/El.svg, verbatim.
    static let elPath = """
    M2.20463e-05 40.4561V31.9281H2.60002V8.52805H2.20463e-05V5.17368e-05H35.1V15.7041H23.452V8.5\
    2805H17.16V16.7441H21.736V22.6721H17.16V31.9281H23.452V23.7121H35.1V40.4561H2.20463e-05ZM36.\
    9663 40.5081V31.9281H39.2543V8.52805H36.9663V5.17368e-05H51.2143V31.9281H53.5023V40.5081H36.9\
    663Z
    """

    /// Its viewBox, which is what the coordinates above are in.
    static let elBox = NSSize(width: 54, height: 41)

    // MARK: - The menu bar item

    /// Standard status-item metrics. The menu bar gives an item an 18pt-tall
    /// box; a glyph that fills it edge to edge reads as oversized next to the
    /// system's own items, which sit at about 15pt inside the same box. So the
    /// image IS 18pt tall and the mark inside it is 15, centred — the padding
    /// is part of the icon, which is also what stops a tall glyph from being
    /// clipped by a menu bar that is a point shorter than expected.
    static let menuBarBoxHeight: CGFloat = 18
    static let menuBarMarkHeight: CGFloat = 15

    /// The "El" mark as a template image, ready for `NSStatusItem.button`.
    ///
    /// Built with `NSImage(size:flipped:drawingHandler:)`, so it is re-drawn
    /// from the path at whatever backing scale it is asked for rather than
    /// rasterised once at 1x and scaled up. That is what keeps the vertical
    /// stems crisp on a 2x display instead of half-covering a device pixel.
    static func menuBarImage() -> NSImage {
        let h = menuBarBoxHeight
        let markH = menuBarMarkHeight
        let markW = (elBox.width / elBox.height) * markH
        // A point of air either side as well, for the same reason as the
        // vertical padding: the glyph is a solid slab and butting it against
        // the edge of its own box makes it crowd whatever is next to it in the
        // bar. `variableLength` adds its own padding on top of this.
        let size = NSSize(width: (markW + 2).rounded(.up), height: h)

        let img = NSImage(size: size, flipped: false) { _ in
            let box = NSRect(x: 1, y: ((h - markH) / 2).rounded(),
                             width: markW, height: markH)
            NSColor.black.setFill()
            path(elPath, viewBox: elBox, fitting: box).fill()
            return true
        }
        // Everything about how this is coloured is now AppKit's business.
        img.isTemplate = true
        img.accessibilityDescription = "Elemental"
        return img
    }

    // MARK: - SVG path data -> NSBezierPath

    /// Parse an SVG `d` attribute and scale it to fit `rect`, preserving the
    /// aspect ratio and flipping Y — SVG counts down the page, AppKit counts up
    /// it, and forgetting that draws the mark upside down.
    ///
    /// Supports M, L, H, V, C, Q, Z in both absolute and relative forms, which
    /// covers every path in Custom/ (they use M, L, H, V, C and Z, all
    /// absolute) with room for artwork that is redrawn later. An unrecognised
    /// command stops the parse rather than guessing: half a glyph is a visible
    /// failure, and a silently wrong one is not.
    static func path(_ d: String, viewBox: NSSize, fitting rect: NSRect) -> NSBezierPath {
        let raw = parse(d)
        let s = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let ox = rect.minX + (rect.width - viewBox.width * s) / 2
        let oy = rect.minY + (rect.height - viewBox.height * s) / 2

        // `append` composes the new matrix AFTER the ones already in `t`, so
        // this reads in application order: put the box's bottom edge on the
        // origin, flip Y and scale about it, then move it where it goes. Doing
        // it in the other order scales the offset and lands the glyph a couple
        // of hundred points below the frame, which is exactly what it did.
        var t = AffineTransform(translationByX: 0, byY: -viewBox.height)
        t.append(AffineTransform(scaleByX: s, byY: -s))
        t.append(AffineTransform(translationByX: ox, byY: oy))
        let out = raw.copy() as! NSBezierPath
        out.transform(using: t)
        out.windingRule = .evenOdd     // counters in the glyph are holes
        return out
    }

    /// The path in its own viewBox coordinates.
    private static func parse(_ d: String) -> NSBezierPath {
        let p = NSBezierPath()
        var nums: [CGFloat] = []
        var cmd: Character = " "
        var cur = CGPoint.zero
        var start = CGPoint.zero

        // Tokenise: a command letter, or a number. Numbers can be written
        // "1.5e-05", ".5", "-3" and can run together as "-1-2", which is why
        // this is a scanner and not a `split`.
        var tokens: [(Character?, CGFloat?)] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter {
                tokens.append((c, nil)); i += 1; continue
            }
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1; continue }
            var j = i
            var seenDigit = false
            if chars[j] == "-" || chars[j] == "+" { j += 1 }
            while j < chars.count {
                let k = chars[j]
                if k.isNumber { seenDigit = true; j += 1; continue }
                if k == "." { j += 1; continue }
                if (k == "e" || k == "E"), seenDigit {
                    j += 1
                    if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                    continue
                }
                break
            }
            guard j > i, let v = Double(String(chars[i..<j])) else { break }
            tokens.append((nil, CGFloat(v)))
            i = j
        }

        /// Emit whatever the pending command can make from the numbers so far.
        func flush() {
            func rel(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                cmd.isLowercase ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd.uppercased().first ?? " " {
            case "M":
                var k = 0
                while k + 1 < nums.count {
                    let pt = rel(nums[k], nums[k + 1])
                    if k == 0 { p.move(to: pt); start = pt } else { p.line(to: pt) }
                    cur = pt; k += 2
                }
            case "L":
                var k = 0
                while k + 1 < nums.count {
                    let pt = rel(nums[k], nums[k + 1]); p.line(to: pt); cur = pt; k += 2
                }
            case "H":
                for v in nums {
                    let pt = CGPoint(x: cmd.isLowercase ? cur.x + v : v, y: cur.y)
                    p.line(to: pt); cur = pt
                }
            case "V":
                for v in nums {
                    let pt = CGPoint(x: cur.x, y: cmd.isLowercase ? cur.y + v : v)
                    p.line(to: pt); cur = pt
                }
            case "C":
                var k = 0
                while k + 5 < nums.count {
                    let c1 = rel(nums[k], nums[k + 1])
                    let c2 = rel(nums[k + 2], nums[k + 3])
                    let pt = rel(nums[k + 4], nums[k + 5])
                    p.curve(to: pt, controlPoint1: c1, controlPoint2: c2)
                    cur = pt; k += 6
                }
            case "Q":
                var k = 0
                while k + 3 < nums.count {
                    let c = rel(nums[k], nums[k + 1])
                    let pt = rel(nums[k + 2], nums[k + 3])
                    // NSBezierPath has no quadratic; the exact cubic equivalent.
                    let c1 = CGPoint(x: cur.x + 2.0 / 3 * (c.x - cur.x),
                                     y: cur.y + 2.0 / 3 * (c.y - cur.y))
                    let c2 = CGPoint(x: pt.x + 2.0 / 3 * (c.x - pt.x),
                                     y: pt.y + 2.0 / 3 * (c.y - pt.y))
                    p.curve(to: pt, controlPoint1: c1, controlPoint2: c2)
                    cur = pt; k += 4
                }
            case "Z":
                if !p.isEmpty { p.close(); cur = start }
            default:
                break
            }
            nums.removeAll(keepingCapacity: true)
        }

        for t in tokens {
            if let c = t.0 {
                if cmd != " " { flush() }
                cmd = c
                if c == "z" || c == "Z" { flush(); cmd = " " }
            } else if let v = t.1 {
                nums.append(v)
            }
        }
        if cmd != " " { flush() }
        return p
    }
}
