//  ElementsSelfTest.swift — looking at the Elements pane without clicking it.
//
//  Two things in this pane cannot be verified by reading the code. A detector
//  that finds nothing and an editor that draws blank both compile perfectly and
//  both are invisible until somebody looks at the pixels. So:
//
//      build/Elemental.app/Contents/MacOS/Elemental --elements-selftest \
//          /tmp/desktop.png /tmp/elements
//
//  runs detection over a real screenshot, draws what it found back onto that
//  screenshot, drives a synthetic drag through the grid's pointer API — the same
//  entry points `mouseDown`/`mouseDragged`/`mouseUp` call, so the snapping and
//  the haptics on the path being exercised are the real ones — and renders the
//  pane, its neighbours and the whole settings window offscreen to PNGs.
//
//  It exits before `app.run()`, so nothing is ever put on the user's screen and
//  no timer ever fires: the 0.45s settle that writes config.json needs a running
//  runloop, and there is not one.
//
//  ---- Measured, on the real screenshot in the report
//
//  4112x2658 desktop, Elemental's own mosaic wallpaper behind everything — the
//  hardest background there is for this, since the wallpaper is itself a grid of
//  hard-edged rectangles — seven visible desktop widgets, a full-width dock and
//  the menu bar.
//
//    detection            127 ms, on a background queue, once per screenshot
//    dock                 top edge 1.1% low, left edge exact, right edge 23%
//                         short (it stops where the run of contrast stops)
//    menu bar             1.6% against a true 2.9%
//    widgets              6 rectangles: 4 sit on real widgets (two of them
//                         covering a stacked PAIR as one box), 2 are wallpaper
//    missed               the two widgets in the top row
//
//  That is a rough detector, and deliberately so — see the Honesty section in
//  FurnitureDetector.swift. The numbers move whenever its thresholds move.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ElementsSelfTest {

    /// `--elements-selftest <screenshot> [outdir]`
    static var request: (shot: URL?, out: URL)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--elements-selftest") else { return nil }
        let shot = args.count > i + 1 && !args[i + 1].hasPrefix("--")
            ? URL(fileURLWithPath: args[i + 1]) : nil
        let out = args.count > i + 2 && !args[i + 2].hasPrefix("--")
            ? URL(fileURLWithPath: args[i + 2]) : URL(fileURLWithPath: "/tmp/elements")
        return (shot, out)
    }

    static func run(delegate: AppDelegate) {
        guard let req = request else { return }
        try? FileManager.default.createDirectory(at: req.out, withIntermediateDirectories: true)
        print("== Elements self-test -> \(req.out.path)")

        var config = Config()
        var detection: DetectedDesktop?

        // ---- 1. detection over a real screenshot
        if let shotURL = req.shot, let shot = NSImage(contentsOf: shotURL) {
            var r = NSRect(origin: .zero, size: shot.size)
            if let cg = shot.cgImage(forProposedRect: &r, context: nil, hints: nil) {
                let t0 = CFAbsoluteTimeGetCurrent()
                let d = FurnitureDetector.detect(cg)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                detection = d
                print("-- detection (\(String(format: "%.1f", ms)) ms)")
                d.log.forEach { print("   \($0)") }
                print("   \(d.summary)")
                writePNG(overlay(cg, d), to: req.out.appendingPathComponent("detect-overlay.png"))
                writePNG(edgeMap(cg), to: req.out.appendingPathComponent("detect-edges.png"))
                config.widgets = d.widgets.map {
                    WidgetRect(x: Float($0.minX), y: Float($0.minY),
                               w: Float($0.width), h: Float($0.height))
                }
                config.dockRect = d.dock.map {
                    WidgetRect(x: Float($0.minX), y: Float($0.minY),
                               w: Float($0.width), h: Float($0.height))
                }
            } else {
                print("!! could not decode \(shotURL.path)")
            }
        } else {
            print("-- no screenshot given, skipping detection")
        }

        // ---- 1b. the new config field survives a round trip
        //
        // `Config.init(from:)` is hand-rolled: a field added to the struct and
        // forgotten there decodes as its default forever, silently, and the
        // user's placement comes back empty after a relaunch. Equatable makes
        // the check one line, so there is no excuse for not making it.
        do {
            var probe = config
            probe.dockRect = WidgetRect(x: 0.11, y: 0.92, w: 0.75, h: 0.06)
            probe.widgets = [WidgetRect(x: 0.01, y: 0.05, w: 0.2, h: 0.13)]
            probe.wetMenuBar = true
            probe.furnitureWetness = 0.42
            let data = try JSONEncoder().encode(probe)
            let back = try JSONDecoder().decode(Config.self, from: data)
            print("-- config round trip: \(back == probe ? "every field survived" : "LOST FIELDS")")
            if back != probe {
                print("   dockRect \(String(describing: back.dockRect)) vs \(String(describing: probe.dockRect))")
                print("   widgets \(back.widgets.count) vs \(probe.widgets.count)")
            }
            // And an empty object must still decode, which is what makes an old
            // config.json upgrade in place instead of being thrown away.
            let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
            print("   an empty config.json still decodes: dock \(String(describing: old.dockRect)), "
                + "\(old.widgets.count) widgets, wetDock \(old.wetDock)")
        } catch {
            print("!! config round trip failed: \(error)")
        }

        // ---- 2. the window builds, and every pane survives being synced
        //
        // The failure this guards against is exact: NSViewController loads its
        // view lazily, so a pane nobody has visited has run neither loadView nor
        // build and every control in it is still nil. `syncSafely` is what makes
        // that safe, and this is the check that it stayed that way.
        let controller = SettingsWindowController(delegate: delegate)
        let (window, panes) = controller.inspectable
        print("-- settings window built, \(panes.count) panes: \(panes.map(\.title_).joined(separator: ", "))")
        for p in panes { p.syncSafely(config) }
        print("   every pane synced without a nil control")

        window.setContentSize(NSSize(width: 900, height: 720))
        window.contentView?.layoutSubtreeIfNeeded()
        // Pre-render the hero the visible pane wants, so the cache hit lands
        // synchronously and the screenshot shows a scene rather than the
        // "Rendering preview…" placeholder — request() calls back inline on a
        // hit, which is exactly what a harness with no runloop needs.
        for p in panes {
            if var spec = p.heroSpec(config) {
                spec.width = Int(ScenePreview.large.width)
                spec.height = Int(ScenePreview.large.height)
                ScenePreview.shared.renderBlocking(spec)
            }
        }
        panes.first?.refreshPreviews()
        window.contentView?.layoutSubtreeIfNeeded()
        if let cv = window.contentView {
            writePNG(render(cv), to: req.out.appendingPathComponent("window-general.png"))
        }

        // ---- 3. each pane on its own, at the window's real width
        for pane in panes {
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 704, height: 760),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            host.contentViewController = pane
            // AFTER assigning the controller: setting a contentViewController
            // resizes the window to the view's fitting size, so a size set
            // before this is thrown away and the scroller ends up zero-high.
            host.setContentSize(NSSize(width: 704, height: 760))
            pane.syncSafely(config)
            host.contentView?.layoutSubtreeIfNeeded()
            pane.refreshPreviews()
            host.contentView?.layoutSubtreeIfNeeded()
            let name = "pane-" + pane.title_.lowercased().replacingOccurrences(of: " ", with: "-")
            if let cv = host.contentView {
                writePNG(render(cv), to: req.out.appendingPathComponent("\(name).png"))
            }
            // The classic pinned-header mistake is a scroller whose last card is
            // unreachable, so measure it rather than trusting it.
            if let scroll = firstScrollView(in: pane.view),
               let doc = scroll.documentView {
                let clip = scroll.contentView.bounds.height
                let content = doc.frame.height
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, content - clip)))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.contentView?.layoutSubtreeIfNeeded()
                print(String(format: "   %@: content %.0f, viewport %.0f, bottom reachable at y=%.0f",
                             pane.title_, content, clip, scroll.contentView.bounds.origin.y))
                if let cv = host.contentView {
                    writePNG(render(cv), to: req.out.appendingPathComponent("\(name)-bottom.png"))
                }
            }
            host.contentViewController = nil
        }

        // ---- 4. drive the grid: select, drag, snap, resize
        if let elements = panes.first(where: { $0 is ElementsPane }) as? ElementsPane {
            driveGrid(elements, detection: detection, config: config, out: req.out)
        }

        let s = ScenePreview.shared.stats
        print("-- preview renderer: \(s.renders) renders, \(s.hits) cache hits, "
            + "\(s.dropped) dropped, \(String(format: "%.0f", s.seconds * 1000))ms total")
        print("== done")
    }

    // MARK: - Driving the editor

    private static func driveGrid(_ pane: ElementsPane, detection: DetectedDesktop?,
                                  config: Config, out: URL) {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 704, height: 760),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.contentViewController = pane
        host.setContentSize(NSSize(width: 704, height: 760))
        pane.syncSafely(config)
        host.contentView?.layoutSubtreeIfNeeded()

        guard let grid = findGrid(in: pane.view) else { print("!! no grid view found"); return }
        // The screenshot behind the rectangles is half of what makes the grid
        // checkable by eye, so put it there — `accept()` cannot be used from a
        // harness with no runloop, since it hands its result back through
        // DispatchQueue.main.
        if let shotURL = request?.shot, let shot = NSImage(contentsOf: shotURL) {
            grid.backdrop = shot
        }
        print("-- grid \(grid.bounds.size), \(grid.widgets.count) widgets, dock \(grid.dock != nil)")
        writePNG(render(grid), to: out.appendingPathComponent("grid-1-initial.png"))

        guard !grid.widgets.isEmpty else { print("!! nothing to drag"); return }

        // Grab the middle of widget 0 and drag it toward the centre of the
        // screen. Straight through the same entry points the mouse uses.
        let r = grid.rect(of: .widget(0))!
        let s = grid.screenRect
        func view(_ f: CGPoint) -> NSPoint {
            NSPoint(x: s.minX + f.x * s.width, y: s.minY + f.y * s.height)
        }
        let start = view(CGPoint(x: r.midX, y: r.midY))
        grid.pointerDown(start)
        print("   selected \(grid.selectionDescription)")
        // Walk it across in steps, so snapping engages and disengages the way it
        // does under a real drag.
        var frames = 0
        for i in 1...24 {
            let t = CGFloat(i) / 24
            grid.pointerDragged(NSPoint(x: start.x + t * s.width * 0.34,
                                        y: start.y + t * s.height * 0.22))
            frames += 1
            if i == 18 { writePNG(render(grid), to: out.appendingPathComponent("grid-2-dragging.png")) }
        }
        grid.pointerUp()
        print("   dragged over \(frames) moves -> \(grid.selectionDescription)")
        writePNG(render(grid), to: out.appendingPathComponent("grid-3-moved.png"))

        // Resize by the bottom-right handle.
        let moved = grid.rect(of: .widget(0))!
        let corner = view(CGPoint(x: moved.maxX, y: moved.maxY))
        grid.pointerDown(corner)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            grid.pointerDragged(NSPoint(x: corner.x + t * s.width * 0.10,
                                        y: corner.y + t * s.height * 0.09))
        }
        grid.pointerUp()
        print("   resized -> \(grid.selectionDescription)")

        // Add one, nudge it, and check the dock can be taken hold of too.
        grid.addWidget()
        print("   added -> \(grid.widgets.count) widgets, \(grid.selectionDescription)")
        if grid.dock != nil {
            let d = grid.dock!
            grid.pointerDown(view(CGPoint(x: d.midX, y: d.midY)))
            grid.pointerDragged(view(CGPoint(x: d.midX, y: d.midY - 0.06)))
            grid.pointerUp()
            print("   dock -> \(grid.selectionDescription)")
        }
        writePNG(render(grid), to: out.appendingPathComponent("grid-4-edited.png"))
        host.contentView?.layoutSubtreeIfNeeded()
        if let cv = host.contentView {
            writePNG(render(cv), to: out.appendingPathComponent("pane-elements-edited.png"))
        }
        host.contentViewController = nil
    }

    // MARK: - Plumbing

    private static func findGrid(in v: NSView) -> DesktopGridView? {
        if let g = v as? DesktopGridView { return g }
        for sub in v.subviews { if let g = findGrid(in: sub) { return g } }
        return nil
    }

    private static func firstScrollView(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    /// A view's pixels, over an opaque background — `NSVisualEffectView` caches
    /// as clear, and a transparent PNG of a transparent window says nothing.
    static func render(_ view: NSView) -> CGImage? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        var r = NSRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    /// The screenshot with what was found drawn on it. This is the picture that
    /// makes a detector's claims checkable.
    static func overlay(_ shot: CGImage, _ d: DetectedDesktop) -> CGImage? {
        let w = min(1400, shot.width)
        let h = Int(Double(shot.height) * Double(w) / Double(shot.width))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Detected rectangles are y-DOWN fractions; CGContext is y-up, so flip
        // on the way out.
        func box(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * CGFloat(w), y: CGFloat(h) - (r.minY + r.height) * CGFloat(h),
                   width: r.width * CGFloat(w), height: r.height * CGFloat(h))
        }
        ctx.setLineWidth(3)
        if let dock = d.dock {
            ctx.setStrokeColor(CGColor(red: 1, green: 0.25, blue: 0.2, alpha: 1))
            ctx.stroke(box(dock))
        }
        ctx.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.35, alpha: 1))
        for r in d.widgets { ctx.stroke(box(r)) }
        if let m = d.menuBar {
            ctx.setStrokeColor(CGColor(red: 0.35, green: 0.6, blue: 1, alpha: 1))
            ctx.stroke(box(CGRect(x: 0, y: 0, width: 1, height: m)))
        }
        return ctx.makeImage()
    }

    /// Every straight edge the detector found, over the screenshot. When a
    /// detection comes back empty this is the only picture that says whether the
    /// edges were never found or the rectangle-building threw them away.
    static func edgeMap(_ shot: CGImage) -> CGImage? {
        guard let g = FurnitureDetector.Grid(image: shot) else { return nil }
        let scale = 3
        let w = g.w * scale, h = g.h * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setAlpha(0.85)
        ctx.setLineWidth(2)
        func y(_ v: Int) -> CGFloat { CGFloat(h - v * scale) }
        ctx.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0.1, alpha: 1))
        for s in g.horizontalSegments() {
            ctx.move(to: CGPoint(x: CGFloat(s.a * scale), y: y(s.pos)))
            ctx.addLine(to: CGPoint(x: CGFloat(s.b * scale), y: y(s.pos)))
            ctx.strokePath()
        }
        ctx.setStrokeColor(CGColor(red: 0.1, green: 0.95, blue: 1, alpha: 1))
        for s in g.verticalSegments() {
            ctx.move(to: CGPoint(x: CGFloat(s.pos * scale), y: y(s.a)))
            ctx.addLine(to: CGPoint(x: CGFloat(s.pos * scale), y: y(s.b)))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage?, to url: URL) {
        guard let image,
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { print("!! could not write \(url.lastPathComponent)"); return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("   wrote \(url.lastPathComponent) (\(image.width)x\(image.height))")
    }
}
