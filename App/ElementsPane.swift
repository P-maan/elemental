//  ElementsPane.swift — everything about the furniture on your screen.
//
//  Elemental draws BEHIND the dock, the widgets and the menu bar, so weather
//  that lands on one of them shows in the space around it: spray off the lip of
//  the dock, snow lying along the top of a widget, a wet band under the menu
//  bar. For any of that to land in the right place the engine has to know where
//  those things ARE, and macOS publishes no API that will say. The dock can be
//  guessed at from com.apple.dock; desktop widgets cannot be guessed at at all.
//
//  So this pane asks. Three steps, in the order a person would do them:
//
//    1. SHOW THE DESKTOP and take a screenshot. Clicking the wallpaper is what
//       moves the windows out of the way on macOS, and Cmd+Shift+3 captures the
//       whole screen. The pane says so in words, in order, with the keys drawn
//       as keys.
//
//       Cmd+Shift+3 and not Cmd+Shift+4: the crosshair, with Space, captures a
//       WINDOW, and the window under the pointer on a cleared desktop is the
//       wallpaper — which is the one picture with neither the dock nor the
//       widgets in it, i.e. exactly the picture this cannot use.
//    2. HAND IT IN, by dropping it on the well or picking it with the file
//       panel, and let `FurnitureDetector` find the slabs. Detection is a
//       heuristic — read its header for what it can and cannot do.
//    3. CORRECT IT on the grid, which is the real interface here. Drag, resize,
//       add, delete, arrow-key. Snapping buzzes through the trackpad.
//
//  Underneath that sit the switches that decide what weather is allowed to do
//  to each of them, which is the other half of "elements": geometry above,
//  behaviour below.
//
//  ---- Performance
//
//  Two rules, both of which this project has been burned by. Detection is tens
//  of milliseconds of pixel work and NEVER runs on a thread that draws — it goes
//  to a background queue and comes back with a result. And a drag on the grid
//  commits on mouse-UP, not per mouse-move, so the live wallpaper is handed new
//  collision geometry once per gesture instead of sixty times a second.

import AppKit
import UniformTypeIdentifiers

// MARK: - The drop well

/// A dashed target that takes a screenshot by drag or by click.
///
/// Both, on purpose: dragging the thumbnail straight off the desktop is the
/// fast path for somebody who just took the shot, and the file panel is the one
/// that works when the screenshot went somewhere else or the drag was fumbled.
final class ScreenshotWell: NSView {

    var onImage: ((NSImage, URL?) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var highlighted = false { didSet { needsDisplay = true } }
    private var thumbnail: NSImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL, .tiff, .png])

        icon.image = NSImage(systemSymbolName: "photo.badge.plus",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular, scale: .large))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = "Drop your screenshot here"
        label.font = UI.body
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [icon, label])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 96),
            col.centerXAnchor.constraint(equalTo: centerXAnchor),
            col.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screenshot drop target")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.quaternaryLabelColor).setFill()
        p.fill()
        if let t = thumbnail {
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            let side = r.insetBy(dx: 8, dy: 8)
            let fit = AVFitRect(t.size, in: side)
            t.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 0.9)
            NSGraphicsContext.restoreGraphicsState()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        p.lineWidth = highlighted ? 2 : 1
        p.setLineDash([5, 4], count: 2, phase: 0)
        p.stroke()
    }

    /// Show what was handed in, so a mistaken file is obvious at a glance.
    func showThumbnail(_ img: NSImage?) {
        thumbnail = img
        icon.isHidden = img != nil
        label.isHidden = img != nil
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        highlighted = image(from: s) != nil
        return highlighted ? .copy : []
    }
    override func draggingExited(_ s: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ s: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let (img, url) = image(from: s) else { return false }
        onImage?(img, url)
        return true
    }

    override func mouseDown(with event: NSEvent) { choose() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    /// The file panel. Also reachable from the button beside the well, because a
    /// clickable area that does not look clickable is not a button.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a screenshot of your desktop"
        panel.prompt = "Use Screenshot"
        // Screenshots land on the Desktop by default, so start there.
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory,
                                                      in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        onImage?(img, url)
    }

    private func image(from s: NSDraggingInfo) -> (NSImage, URL?)? {
        let pb = s.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]])
            as? [URL], let u = urls.first, let img = NSImage(contentsOf: u) {
            return (img, u)
        }
        if let img = NSImage(pasteboard: pb) { return (img, nil) }
        return nil
    }
}

