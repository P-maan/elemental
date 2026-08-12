//  DesktopGrid.swift — the miniature of your display, and the hand that moves it.
//
//  This is the Elements pane's live map of `PlacementModel`. It is not a second
//  editor: it draws exactly the placements the full-screen overlay is editing,
//  writes back through the same mutators, snaps by the same rules and commits
//  down the same path. Drag something here and it moves on the overlay while
//  your finger is still down; drag it there and it moves here. See the header of
//  Placements.swift for why there is only one model.
//
//  It stays directly editable rather than becoming a read-only thumbnail,
//  because the pane is where you check a placement against the switches that
//  light it up, and being able to nudge one without opening anything is worth
//  keeping. What it can no longer do is disagree: a widget here is a size PRESET
//  like it is everywhere else, so there are no free-hand rectangles left to
//  reconcile.
//
//  ---- Haptics
//
//  Every snap and every detent crossed while dragging fires
//  `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, ...)` — the
//  pattern Preview and Keynote use for their snap guides, so it is already the
//  meaning "you have landed on a line" carries on this hardware. It fires on the
//  TRANSITION into a snap, never continuously: a drag that stays parked on a
//  guide buzzes once, not sixty times a second.
//
//  The performer is guarded. A Mac with a non-Force-Touch trackpad, or a mouse
//  and no trackpad at all, has none, and asking for feedback there must be a
//  no-op rather than a crash.
//
//  ---- Where the work happens
//
//  Dragging writes geometry into the model, which redraws whatever is watching.
//  The CONFIG is committed on MOUSE-UP, not per mouse-move: a commit re-syncs
//  every other pane and pushes new collision geometry into the live wallpaper,
//  which is not something to do sixty times a second. See the performance note
//  at the top of Settings.swift.

import AppKit

// MARK: - Haptics

/// The alignment detent, or nothing at all on hardware that cannot do it.
enum Haptics {

    /// Optional on purpose. `defaultPerformer` is declared non-optional by
    /// AppKit, but the whole point is that plenty of Macs cannot do this, so it
    /// is taken as an optional and guarded — a mouse-only desk must get silence,
    /// not a trap.
    private static var performer: NSHapticFeedbackPerformer? {
        let p: NSHapticFeedbackPerformer? = NSHapticFeedbackManager.defaultPerformer
        return p
    }

    /// One detent. Call on the transition into a snap, never per frame.
    static func alignment() {
        guard let p = performer else { return }
        p.perform(.alignment, performanceTime: .drawCompleted)
    }

    /// A heavier one, for a control landing on a named stop rather than a line.
    static func level() {
        guard let p = performer else { return }
        p.perform(.levelChange, performanceTime: .drawCompleted)
    }

    /// True when this Mac can actually do it. Used only to word the UI honestly.
    static var available: Bool { performer != nil }
}

/// A slider that clicks as it passes each detent.
///
/// `NSSlider` with tick marks snaps but says nothing, so a slider dragged with
/// the pointer outside the track gives no clue where the stops are. One
/// `.alignment` tap per detent crossed makes them findable without looking.
final class DetentSlider: NSSlider {

    /// Detent spacing in slider units. 0.1 over a 0...1 range is ten stops.
    var detent: Double = 0.1
    private var lastIndex: Int?

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let i = Int((doubleValue / max(0.0001, detent)).rounded())
        if let last = lastIndex, last != i { Haptics.alignment() }
        lastIndex = i
        return super.sendAction(action, to: target)
    }

    /// Called when the value is set programmatically, so the next drag does not
    /// fire a spurious detent for the jump.
    func resyncDetent() { lastIndex = Int((doubleValue / max(0.0001, detent)).rounded()) }
}

// MARK: - The grid

final class DesktopGridView: NSView {

    /// The geometry. Not owned — the pane owns it and hands the same instance to
    /// the overlay, which is the whole point.
    let model: PlacementModel

    // ---- selection, in this view's own vocabulary
    //
    // `PlacementModel.Ref?` with a `.none` case spelled out, so call sites read
    // the way they always have.

    enum Selection: Equatable { case none, dock, widget(Int) }

    var selection: Selection {
        get {
            switch model.selection {
            case .none: return .none
            case .dock: return .dock
            case .widget(let i): return .widget(i)
            }
        }
        set { model.selection = ref(of: newValue) }
    }

