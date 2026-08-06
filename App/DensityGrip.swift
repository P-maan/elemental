//  DensityGrip.swift — grid density you take hold of.
//
//  Density used to be a stepper: "Grid rows: 36". Nobody knows what 36 rows
//  looks like, so the only way to use it was to type a number, look at the
//  preview, and type another one. The complaint was exact — the wanted gesture
//  is grabbing the grid by the corner of the box and stretching it until the
//  cells are the size you want, or rolling two fingers over it until they are.
//
//  So this is the control: a live render of the actual mosaic, with a corner
//  handle. Drag the handle OUT and the cells grow, which means fewer of them
//  fit down the screen; drag it IN and they shrink and there are more. Two
//  fingers anywhere over the box does the same thing a step at a time. Every
//  step crossed fires `Haptics.alignment()` — the same detent DesktopGrid uses
//  for a snap — on the TRANSITION into the step and never per mouse-move, or a
//  drag buzzes continuously instead of clicking.
//
//  The numeric field beside it stays. A picture is not typeable, not
//  scriptable, and not reachable from the keyboard, and somebody who knows they
//  want 48 should be able to say so.
//
//  ---- Why there is a ladder rather than a number line
//
//  The engine does not use the row count it is given. `SceneSimulation.resize`
//  picks a cell pitch that divides the display's pixel height EXACTLY, because
//  a remainder is a sliver of screen the grid never reaches. So asking for 37
//  rows on a 1800px display gets you whatever whole-pitch count is nearest, and
//  several different requests land on the same one. A control that stepped
//  through the raw numbers would click through values that draw identically and
//  then appear to snap somewhere else when committed.
//
//  `MosaicDensity.ladder` therefore enumerates the densities the display can
//  actually produce, once, and the drag and the scroll both move an INDEX along
//  it. Every click is a visible change, and the read-out is the count the
//  engine will really use rather than the one that was asked for.
//
//  ---- Cost
//
//  The picture is a `PreviewTile` at `ScenePreview.large`, which is the size the
//  hero already renders — so at rest the grip is a cache hit and costs nothing,
//  and during a drag it shares the hero's renderer instead of forcing a fourth
//  one into existence. Requests are coalesced per slot by `ScenePreview`, so a
//  60-events-a-second drag costs one render per render. Nothing here is
//  debounced away, because this preview IS the control: see the performance
//  note at the top of PreviewRenderer.swift for what is debounced and why.

import AppKit

// MARK: - What the engine can actually draw

enum MosaicDensity {

    /// The range the stored setting is clamped to, unchanged from the stepper.
    static let requestRange = 12...120

    /// One achievable density.
    struct Step: Equatable {
        /// The value to store in the config to get this density.
        var requested: Int
        /// What the engine will really draw.
        var rows: Int
        /// Cell pitch in display pixels.
        var cellPixels: Double
    }

    /// The row count `SceneSimulation.resize` will settle on for a request.
    ///
    /// A mirror of that function, deliberately: it lives in Core and is not
    /// callable without building a whole simulation, and the only thing needed
    /// here is the arithmetic. Kept in the same order and with the same
    /// `max(6,…)` floor so the two cannot disagree.
    static func actualRows(requested: Int, pixelHeight: Double) -> Int {
        let h = Float(max(1, pixelHeight))
        let sp0 = max(6, (h / Float(max(1, requested))).rounded())
        let r = max(1, Int((h / sp0).rounded()))
        let sp = h / Float(r)
        return max(1, Int((h / sp).rounded()))
    }

    /// Every distinct density this display can produce, ascending, each with the
    /// request that yields it.
    static func ladder(pixelHeight: Double) -> [Step] {
        var seen = Set<Int>()
        var out: [Step] = []
        for q in requestRange {
            let r = actualRows(requested: q, pixelHeight: pixelHeight)
            guard !seen.contains(r) else { continue }
            seen.insert(r)
            out.append(Step(requested: q, rows: r, cellPixels: pixelHeight / Double(r)))
        }
        return out.sorted { $0.rows < $1.rows }
    }

    /// The main display, in pixels down. The same number `WallpaperSurface`
    /// hands the renderer, so the ladder describes the wall the user will see.
    static var displayPixelHeight: Double {
        guard let s = NSScreen.main, s.frame.height > 1 else { return 1800 }
        return Double(s.frame.height * s.backingScaleFactor)
    }
}

// MARK: - The control

final class DensityGripView: NSView {

    /// Points the picture is drawn at. The RENDER is always `ScenePreview.large`
    /// — same 8:5 shape a display has, same renderer the hero uses.
    static let tilePoints = NSSize(width: 264, height: 165)
    /// Room around the picture for the handle to sit on its corner.
    private static let pad: CGFloat = 12

    private let tile = PreviewTile(points: DensityGripView.tilePoints, corner: 8)
    private let overlay = GripOverlay()