/// Aspect-fit one size inside a rect.
func AVFitRect(_ size: NSSize, in r: NSRect) -> NSRect {
    guard size.width > 0, size.height > 0 else { return r }
    let s = min(r.width / size.width, r.height / size.height)
    let w = size.width * s, h = size.height * s
    return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
}

// MARK: - Numbered step

/// One line of the setup instructions: a number in a circle, then the text with
/// its keystrokes drawn as keys rather than written as words.
func stepRow(_ n: Int, _ text: String, keys: [String] = []) -> NSView {
    let number = NSTextField(labelWithString: "\(n)")
    number.font = .systemFont(ofSize: 10, weight: .bold)
    number.alignment = .center
    number.textColor = .white
    number.translatesAutoresizingMaskIntoConstraints = false
    // An NSBox, not a layer-backed view: a CGColor taken from
    // `controlAccentColor` is resolved once and then frozen, so a badge drawn
    // that way keeps yesterday's accent colour when the user changes theirs.
    // `fillColor` keeps the NSColor and re-resolves it.
    let badge = NSBox()
    badge.boxType = .custom
    badge.borderType = .noBorder
    badge.cornerRadius = 9
    badge.fillColor = .controlAccentColor
    badge.titlePosition = .noTitle
    badge.contentViewMargins = .zero
    badge.translatesAutoresizingMaskIntoConstraints = false
    let badgeHost = NSView()
    badgeHost.translatesAutoresizingMaskIntoConstraints = false
    badgeHost.addSubview(number)
    badge.contentView = badgeHost
    NSLayoutConstraint.activate([
        badge.widthAnchor.constraint(equalToConstant: 18),
        badge.heightAnchor.constraint(equalToConstant: 18),
        badgeHost.topAnchor.constraint(equalTo: badge.topAnchor),
        badgeHost.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
        badgeHost.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
        badgeHost.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
        number.centerXAnchor.constraint(equalTo: badgeHost.centerXAnchor),
        number.centerYAnchor.constraint(equalTo: badgeHost.centerYAnchor),
    ])

    let body = NSTextField(wrappingLabelWithString: text)
    body.font = UI.body
    body.textColor = .labelColor
    body.preferredMaxLayoutWidth = 380
    body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let line = NSStackView(views: [badge] + keys.map(keyCap) + [body])
    // A key cap is a box and a box has no baseline, so `.firstBaseline` hangs
    // the keys off the bottom of the text they belong with. Tops line up.
    line.alignment = keys.isEmpty ? .firstBaseline : .top
    line.spacing = 6
    line.translatesAutoresizingMaskIntoConstraints = false
    return line
}

/// A keystroke, drawn as a key.
func keyCap(_ s: String) -> NSView {
    let f = NSTextField(labelWithString: s)
    f.font = .systemFont(ofSize: 11, weight: .medium)
    f.alignment = .center
    f.textColor = .labelColor
    f.translatesAutoresizingMaskIntoConstraints = false
    let box = NSBox()
    box.boxType = .custom
    box.borderType = .lineBorder
    box.borderWidth = 1
    box.cornerRadius = 4
    box.fillColor = .quaternaryLabelColor
    box.borderColor = .separatorColor
    box.titlePosition = .noTitle
    box.contentViewMargins = .zero
    box.translatesAutoresizingMaskIntoConstraints = false
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(f)
    box.contentView = host
    // An NSBox given an Auto Layout contentView and nothing else has a fitting
    // size of zero — it does not constrain the view it was handed. The keys
    // then stack on top of one another and on top of the text beside them,
    // which is precisely what they did. Same trap as `Card`.
    NSLayoutConstraint.activate([
        f.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
        f.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -2),
        f.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
        f.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
        host.topAnchor.constraint(equalTo: box.topAnchor),
        host.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        host.leadingAnchor.constraint(equalTo: box.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: box.trailingAnchor),
    ])
    box.setContentCompressionResistancePriority(.required, for: .horizontal)
    box.setContentHuggingPriority(.required, for: .horizontal)
    return box
}

// MARK: - The pane

final class ElementsPane: Pane {

    override var title_: String { "Elements" }
    override var symbol: String { "rectangle.3.group" }

    private var grid: DesktopGridView!
    private var well: ScreenshotWell!
    private var statusLabel: NSTextField!
    private var selectionLabel: NSTextField!
    private var detailText: NSTextView?
    private var spinner: NSProgressIndicator!
    private var removeButton: NSButton!