    // MARK: - Model passthroughs
    //
    // Kept as properties rather than making every caller reach into the model,
    // because the pane and the offscreen harness both talk to this view in terms
    // of `WidgetRect`s and that is the shape `Config` uses too.

    var widgets: [WidgetRect] {
        get { model.widgetRects }
        set { model.setWidgetRects(newValue) }
    }
    var dock: CGRect? {
        get { model.dock }
        set { model.dock = newValue }
    }
    var menuBarHeight: CGFloat {
        get { model.menuBarHeight }
        set { model.menuBarHeight = newValue }
    }
    var wetDock: Bool {
        get { model.wetDock }
        set { model.wetDock = newValue }
    }
    var wetWidgets: Bool {
        get { model.wetWidgets }
        set { model.wetWidgets = newValue }
    }
    var wetMenuBar: Bool {
        get { model.wetMenuBar }
        set { model.wetMenuBar = newValue }
    }
    var strength: CGFloat {
        get { model.strength }
        set { model.strength = newValue }
    }

    /// A faint copy of the user's screenshot behind the rectangles, so what has
    /// been placed can be checked against what was actually on screen. This is
    /// the difference between "trust these numbers" and "look, that is your
    /// dock".
    var backdrop: NSImage? {
        get { model.backdrop }
        set { model.backdrop = newValue }
    }

    /// Screen shape, from the model's reference display.
    var aspect: CGFloat { model.aspect }

    var selectionDescription: String { model.selectionDescription }

    // ---- geometry

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var widthC: NSLayoutConstraint!
    private var heightC: NSLayoutConstraint!