    /// The densities this display can draw, ascending.
    private(set) var steps: [MosaicDensity.Step]
    private(set) var index: Int = 0

    /// Fires on every step crossed, with the value to store. Cheap: update the
    /// field and the live preview from here, never commit.
    var onLiveChange: ((Int) -> Void)?
    /// Fires on mouse-up, on the end of a scroll, and on discrete edits.
    var onCommit: ((Int) -> Void)?

    private var base: PreviewSpec?
    private(set) var isDragging = false
    private var grabDistance: CGFloat = 0
    private var grabIndex = 0
    private var scrollAccum: CGFloat = 0
    private var scrollTimer: Timer?

    /// Origin at the top left, so "drag the corner further out" is simply
    /// "larger x and y" and the distance from the picture's own corner is the
    /// obvious one.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(pixelHeight: Double = MosaicDensity.displayPixelHeight) {
        steps = MosaicDensity.ladder(pixelHeight: pixelHeight)
        let p = Self.pad
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.tilePoints.width + 2 * p,
                                 height: Self.tilePoints.height + 2 * p))
        translatesAutoresizingMaskIntoConstraints = false

        overlay.grip = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.tilePoints.width + 2 * p),
            heightAnchor.constraint(equalToConstant: Self.tilePoints.height + 2 * p),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            tile.topAnchor.constraint(equalTo: topAnchor, constant: p),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.slider)
        setAccessibilityLabel("Grid density")
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Value

    /// The current step. Never empty — the ladder always has at least one entry.
    var step: MosaicDensity.Step {
        steps.isEmpty ? MosaicDensity.Step(requested: 36, rows: 36, cellPixels: 50)
                      : steps[max(0, min(steps.count - 1, index))]
    }

    /// What to store in the config for what is shown.
    var requestedRows: Int { step.requested }
    /// What the engine will really draw on this display.
    var actualRows: Int { step.rows }

    /// Move to whichever step a stored request lands on. Silent — no haptic and
    /// no callback, because this is `sync` catching up with the config, not the
    /// user turning anything.
    func setRequested(_ q: Int) {
        let want = MosaicDensity.actualRows(requested: q,
                                            pixelHeight: MosaicDensity.displayPixelHeight)
        index = nearestIndex(rows: Double(want))
        scrollAccum = 0
        updateAccessibility()
        overlay.needsDisplay = true
        refreshTile()
    }

    private func nearestIndex(rows: Double) -> Int {
        guard !steps.isEmpty else { return 0 }
        var best = 0
        var bestD = Double.greatestFiniteMagnitude
        for (i, s) in steps.enumerated() {
            let d = abs(Double(s.rows) - rows)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// The one place the index moves. Buzzes once per step crossed, on the
    /// transition and never per frame — a drag parked between two steps is
    /// silent.
    private func setIndex(_ i: Int, live: Bool) {
        let clamped = max(0, min(steps.count - 1, i))
        guard clamped != index else { return }
        index = clamped
        Haptics.alignment()
        updateAccessibility()
        overlay.needsDisplay = true
        refreshTile()
        if live { onLiveChange?(requestedRows) }
    }

    private func updateAccessibility() {
        setAccessibilityValue("\(actualRows) rows")
        toolTip = "\(actualRows) rows down your display — "
                + "\(Int(step.cellPixels.rounded()))px cells. "
                + "Drag the corner or scroll to change it."
    }

    // MARK: - The picture

    /// Draw this scene at whatever density the grip is currently showing.
    ///
    /// Cheap on every drag frame: an unchanged spec is dropped by `PreviewTile`,
    /// and a changed one supersedes the request in flight before it reaches the
    /// GPU.
    func show(_ spec: PreviewSpec) {
        var s = spec
        s.width = Int(ScenePreview.large.width)
        s.height = Int(ScenePreview.large.height)
        base = s
        refreshTile()
    }

    private func refreshTile() {
        guard let s = currentSpec else { return }
        tile.show(s)
    }

    /// The spec the box is showing right now.
    ///
    /// Exposed for the harness, which has no runloop: `ScenePreview` hands an
    /// uncached result back through `DispatchQueue.main.async`, so offscreen the
    /// picture only ever arrives if it was rendered blocking first and the
    /// request is therefore a cache hit.
    var currentSpec: PreviewSpec? {
        guard var s = base else { return nil }
        s.gridRows = requestedRows
        return s
    }

    /// Harness only. See `PreviewTile.showBlocking`.
    func renderNow() {
        if let s = currentSpec { tile.showBlocking(s) }
    }

    // MARK: - Geometry

    private var tileRect: NSRect {
        NSRect(origin: NSPoint(x: Self.pad, y: Self.pad), size: Self.tilePoints)
    }
    /// The corner being pulled, and the corner the distance is measured from.
    fileprivate var handleCentre: NSPoint { NSPoint(x: tileRect.maxX, y: tileRect.maxY) }
    private var anchor: NSPoint { NSPoint(x: tileRect.minX, y: tileRect.minY) }
    fileprivate var handleRect: NSRect {
        NSRect(x: handleCentre.x - 11, y: handleCentre.y - 11, width: 22, height: 22)
    }

    private func distance(_ p: NSPoint) -> CGFloat {
        max(24, hypot(p.x - anchor.x, p.y - anchor.y))
    }

    // MARK: - Pointer
    //
    // Split out from the event methods so the verification harness can drive a
    // drag without a mouse, exactly as DesktopGridView does — there is no other
    // way to prove that the stretch, the stepping and the haptics work.

    func pointerDown(_ p: NSPoint) {
        window?.makeFirstResponder(self)
        guard handleRect.insetBy(dx: -6, dy: -6).contains(p) else { return }
        isDragging = true
        grabDistance = distance(p)
        grabIndex = index
        overlay.needsDisplay = true
    }

    func pointerDragged(_ p: NSPoint) {
        guard isDragging, !steps.isEmpty else { return }
        // Pulling the corner out multiplies the cell's size, and the number of
        // cells down the screen is inversely proportional to it. So the row
        // count the drag is asking for is the one it started on, divided by how
        // much further out the corner now is.
        let scale = distance(p) / max(1, grabDistance)
        let wanted = Double(steps[grabIndex].rows) / Double(scale)
        setIndex(nearestIndex(rows: wanted), live: true)
    }

    func pointerUp() {
        guard isDragging else { return }
        isDragging = false
        overlay.needsDisplay = true
        onCommit?(requestedRows)
    }

    override func mouseDown(with e: NSEvent) { pointerDown(convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { pointerDragged(convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { pointerUp() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        addCursorRect(handleRect.insetBy(dx: -6, dy: -6), cursor: .crosshair)
    }

    // MARK: - Scroll

    /// Two fingers anywhere over the box. Up is denser.
    override func scrollWheel(with e: NSEvent) {
        var dy = e.scrollingDeltaY
        // A wheel reports lines, a trackpad reports points. Without this a
        // notched wheel would need a dozen clicks to move one step.
        if !e.hasPreciseScrollingDeltas { dy *= 12 }
        scrollAccum += dy
        // Points of travel per step. Chosen so a comfortable one-inch swipe
        // crosses roughly a dozen densities rather than the whole ladder.
        let per: CGFloat = 16
        var moved = 0
        while abs(scrollAccum) >= per, moved < 40 {
            let dir = scrollAccum > 0 ? 1 : -1
            scrollAccum -= CGFloat(dir) * per
            setIndex(index + dir, live: true)
            moved += 1
        }
        // A scroll has no mouse-up, so the commit is on it going quiet. The
        // timer is also what keeps a long flick from committing forty times.
        scheduleScrollCommit()
    }

    private func scheduleScrollCommit() {
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.scrollTimer = nil
            self.onCommit?(self.requestedRows)
        }
    }

    /// Step without an event, for the harness and for the keyboard.
    func stepBy(_ n: Int) {
        guard n != 0 else { return }
        setIndex(index + n, live: true)
    }

    /// Commit now rather than on the scroll timer — the harness has no runloop
    /// for a timer to fire on.
    func commitNow() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        onCommit?(requestedRows)
    }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 124, 126: stepBy(1); commitNow()    // right, up
        case 123, 125: stepBy(-1); commitNow()   // left, down
        default: super.keyDown(with: e)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { stepBy(1); commitNow(); return true }
    override func accessibilityPerformDecrement() -> Bool { stepBy(-1); commitNow(); return true }
}

// MARK: - Looking at it without clicking it
//
//     build/Elemental.app/Contents/MacOS/Elemental --density-selftest /tmp/density
//
// Builds the Home Screen pane, drives the grip's corner handle out and back in
// and then scrolls it, and writes the box at each density. A control that steps
// through values but renders the same picture every time — or a blank one —
// compiles perfectly and is invisible until somebody looks at the pixels.

enum DensitySelfTest {

    static var outDir: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--density-selftest") else { return nil }
        return URL(fileURLWithPath: a.count > i + 1 && !a[i + 1].hasPrefix("--")
                   ? a[i + 1] : "/tmp/density")
    }

    static func run() {
        guard let out = outDir else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let config = Config()
        let ladder = MosaicDensity.ladder(pixelHeight: MosaicDensity.displayPixelHeight)
        print("== density self-test -> \(out.path)")
        print("-- display \(Int(MosaicDensity.displayPixelHeight))px tall, "
            + "\(ladder.count) achievable densities, "
            + "\(ladder.first?.rows ?? 0)…\(ladder.last?.rows ?? 0) rows")

        let pane = SurfacePane(role: .desktop, title: "Home Screen", symbol: "menubar.dock.rectangle",
                               blurb: "")
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 704, height: 900),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.contentViewController = pane
        pane.syncSafely(config)
        host.contentView?.layoutSubtreeIfNeeded()

        let g = pane.grip!
        g.show(PreviewSpec.desktop(config, pixels: ScenePreview.large))

        func shot(_ name: String) {
            g.renderNow()
            g.layoutSubtreeIfNeeded()
            ElementsSelfTest.writePNG(ElementsSelfTest.render(g),
                                      to: out.appendingPathComponent(name))
        }
        shot("grip-0-initial.png")

        // Drag the corner OUT — bigger cells, fewer rows — then well past the
        // start, in, for more. Straight through the pointer API the mouse uses.
        let corner = NSPoint(x: g.bounds.maxX - 12, y: g.bounds.maxY - 12)
        var crossed = 0
        var last = g.actualRows
        g.pointerDown(corner)
        for i in 1...20 {
            g.pointerDragged(NSPoint(x: corner.x + CGFloat(i) * 9, y: corner.y + CGFloat(i) * 6))
            if g.actualRows != last { crossed += 1; last = g.actualRows }
        }
        print("   drag out  -> \(g.actualRows) rows (req \(g.requestedRows)), \(crossed) steps crossed")
        shot("grip-1-dragged-out.png")
        for i in 1...26 {
            let t = CGFloat(20 - i)
            g.pointerDragged(NSPoint(x: corner.x + t * 9, y: corner.y + t * 6))
        }
        g.pointerUp()
        print("   drag in   -> \(g.actualRows) rows (req \(g.requestedRows))")
        shot("grip-2-dragged-in.png")

        // And the scroll path, which shares the stepping and the haptics.
        g.setRequested(36)
        shot("grip-3-scroll-start.png")
        for _ in 0..<18 { g.stepBy(1) }
        g.commitNow()
        print("   scroll up -> \(g.actualRows) rows (req \(g.requestedRows))")
        shot("grip-4-scrolled.png")

        // The picture has to actually differ; identical bytes at two densities
        // would mean the preview is not following the control.
        let s = ScenePreview.shared.stats
        print("-- preview: \(s.renders) renders, \(s.hits) hits, \(s.dropped) dropped, "
            + String(format: "%.0fms", s.seconds * 1000))
        host.contentViewController = nil
        print("== done")
    }
}

// MARK: - What is drawn over the picture

/// The handle, the read-out and the cell ghost.
///
/// A separate view rather than the grip's own `draw` because subviews are drawn
/// last: anything the grip painted itself would end up behind the thumbnail it
/// is meant to annotate. It never takes a click — `hitTest` sends everything
/// through to the grip, so one set of pointer handling serves both.
private final class GripOverlay: NSView {

    weak var grip: DensityGripView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let g = grip else { return }
        let c = g.handleCentre
        let active = g.isDragging

        // One cell at the current density, in the corner being pulled. This is
        // the thing the drag is actually setting, and a number cannot show it.
        let cell = max(2, DensityGripView.tilePoints.height / CGFloat(max(1, g.actualRows)))
        let ghost = NSRect(x: c.x - cell, y: c.y - cell, width: cell, height: cell)
        let gp = NSBezierPath(rect: ghost)
        gp.lineWidth = 1
        gp.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(active ? 0.95 : 0.55).setStroke()
        gp.stroke()

        // The read-out, over the picture where the eyes already are. The count
        // the ENGINE will use — the request is in the field beside the box, and
        // a control that showed the request would look broken every time the
        // pitch had to move a row to divide the display.
        let text = "\(g.actualRows) rows"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        let pill = NSRect(x: DensityGripView.tilePoints.width / 2 - sz.width / 2 - 7,
                          y: 20, width: sz.width + 14, height: sz.height + 4)
            .offsetBy(dx: 12, dy: 0)
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2,
                                    yRadius: pill.height / 2)
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        pillPath.fill()
        NSColor.separatorColor.setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()
        str.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 2))

        // The handle itself, on the corner.
        let box = NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)
        let hp = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        (active ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
        hp.fill()
        NSColor.controlAccentColor.setStroke()
        hp.lineWidth = 1.5
        hp.stroke()

        // Three diagonal strokes, the corner-grip idiom.
        (active ? NSColor.white : NSColor.controlAccentColor).setStroke()
        for i in 0..<3 {
            let o = CGFloat(i) * 4 - 4
            let line = NSBezierPath()
            line.lineWidth = 1.5
            line.move(to: NSPoint(x: box.minX + 4 + o, y: box.maxY - 4))
            line.line(to: NSPoint(x: box.maxX - 4, y: box.minY + 4 + o))
            line.stroke()
        }
    }
}