    private var dockCheck: NSButton!
    private var widgetsCheck: NSButton!
    private var menuBarCheck: NSButton!
    private var furnitureS: LabelledSlider!
    private var paneCheck: NSButton!
    private var paneS: LabelledSlider!
    private var furnitureRows: [NSView] = []
    private var paneRows: [NSView] = []

    /// The last detection, kept only so the log can be shown.
    private var lastDetection: DetectedDesktop?

    /// Detection is off the main thread; this guards against a second image
    /// being handed in while the first is still being read.
    private var detecting = false

    override func build() {
        // ---- the pinned grid
        //
        // The grid is this pane's hero. It is also its primary control, so
        // pinning it means the thing being edited never scrolls away from the
        // switches that light it up.
        grid = DesktopGridView(width: 320)
        grid.onLiveChange = { [weak self] in self?.updateSelectionLabel() }
        grid.onCommit = { [weak self] in self?.gridEdited() }
        grid.onSelectionChange = { [weak self] in
            self?.updateSelectionLabel()
            self?.updateRemoveState()
        }
        installHeader(grid, caption:
            "Your screen, and the things on it that weather has to land on. Drag a rectangle "
          + "to move it, take a handle to resize it, ⌫ to remove it. It clicks as it lands on "
          + "a guide.")

        // ---- setup
        well = ScreenshotWell()
        well.onImage = { [weak self] img, url in self?.accept(img, from: url) }

        let chooseButton = NSButton(title: "Choose Screenshot…", target: self,
                                    action: #selector(chooseFile))
        chooseButton.bezelStyle = .rounded
        chooseButton.font = UI.body

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString:
            "No screenshot yet. Everything below can also be placed by hand.")
        statusLabel.font = UI.caption
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 420

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let setup = Card("Find your dock and widgets", symbol: "viewfinder")
        setup.add(captionLabel(
            "macOS will not tell an app where your dock and desktop widgets are, so show it a "
          + "picture instead. This takes about fifteen seconds."))
        setup.add(stepRow(1, "Click any empty part of your wallpaper. That is what pushes your "
                           + "windows aside and shows the desktop."))
        setup.add(stepRow(2, "captures the whole screen to your Desktop folder.",
                          keys: ["⌘", "⇧", "3"]))
        setup.add(stepRow(3, "Drop that file below, or pick it with the button."))
        setup.add(well)
        setup.add(NSStackView(views: [chooseButton]))
        setup.add(statusRow)
        setup.note("⌘⇧3 rather than ⌘⇧4: the crosshair with Space captures one WINDOW, and the "
                 + "window under the pointer on an empty desktop is the wallpaper — with no dock "
                 + "and no widgets in it, which is the one thing this needs. "
                 + "Detection is a guess made from edges and contrast: it finds slabs that are "
                 + "calmer inside than the wallpaper around them. Expect it to miss one and to "
                 + "invent one — the grid above is where that is put right.")
        addCard(setup)

        // ---- the grid's own controls
        let addButton = NSButton(title: "Add Widget", target: self, action: #selector(addWidget))
        addButton.bezelStyle = .rounded
        addButton.font = UI.body
        removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.font = UI.body
        removeButton.isEnabled = false
        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clearButton.bezelStyle = .rounded
        clearButton.font = UI.body

        selectionLabel = NSTextField(wrappingLabelWithString: "")
        selectionLabel.font = UI.caption
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.preferredMaxLayoutWidth = 420

        // The one that matters. The miniature in the header is big enough to
        // CHECK a placement and far too small to make one — a widget on a
        // 4112px display is a few points across up there — so the real editing
        // happens in a sheet that gives it the whole window.
        let bigButton = NSButton(title: "Edit at Full Size…", target: self,
                                 action: #selector(editPlacements))
        bigButton.bezelStyle = .rounded
        bigButton.keyEquivalent = "\r"
        bigButton.font = UI.body

        let buttons = NSStackView(views: [bigButton, addButton, removeButton, clearButton])
        buttons.spacing = 8

        let edit = Card("Placement", symbol: "hand.draw")
        edit.add(buttons)
        edit.add(selectionLabel)
        edit.note("Arrow keys nudge the selection, ⌥-arrow moves it a hair, ⇧-arrow moves it "
                + "further, Tab steps through them. Rectangles snap to the screen's edges and "
                + "centre, to a twelfth-of-a-screen grid, and to each other"
                + (Haptics.available ? ", and the trackpad clicks each time one catches." : "."))
        addCard(edit)

        // ---- what weather does to them
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

        dockCheck = check("Dock", #selector(changed))
        widgetsCheck = check("Desktop widgets", #selector(changed))
        menuBarCheck = check("Menu bar", #selector(changed))
        furnitureS = detentSlider("Strength", 0...1, #selector(changed), pct)
        furnitureRows = [furnitureS.container]

        let furniture = Card("What weather does to them", symbol: "cloud.rain")
        furniture.add(captionLabel(
            "Rain, spray and snow gather around the edges of whatever is switched on here — a wet "
          + "band along the lip of the dock, snow lying on a widget, frost blooming out from the "
          + "menu bar. Switching one off makes weather fall straight past it."))
        furniture.add(dockCheck)
        furniture.add(widgetsCheck)
        furniture.add(menuBarCheck)
        furniture.add(furnitureS.container)
        furniture.note("The menu bar is off by default: it is the one strip that is always there "
                     + "whatever you are doing, and water on it reads as a UI glitch rather than "
                     + "as weather. Strength dials the whole effect back without turning it off.")
        addCard(furniture)

        // ---- the glass
        paneCheck = check("Water on the screen itself", #selector(changed))
        paneS = detentSlider("Strength", 0...1, #selector(changed), pct)
        paneRows = [paneS.container]

        let glass = Card("Water on the glass", symbol: "drop.degreesign")
        glass.add(captionLabel("Droplets clinging, running and beading on the screen, as though you "
                             + "were looking at the sky through a window. Not furniture — the whole "
                             + "pane — but it is the other thing rain does to your desktop."))
        glass.add(paneCheck)
        glass.add(paneS.container)
        glass.note("Turning this off leaves the sky alone entirely.")
        addCard(glass)
    }

    /// A slider whose detents you can feel. Same wiring as `Pane.slider`, with
    /// the tick-crossing haptic added — the strength sliders have real stops at
    /// every tenth and nothing on screen says so.
    private func detentSlider(_ title: String, _ range: ClosedRange<Double>,
                              _ action: Selector,
                              _ format: @escaping (Double) -> String) -> LabelledSlider {
        let ls = LabelledSlider(range: range, format: format, slider: DetentSlider())
        ls.slider.target = self
        ls.slider.action = action
        ls.container = formRow(title, ls.box)
        return ls
    }

    // MARK: - Sync

    override func sync(_ c: Config) {
        dockCheck.state = c.wetDock ? .on : .off
        widgetsCheck.state = c.wetWidgets ? .on : .off
        menuBarCheck.state = c.wetMenuBar ? .on : .off
        furnitureS.value = c.furnitureWetness
        paneCheck.state = c.paneWater ? .on : .off
        paneS.value = c.paneWaterAmount
        (furnitureS.slider as? DetentSlider)?.resyncDetent()
        (paneS.slider as? DetentSlider)?.resyncDetent()

        grid.widgets = c.widgets
        grid.dock = c.dockRect.map {
            CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.w), height: CGFloat($0.h))
        } ?? grid.dock ?? Self.estimatedDock()
        grid.menuBarHeight = Self.estimatedMenuBar()
        redraw(c)
        updateSelectionLabel()
        updateRemoveState()
    }

    private func redraw(_ c: Config) {
        grid.wetDock = c.wetDock
        grid.wetWidgets = c.wetWidgets
        grid.wetMenuBar = c.wetMenuBar
        grid.strength = CGFloat(c.furnitureWetness)
        // A strength slider with nothing switched on has nothing to strengthen.
        UI.setHidden(furnitureRows, !(c.wetDock || c.wetWidgets || c.wetMenuBar))
        UI.setHidden(paneRows, !c.paneWater)
    }

    private func updateSelectionLabel() {
        selectionLabel.stringValue = grid.selectionDescription
    }

    private func updateRemoveState() {
        removeButton.isEnabled = grid.canRemoveSelection
    }

    // MARK: - Where the dock and menu bar start out
    //
    // Before any screenshot has been handed in, the grid still has to show
    // something true. These are the same two facts `Furniture.desktop` works
    // from — the screen's insets and com.apple.dock — expressed as fractions.
    // They are an ESTIMATE, which is exactly why the grid is editable.

    static func estimatedMenuBar() -> CGFloat {
        guard let s = NSScreen.main, s.frame.height > 1 else { return 0.025 }
        return max(0, (s.frame.maxY - s.visibleFrame.maxY) / s.frame.height)
    }

    static func estimatedDock() -> CGRect? {
        guard let s = NSScreen.main, s.frame.height > 1, s.frame.width > 1 else { return nil }
        let f = s.frame, v = s.visibleFrame
        let d = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        let tile = CGFloat((d["tilesize"] as? NSNumber)?.doubleValue ?? 55)
        let items = CGFloat(max(1, ((d["persistent-apps"] as? [Any])?.count ?? 0)
                                 + ((d["persistent-others"] as? [Any])?.count ?? 0) + 1))
        let orientation = (d["orientation"] as? String) ?? "bottom"
        let bottom = (v.minY - f.minY) / f.height
        let left = (v.minX - f.minX) / f.width
        let right = (f.maxX - v.maxX) / f.width

        func span(_ available: CGFloat, _ pitch: CGFloat) -> CGFloat {
            min(available * 0.96, (items * tile * 1.09 + tile) / pitch)
        }
        switch orientation {
        case "left" where left > 0.002:
            let h = span(1, f.height)
            return CGRect(x: 0, y: (1 - h) / 2, width: left, height: h)
        case "right" where right > 0.002:
            let h = span(1, f.height)
            return CGRect(x: 1 - right, y: (1 - h) / 2, width: right, height: h)
        default:
            guard bottom > 0.002 else { return nil }
            let w = span(1, f.width)
            return CGRect(x: (1 - w) / 2, y: 1 - bottom, width: w, height: bottom)
        }
    }

    // MARK: - Screenshot in, rectangles out

    @objc private func chooseFile() { well.choose() }

    /// Take an image and read it. The reading is NOT done here — see the note
    /// at the top of this file about heavy work and drawing threads.
    func accept(_ image: NSImage, from url: URL?) {
        guard !detecting else { return }
        well.showThumbnail(image)
        grid.backdrop = image

        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            statusLabel.stringValue = "That file could not be read as an image."
            return
        }
        // A screenshot of one display should be about the shape of that display.
        // Anything wildly off is a cropped shot or a photo, and detection's
        // fractions would be meaningless against the real screen.
        if let s = NSScreen.main, s.frame.height > 1 {
            let want = s.frame.width / s.frame.height
            let got = CGFloat(cg.width) / CGFloat(max(1, cg.height))
            if abs(want - got) / want > 0.12 {
                statusLabel.stringValue =
                    "That picture is not the shape of your display, so the rectangles would land "
                  + "in the wrong places. Capture the whole screen: ⌘⇧4, then Space, then click."
                return
            }
        }

        detecting = true
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Reading the screenshot…"
        let started = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FurnitureDetector.detect(cg)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.detecting = false
                self.spinner.stopAnimation(nil)
                self.lastDetection = result
                self.statusLabel.stringValue = result.summary
                    + String(format: " (%.0f ms) Drag anything it got wrong.", ms)
                guard !result.isEmpty else { return }
                self.grid.adopt(result)
            }
        }
    }

    // MARK: - Actions

    @objc private func addWidget() { grid.addWidget() }
    @objc private func removeSelected() { grid.removeSelected() }
    @objc private func clearAll() { grid.clearAll() }

    /// Open the full-size editor. Exposed for the harness, which cannot click.
    @objc func editPlacements() {
        let ed = PlacementEditor()
        ed.adopt(grid)
        ed.onChange = { [weak self] g in
            guard let self else { return }
            self.grid.widgets = g.widgets
            self.grid.dock = g.dock
            self.gridEdited()
        }
        presentAsSheet(ed)
    }

    /// The editor as it would be presented, for the harness. Not used by the
    /// app, which goes through `editPlacements`.
    func makePlacementEditor() -> PlacementEditor {
        let ed = PlacementEditor()
        ed.adopt(grid)
        return ed
    }

    /// The grid finished a gesture. One commit per gesture, never per frame.
    private func gridEdited() {
        guard var c = owner?.config else { return }
        c.widgets = grid.widgets
        // Only store a dock override when the dock has actually been MOVED off
        // the estimate. Storing the estimate itself would look harmless and is
        // not: `dockRect` is a fraction with no display attached, so it would
        // be applied to every screen — putting a dock-shaped collision surface
        // along the bottom of a second display that has no dock on it.
        c.dockRect = {
            guard let d = grid.dock else { return nil }
            if let e = Self.estimatedDock(), abs(e.minX - d.minX) < 0.005,
               abs(e.minY - d.minY) < 0.005, abs(e.width - d.width) < 0.005,
               abs(e.height - d.height) < 0.005 { return nil }
            return WidgetRect(x: Float(d.minX), y: Float(d.minY),
                              w: Float(d.width), h: Float(d.height))
        }()
        updateSelectionLabel()
        updateRemoveState()
        owner?.commit(c, from: self)
    }

    @objc private func changed() {
        guard var c = owner?.config else { return }
        c.wetDock = dockCheck.state == .on
        c.wetWidgets = widgetsCheck.state == .on
        c.wetMenuBar = menuBarCheck.state == .on
        c.furnitureWetness = furnitureS.value
        c.paneWater = paneCheck.state == .on
        c.paneWaterAmount = paneS.value
        furnitureS.refresh()
        paneS.refresh()
        redraw(c)
        owner?.commit(c, from: self)
    }
}

// MARK: - The full-size editor

/// Placements, on a sheet, at a size you can actually work at.
///
/// The complaint was exact: correcting a widget rectangle inside a 320pt strip
/// pinned to the top of a settings pane means dragging something a handful of
/// points across, and that is not editing, it is fiddling. So the pane's
/// miniature keeps its job — showing at a glance what is placed and what is lit
/// up — and the actual work moves here, where the same screen is drawn more
/// than twice as wide and four and a half times the area, with handles scaled
/// to match (see `DesktopGridView.handleRadius`).
///
/// Nothing about the interaction changes. This is the same `DesktopGridView`
/// class with the same snapping, the same dashed guides, the same haptic on the
/// transition into a snap and the same commit on mouse-up. Only the size and
/// the reach are different.
final class PlacementEditor: NSViewController {

    /// Points across. Sized to sit inside the settings window's 860pt content
    /// width with room for the sheet's own margins.
    static let gridWidth: CGFloat = 700

    let grid = DesktopGridView(width: PlacementEditor.gridWidth)

    /// Fires on every committed gesture, so the wallpaper follows the edit
    /// rather than waiting for the sheet to be dismissed.
    var onChange: ((DesktopGridView) -> Void)?

    private let selectionLabel = NSTextField(wrappingLabelWithString: "")
    private var removeButton: NSButton!

    /// Copy the pane's grid in, state and all.
    func adopt(_ other: DesktopGridView) {
        grid.widgets = other.widgets
        grid.dock = other.dock
        grid.menuBarHeight = other.menuBarHeight
        grid.wetDock = other.wetDock
        grid.wetWidgets = other.wetWidgets
        grid.wetMenuBar = other.wetMenuBar
        grid.strength = other.strength
        grid.backdrop = other.backdrop
    }

    override func loadView() {
        grid.onLiveChange = { [weak self] in self?.refreshLabels() }
        grid.onCommit = { [weak self] in
            guard let self else { return }
            self.refreshLabels()
            self.onChange?(self.grid)
        }
        grid.onSelectionChange = { [weak self] in self?.refreshLabels() }

        let add = NSButton(title: "Add Widget", target: self, action: #selector(addWidget))
        add.bezelStyle = .rounded
        add.font = UI.body
        removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.font = UI.body
        let clear = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        clear.font = UI.body
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.font = UI.body

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [add, removeButton, clear, spacer, done])
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        selectionLabel.font = UI.caption
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.preferredMaxLayoutWidth = Self.gridWidth

        let column = NSStackView(views: [
            headlineLabel("Placements"),
            captionLabel("Drag a rectangle to move it, take a corner to resize it. Arrow keys nudge "
                       + "the selection, ⌥-arrow a hair, ⇧-arrow further; Tab steps through them and "
                       + "⌫ removes one." + (Haptics.available
                            ? " The trackpad clicks each time an edge catches a guide." : ""),
                         width: Self.gridWidth),
            grid,
            selectionLabel,
            buttons,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        view = host
        refreshLabels()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // So the arrow keys work without the user having to find something to
        // click on first.
        view.window?.makeFirstResponder(grid)
    }

    private func refreshLabels() {
        selectionLabel.stringValue = grid.selectionDescription
        removeButton?.isEnabled = grid.canRemoveSelection
    }

    @objc private func addWidget() { grid.addWidget() }
    @objc private func removeSelected() { grid.removeSelected() }
    @objc private func clearAll() { grid.clearAll() }
    @objc private func finish() { dismiss(self) }
}