    init(width: CGFloat = 320, model: PlacementModel = PlacementModel()) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: width,
                                 height: (width / model.aspect).rounded()))
        translatesAutoresizingMaskIntoConstraints = false
        widthC = widthAnchor.constraint(equalToConstant: width)
        heightC = heightAnchor.constraint(equalToConstant: (width / model.aspect).rounded())
        NSLayoutConstraint.activate([widthC, heightC])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Your desktop. Drag the rectangles to match what is on your screen.")

        // Anything that changes the model redraws this. A drag happening in the
        // OVERLAY arrives here through exactly this path, which is what makes
        // the two views one feature rather than two.
        model.observe(self) { [weak self] _ in
            guard let self else { return }
            // The overlay measures the presets against whichever display it was
            // opened on, so the reference screen can change under us. A
            // miniature still drawn at the old shape would put every rectangle
            // in a slightly wrong place, which is precisely the kind of drift
            // this file is meant to be free of.
            let h = (self.widthC.constant / self.model.aspect).rounded()
            if abs(self.heightC.constant - h) > 0.5 { self.heightC.constant = h }
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { model.stopObserving(self) }

    /// The screen's rectangle inside the view, inset for the bezel.
    var screenRect: NSRect { bounds.insetBy(dx: 5, dy: 5) }

    /// Fraction to view points. Deliberately NOT rounded or `.integral`-ised:
    /// the drawn rectangle has to be the model's rectangle exactly, or the frame
    /// under a dragged widget sits a point or two off the widget it belongs to
    /// and the whole thing looks like it is not tracking. Everything — fill,
    /// ring, handles, labels, hit testing — goes through this one function.
    func toView(_ r: CGRect) -> NSRect {
        let s = screenRect
        return NSRect(x: s.minX + r.minX * s.width, y: s.minY + r.minY * s.height,
                      width: r.width * s.width, height: r.height * s.height)
    }

    private func toFrac(_ p: NSPoint) -> CGPoint {
        let s = screenRect
        return CGPoint(x: (p.x - s.minX) / max(1, s.width), y: (p.y - s.minY) / max(1, s.height))
    }

    /// The rounding of the real thing, scaled into this miniature. A widget
    /// drawn 70pt wide up here gets the radius its 329pt self would have,
    /// shrunk by the same factor — so the shape is right at every size.
    private func radius(_ e: PlacementModel.Element) -> CGFloat {
        e.radiusPoints * (screenRect.width / max(1, model.screenPoints.width))
    }

    // MARK: - Drawing

    override func draw(_ dirty: NSRect) {
        let s = screenRect
        let screen = NSBezierPath(roundedRect: s, xRadius: 9, yRadius: 9)

        NSColor.windowBackgroundColor.setFill()
        screen.fill()

        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        if let img = model.backdrop {
            // The real screenshot, dimmed, so the rectangles can be checked
            // against the thing they are meant to describe.
            // `respectFlipped` matters: this view is flipped so that fractions
            // read y-down like `WidgetRect`, and without it the screenshot
            // draws upside down under rectangles that are the right way up.
            img.draw(in: s, from: .zero, operation: .sourceOver, fraction: 0.55,
                     respectFlipped: true, hints: nil)
            NSColor.windowBackgroundColor.withAlphaComponent(0.28).setFill()
            s.fill()
        } else {
            let sky = NSGradient(colors: [
                NSColor(calibratedRed: 0.19, green: 0.40, blue: 0.70, alpha: 1),
                NSColor(calibratedRed: 0.60, green: 0.75, blue: 0.89, alpha: 1),
            ])
            sky?.draw(in: s, angle: -90)
        }
        NSGraphicsContext.restoreGraphicsState()

        for e in model.elements {
            let r = toView(e.rect)
            let rad = radius(e)
            let p = continuousRoundedRect(r, radius: rad)

            NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
            p.fill()
            if e.wet {
                NSColor.controlAccentColor.withAlphaComponent(0.26 + 0.44 * model.strength).setFill()
                p.fill()
                NSColor.controlAccentColor.setStroke()
                p.lineWidth = 1.5
                p.stroke()
            } else {
                NSColor.separatorColor.setStroke()
                p.lineWidth = 1
                p.stroke()
            }

            // The live link, drawn first so the selection ring sits over it: the
            // element somebody has hold of RIGHT NOW glows, whether the hand is
            // in this view or on the full-screen overlay.
            if let ref = e.ref, model.dragging == ref { drawDragHalo(r, radius: rad) }

            if let ref = e.ref, model.selection == ref {
                let ring = continuousRoundedRect(r.insetBy(dx: -2.5, dy: -2.5), radius: rad + 2.5)
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 2
                ring.stroke()
                // Whatever grips this element offers. Eight for a widget, which
                // can be any size; the four mid-edge ones for the dock, so that
                // every dock drag changes exactly one edge.
                drawHandles(r, indices: e.handles)
            }

            let labelSize: CGFloat = big ? 11 : 8
            if r.height >= labelSize + 5, r.width >= labelSize * 3 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: labelSize, weight: e.wet ? .semibold : .regular),
                    .foregroundColor: e.wet ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]
                let str = NSAttributedString(string: e.label, attributes: attrs)
                let sz = str.size()
                if sz.width < r.width - 4 {
                    str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
                }
            }
        }

        drawSuggestions()

        // Snap guides, while a drag is holding one.
        if !guides.isEmpty {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            for g in guides {
                let line = NSBezierPath()
                line.lineWidth = 1
                line.setLineDash([3, 3], count: 2, phase: 0)
                if g.vertical {
                    let x = (s.minX + g.value * s.width).rounded() + 0.5
                    line.move(to: NSPoint(x: x, y: s.minY)); line.line(to: NSPoint(x: x, y: s.maxY))
                } else {
                    let y = (s.minY + g.value * s.height).rounded() + 0.5
                    line.move(to: NSPoint(x: s.minX, y: y)); line.line(to: NSPoint(x: s.maxX, y: y))
                }
                line.stroke()
            }
        }

        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()
    }

    /// Two soft rings outside the rectangle, at the rectangle's own rounding.
    /// Outside rather than a fill, so it cannot be confused with the wet styling
    /// and so it still reads on a widget small enough to be four points high.
    private func drawDragHalo(_ r: NSRect, radius: CGFloat) {
        for (inset, alpha, width) in [(CGFloat(6), CGFloat(0.18), CGFloat(4)),
                                      (CGFloat(3), CGFloat(0.55), CGFloat(2))] {
            let halo = continuousRoundedRect(r.insetBy(dx: -inset, dy: -inset),
                                             radius: radius + inset)
            NSColor.controlAccentColor.withAlphaComponent(alpha).setStroke()
            halo.lineWidth = width
            halo.stroke()
        }
    }

    // ---- handle size
    //
    // A 3pt dot with a 12pt hit box is fine on a 320pt thumbnail and impossible
    // on a bigger one, where the same rectangle is more than twice as wide and
    // the pointer has real room to work in. Both scale with the miniature so a
    // handle is always worth aiming at.

    private var big: Bool { bounds.width >= 560 }
    private var handleRadius: CGFloat { big ? 5.5 : 3 }
    private var handleSlop: CGFloat { big ? 11 : 6 }

    private func drawHandles(_ r: NSRect, indices: [Int]) {
        let hr = handleRadius
        for i in indices {
            let p = ResizeHandle.point(i, in: r)
            let box = NSRect(x: p.x - hr, y: p.y - hr, width: hr * 2, height: hr * 2)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.controlAccentColor.setStroke()
            let o = NSBezierPath(ovalIn: box)
            o.lineWidth = 1.5
            o.stroke()
        }
    }

    /// What the detector thinks it saw, drawn dashed and dimmer so it cannot be
    /// mistaken for something that has been placed. It is not editable from the
    /// miniature — a suggestion is taken or dropped on the full-screen editor,
    /// where it is over the thing it is a guess about — but it is drawn here so
    /// the two views still show the same state.
    private func drawSuggestions() {
        guard !model.suggestions.isEmpty else { return }
        for s in model.suggestions {
            let r = toView(s.rect)
            let rad = s.kind == .dock
                ? min(18, min(r.width, r.height) / 2)
                : model.cornerRadiusPoints(for: s.rect)
                    * (screenRect.width / max(1, model.screenPoints.width))
            let p = continuousRoundedRect(r, radius: rad)
            NSColor.systemPink.withAlphaComponent(0.10).setFill()
            p.fill()
            NSColor.systemPink.withAlphaComponent(0.85).setStroke()
            p.lineWidth = 1.5
            p.setLineDash([4, 3], count: 2, phase: 0)
            p.stroke()
        }
    }

    // MARK: - Snapping

    private var guides: [PlacementModel.Guide] = []
    /// Which snaps are currently engaged, so a haptic fires on the transition in
    /// rather than every frame the drag stays parked on the line.
    private var engaged: Set<String> = []

    /// Snap distance, derived from a fixed few points in the VIEW — so it feels
    /// the same however big the miniature is drawn, and so this view and the
    /// full-screen overlay both mean "close enough to catch under the hand".
    private var snapTolerance: CGSize {
        CGSize(width: 4.5 / max(1, screenRect.width), height: 4.5 / max(1, screenRect.height))
    }

    /// Buzz once per newly engaged guide, then remember what is engaged.
    private func apply(_ snap: PlacementModel.Snap) {
        guides = snap.guides
        if !snap.names.subtracting(engaged).isEmpty { Haptics.alignment() }
        engaged = snap.names
    }

    // MARK: - Pointer handling
    //
    // Split out from `mouseDown`/`mouseDragged` so the verification harness can
    // drive a drag without a mouse — there is no other way to prove that the
    // editor, the snapping and the haptics actually work, since the harness
    // cannot click.

    /// Which part of the selection a drag has hold of. -1 is the body.
    private var grabbed: Int = -1
    private var dragOrigin: CGPoint = .zero
    private var rectAtGrab: CGRect = .zero
    private var dragging = false

    /// Smallest anything may be pulled to, as a fraction. Below this it cannot
    /// be grabbed again.
    private let minSize: CGFloat = 0.02

    /// Which grips an element offers. Taken from the model's element list, so
    /// the hit test cannot get out of step with what was drawn.
    private func handles(for ref: PlacementModel.Ref) -> [Int] {
        model.elements.first { $0.ref == ref }?.handles ?? []
    }

    func pointerDown(_ p: NSPoint, clickCount: Int = 1) {
        window?.makeFirstResponder(self)
        guides.removeAll(); engaged.removeAll()

        // A resize handle of the current selection wins over anything underneath
        // it, including the rectangle it belongs to.
        if let ref = model.selection, let r = model.rect(of: ref) {
            let vr = toView(r)
            let slop = handleSlop
            for i in handles(for: ref) {
                let hp = ResizeHandle.point(i, in: vr)
                guard NSRect(x: hp.x - slop, y: hp.y - slop,
                             width: slop * 2, height: slop * 2).contains(p) else { continue }
                grabbed = i
                dragOrigin = toFrac(p)
                rectAtGrab = r
                begin(ref)
                return
            }
        }
        // Otherwise pick the front-most element under the pointer.
        if let ref = model.hit(toFrac(p)), let r = model.rect(of: ref) {
            model.selection = ref
            // A second click steps a widget round the four sizes. It is the
            // repair for the one case classification gets wrong — a rectangle
            // drawn between two presets — and it beats deleting and redrawing to
            // change your mind.
            if clickCount == 2, case .widget(let i) = ref {
                model.cycleSize(i)
                Haptics.level()
                dragging = false
                model.commit()
                return
            }
            grabbed = -1
            dragOrigin = toFrac(p)
            rectAtGrab = r
            begin(ref)
            return
        }
        model.selection = nil
        dragging = false
        needsDisplay = true
    }

    private func begin(_ ref: PlacementModel.Ref) {
        dragging = true
        model.dragging = ref
    }

    func pointerDragged(_ p: NSPoint) {
        guard dragging, let ref = model.selection else { return }
        let now = toFrac(p)
        let dx = now.x - dragOrigin.x, dy = now.y - dragOrigin.y

        if grabbed < 0 {
            // Clamp on to the screen BEFORE snapping, never after. A clamp
            // applied afterwards silently slides the rectangle off the guide it
            // just caught, and then the dashed line the user is aiming at is no
            // longer touching the rectangle they are aiming it with. Every
            // target is inside the screen and a snap moves at most one
            // tolerance, so clamping first cannot let anything escape.
            let moved = clamp(rectAtGrab.offsetBy(dx: dx, dy: dy))
            let snap = model.snapping(moved, moving: ref, tolerance: snapTolerance)
            apply(snap)
            model.write(snap.rect, to: ref)
        } else {
            // A resize. Every rule — which edges the handle owns, the
            // positional guides, the preset-dimension magnets, the minimum
            // size — lives in the model, so the miniature and the full-screen
            // editor resize identically. See `PlacementModel.resizing`.
            let snap = model.resizing(rectAtGrab, handle: grabbed, dx: dx, dy: dy,
                                      ref: ref, tolerance: snapTolerance, minimum: minSize,
                                      presetMagnets: ref != .dock)
            apply(snap)
            model.write(snap.rect, to: ref)
        }
        needsDisplay = true
    }

    func pointerUp() {
        guard dragging else { return }
        dragging = false
        model.dragging = nil
        guides.removeAll()
        engaged.removeAll()
        needsDisplay = true
        model.commit()
    }

    /// Entirely on the screen. A rectangle half off the edge is one the user
    /// cannot grab again, and neither a widget nor the dock can be there.
    private func clamp(_ r: CGRect) -> CGRect { model.clamped(r) }

    override func mouseDown(with event: NSEvent) {
        pointerDown(convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) {
        pointerDragged(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { pointerUp() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Three speeds, so fine adjustment never needs pixel-accurate mousing:
        // ⌥ a hair, plain a step, ⇧ a stride. On a 4112px display ⌥ is about
        // four pixels.
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.02
                          : event.modifierFlags.contains(.option) ? 0.001 : 0.004
        var handled = true
        switch event.keyCode {
        case 123: nudge(dx: -step, dy: 0, pull: step)   // left
        case 124: nudge(dx: step, dy: 0, pull: step)    // right
        case 125: nudge(dx: 0, dy: step, pull: step)    // down
        case 126: nudge(dx: 0, dy: -step, pull: step)   // up
        case 51, 117: removeSelected()           // delete / forward delete
        case 48: cycleSelection()                // tab
        case 49: cycleSize()                     // space
        // Same bindings as the full-screen editor. One model, one set of keys —
        // learning them in the miniature must carry over.
        case 33: model.nudgeSelectedWetness(by: -0.1)  // [
        case 30: model.nudgeSelectedWetness(by:  0.1)  // ]
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }

    /// `pull` is how far a nudge is allowed to be dragged onto a guide — one
    /// step, so a fine ⌥-nudge is not yanked back onto a line it was trying to
    /// creep away from.
    private func nudge(dx: CGFloat, dy: CGFloat, pull: CGFloat = 0.004) {
        guard let ref = model.selection, let r0 = model.rect(of: ref) else { return }
        let moved = clamp(r0.offsetBy(dx: dx, dy: dy))
        // A keyboard nudge that lands exactly on a guide should feel like the
        // drag that lands on the same guide.
        let snap = model.snapping(moved, moving: ref, tolerance: snapTolerance)
        var r = moved
        if abs(snap.rect.minX - moved.minX) < pull { r.origin.x = snap.rect.minX }
        if abs(snap.rect.minY - moved.minY) < pull { r.origin.y = snap.rect.minY }
        if !snap.names.subtracting(engaged).isEmpty { Haptics.alignment() }
        engaged = snap.names
        guides.removeAll()
        model.write(r, to: ref)
        needsDisplay = true
        model.commit()
    }

    func cycleSelection() {
        let all = model.cycleOrder
        guard !all.isEmpty else { return }
        guard let ref = model.selection, let i = all.firstIndex(of: ref) else {
            model.selection = all[0]; return
        }
        model.selection = all[(i + 1) % all.count]
        Haptics.alignment()
    }

    /// Step the selected widget round the four sizes. The dock has no presets,
    /// so it is left alone rather than being given a meaningless one.
    func cycleSize() {
        guard case .widget(let i) = model.selection else { return }
        model.cycleSize(i)
        Haptics.level()
        model.commit()
    }

    // MARK: - Edits

    func addWidget() {
        // Dropped in the middle at the commonest size, selected, ready to be
        // dragged where it belongs and pulled to whatever size it really is.
        let s = model.fractionalSize(.medium)
        model.addWidget(model.clamped(WidgetPlacement(
            rect: CGRect(x: 0.5 - s.width / 2, y: 0.5 - s.height / 2,
                         width: s.width, height: s.height))))
        Haptics.level()
        needsDisplay = true
        model.commit()
    }

    /// Which the Remove button and ⌫ apply to.
    ///
    /// Widgets only. The dock is not deletable, because "no dock" is not a
    /// placement — it is the Dock switch below, and removing the rectangle
    /// would only make it come back from the system estimate on the next sync,
    /// which reads as the button not working.
    var canRemoveSelection: Bool {
        if case .widget(let i) = model.selection { return i < model.widgets.count }
        return false
    }

    func removeSelected() {
        guard case .widget(let i) = model.selection else { return }
        model.removeWidget(at: i)
        Haptics.level()
        needsDisplay = true
        model.commit()
    }

    func clearAll() {
        model.removeAllWidgets()
        needsDisplay = true
        model.commit()
    }

    /// Replace everything with what a screenshot yielded. Every rectangle is
    /// classified to a preset on the way in — see `PlacementModel.setWidgetRects`.
    func adopt(_ d: DetectedDesktop) {
        model.setWidgetRects(d.widgets.map {
            WidgetRect(x: Float($0.minX), y: Float($0.minY),
                       w: Float($0.width), h: Float($0.height))
        })
        model.dock = d.dock
        if let m = d.menuBar { model.menuBarHeight = m }
        model.selection = nil
        needsDisplay = true
        model.commit()
    }

    // MARK: - Selection plumbing

    private func ref(of s: Selection) -> PlacementModel.Ref? {
        switch s {
        case .none: return nil
        case .dock: return .dock
        case .widget(let i): return .widget(i)
        }
    }

    func rect(of s: Selection) -> CGRect? {
        guard let r = ref(of: s) else { return nil }
        return model.rect(of: r)
    }
}

// MARK: - Dock override

/// Fold a user-corrected dock rectangle into the collision geometry.
///
/// `Furniture.desktop` derives the dock from com.apple.dock's tile size and item
/// count, which is a good guess and not more than that — a stack, a wide
/// separator or a second display all move it. When the user has dragged the dock
/// in the placement editor, that measurement is better than the guess, so it
/// replaces it. Nil changes nothing, which is what every user who never opens the
/// pane gets.
func applyingDockOverride(_ surfaces: [Surface], override: WidgetRect?,
                          pixelWidth W: Float, pixelHeight H: Float,
                          enabled: Bool) -> [Surface] {
    guard let o = override, enabled else { return surfaces }
    var out = surfaces.filter { $0.kind != .dock }
    out.append(Surface(x: o.x * W, y: o.y * H, w: o.w * W, h: o.h * H, kind: .dock))
    return out
}
