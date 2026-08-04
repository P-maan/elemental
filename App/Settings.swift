//  Settings.swift — the control surface.
//
//  A sidebar-style preferences window, the shape modern System Settings uses:
//  an NSSplitViewController with a source list on the left and one pane on the
//  right. AppKit has no built-in sidebar tab style — NSTabViewController only
//  offers toolbar and segmented — so the split view is the way to get it.
//
//  The three surfaces Elemental draws (desktop, lock screen, screen saver) get
//  a pane each, and they share one class rather than three copies of the same
//  controls; `role` is the only thing that differs.
//
//  Reachable two ways, so hiding the menu-bar item never locks you out: the
//  menu-bar item, or launching Elemental again from Spotlight or Finder (see
//  applicationShouldHandleReopen in main.swift).

import AppKit
import ServiceManagement
import MapKit

// MARK: - Shared form building
//
// Small helpers so every pane lays out identically. Labels are a fixed width so
// controls line up down the window, which is most of what makes a settings
// window look deliberate rather than assembled.

class Pane: NSViewController {

    let stack = NSStackView()
    weak var owner: SettingsWindowController?

    /// Sidebar presentation.
    var title_: String { "" }
    var symbol: String { "gearshape" }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        view = scroll
        build()
    }

    /// Subclasses populate `stack` here.
    func build() {}
    /// Called whenever the config changes underneath the pane.
    ///
    /// Only ever call this through `syncSafely` — NSViewController loads its
    /// view lazily, so a pane the user has not visited yet has run neither
    /// `loadView` nor `build`, and every control is still nil.
    func sync(_ config: Config) {}

    /// Force the view (and therefore `build`) before syncing.
    func syncSafely(_ config: Config) {
        loadViewIfNeeded()
        sync(config)
    }

    // ---- builders

    func section(_ t: String) -> NSView {
        let f = NSTextField(labelWithString: t)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        let box = NSStackView(views: [f])
        box.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        return box
    }

    func note(_ t: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: t)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 380
        return f
    }

    func row(_ title: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 108).isActive = true
        let s = NSStackView(views: [l, control])
        s.spacing = 12
        s.alignment = .centerY
        return s
    }

    func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return b
    }

    func popup(_ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.target = self; p.action = action
        return p
    }

    func check(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    /// A slider with its value written out beside it, as a settings row.
    ///
    /// Six of the relief controls are the same shape, and building them by hand
    /// six times is how the labels drift out of step with the sliders.
    func slider(_ title: String, _ range: ClosedRange<Double>,
                _ action: Selector, _ format: @escaping (Double) -> String) -> LabelledSlider {
        let ls = LabelledSlider(range: range, format: format)
        ls.slider.target = self; ls.slider.action = action
        ls.container = row(title, ls.box)
        return ls
    }
}

/// Slider plus its read-out. `value` keeps the two in step in both directions.
final class LabelledSlider {
    let slider = NSSlider()
    let label = NSTextField(labelWithString: "")
    let box = NSStackView()
    /// The full row, for showing and hiding.
    var container: NSView!
    private let format: (Double) -> String

    init(range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.format = format
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        box.setViews([slider, label], in: .leading)
        box.spacing = 8
        box.alignment = .centerY
    }

    /// Rounded to two decimals so the stored config does not accumulate the
    /// slider's float noise.
    var value: Double {
        get { (slider.doubleValue * 100).rounded() / 100 }
        set { slider.doubleValue = newValue; label.stringValue = format(newValue) }
    }

    func refresh() { label.stringValue = format(value) }
}

// MARK: - General

final class GeneralPane: Pane {

    override var title_: String { "General" }
    override var symbol: String { "gearshape" }

    private var loginCheck: NSButton!
    private var fpsPop: NSPopUpButton!
    private var speedPop: NSPopUpButton!
    private var replayPop: NSPopUpButton!
    private var occludedCheck: NSButton!
    private var lowPowerCheck: NSButton!
    private var lockSyncCheck: NSButton!

    // Relief. Six controls over one wall of blocks; `glassOnly` are the three
    // that need something to transmit and so mean nothing on a flat tile.
    private var depthS: LabelledSlider!
    private var angleS: LabelledSlider!
    private var lightS: LabelledSlider!
    private var refractS: LabelledSlider!
    private var dispersS: LabelledSlider!
    private var frostS: LabelledSlider!
    private var splayS: LabelledSlider!
    private var glassOnly: [NSView] = []

    static let fpsChoices = [10, 15, 30, 60, 120]
    static let speedChoices: [(String, Double)] = [
        ("Glacial — 0.15×", 0.15), ("Very slow — 0.3×", 0.3), ("Slow — 0.6×", 0.6),
        ("Real time", 1.0), ("Brisk — 1.5×", 1.5),
    ]
    static let replayChoices: [(String, Double)] = [
        ("Off", 0), ("Flick — 2s", 2), ("Normal — 5s", 5), ("Slow — 10s", 10), ("Cinematic — 20s", 20),
    ]

    override func build() {
        stack.addArrangedSubview(section("Startup"))
        loginCheck = check("Open Elemental at login", #selector(loginToggled))
        stack.addArrangedSubview(loginCheck)
        stack.addArrangedSubview(note("Elemental has no Dock icon. Launching it again from Spotlight or "
                                    + "Finder reopens these settings."))

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(section("Relief"))
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

        depthS = slider("Depth", 0...1, #selector(changed), pct)
        stack.addArrangedSubview(depthS.container)
        angleS = slider("Light angle", -180...180, #selector(changed)) { "\(Int($0.rounded()))°" }
        stack.addArrangedSubview(angleS.container)
        lightS = slider("Light", 0...1, #selector(changed), pct)
        stack.addArrangedSubview(lightS.container)
        splayS = slider("Splay", 0...1, #selector(changed), pct)
        stack.addArrangedSubview(splayS.container)
        stack.addArrangedSubview(note("Every cell is a block pushed out of the wall by its own brightness, "
                                    + "so the sky's clouds and the moon emboss the mosaic instead of only "
                                    + "colouring it. Depth is how far they stand out; the light angle and "
                                    + "strength shade their side faces and the crevices between them; splay "
                                    + "unsettles the courses so the wall is not perfectly regular."))

        refractS = slider("Refraction", 0...1, #selector(changed), pct)
        stack.addArrangedSubview(refractS.container)
        dispersS = slider("Dispersion", 0...1, #selector(changed), pct)
        stack.addArrangedSubview(dispersS.container)
        frostS = slider("Frost", 0...1, #selector(changed), pct)
        stack.addArrangedSubview(frostS.container)
        let glassNote = note("Refraction is how far you see THROUGH each block, so what lands on its face "
                           + "is the wall a little way behind — the further from the centre of the screen, "
                           + "the further off. Dispersion splits that per colour and fringes the edges; "
                           + "frost scatters it.")
        stack.addArrangedSubview(glassNote)
        // These three describe light passing through a block. A flat tile is
        // opaque, so they are hidden rather than left sitting there doing
        // nothing — a dead control is worse than a missing one.
        glassOnly = [refractS.container, dispersS.container, frostS.container, glassNote]

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(section("Motion"))
        fpsPop = popup(Self.fpsChoices.map { "\($0) fps" }, #selector(changed))
        stack.addArrangedSubview(row("Frame rate", fpsPop))
        speedPop = popup(Self.speedChoices.map(\.0), #selector(changed))
        stack.addArrangedSubview(row("Speed", speedPop))
        stack.addArrangedSubview(note("Frame rate is how often it is drawn; speed is how fast the world "
                                    + "runs. Lowering the frame rate saves power; slowing the motion costs "
                                    + "nothing and simply reads calmer."))

        replayPop = popup(Self.replayChoices.map(\.0), #selector(changed))
        stack.addArrangedSubview(row("Wake replay", replayPop))
        stack.addArrangedSubview(note("After sleep or a closed lid, the scene replays the hours it missed "
                                    + "as a time-lapse before settling into now. Gaps under ten minutes "
                                    + "always resume instantly."))

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(section("Power"))
        occludedCheck = check("Keep drawing when fully covered", #selector(changed))
        lowPowerCheck = check("Reduce detail and frame rate in Low Power Mode", #selector(changed))
        stack.addArrangedSubview(occludedCheck)
        stack.addArrangedSubview(lowPowerCheck)
        stack.addArrangedSubview(note("Behind a fullscreen app Elemental pauses but is never unloaded, so "
                                    + "coming back is a single frame with no reload."))

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(section("Lock screen"))
        lockSyncCheck = check("Show the scene on the lock screen", #selector(changed))
        stack.addArrangedSubview(lockSyncCheck)
        stack.addArrangedSubview(note("Replaces your desktop picture with a still of the scene, refreshed "
                                    + "every minute and again the moment you lock. macOS does not permit "
                                    + "animation behind the password field — the screen saver is the only "
                                    + "animated surface at the lock."))
    }

    override func sync(_ c: Config) {
        loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        fpsPop.selectItem(at: Self.fpsChoices.firstIndex(of: c.maxFPS) ?? 2)
        speedPop.selectItem(at: Self.speedChoices.firstIndex { abs($0.1 - c.motionSpeed) < 0.001 } ?? 3)
        replayPop.selectItem(at: c.playbackOnWake
            ? (Self.replayChoices.firstIndex { abs($0.1 - c.playbackMaxSeconds) < 0.001 } ?? 2) : 0)
        occludedCheck.state = c.renderWhenOccluded ? .on : .off
        lowPowerCheck.state = c.lowPowerOnBattery ? .on : .off
        lockSyncCheck.state = c.syncLockScreen ? .on : .off
        depthS.value = c.reliefDepth
        angleS.value = c.lightAngle
        lightS.value = c.lightIntensity
        splayS.value = c.splay
        refractS.value = c.refraction
        dispersS.value = c.dispersion
        frostS.value = c.frost
        // The desktop's finish decides it: the lock screen and saver can differ,
        // but this is one shared wall and the pane it lives on is the general one.
        let glass = c.finish == .glass
        for v in glassOnly { v.isHidden = !glass }
    }

    @objc private func loginToggled() {
        do {
            if loginCheck.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change the login item"
            a.informativeText = "\(error.localizedDescription)\n\nYou can also set this in "
                              + "System Settings › General › Login Items."
            a.runModal()
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func changed() {
        guard var c = owner?.config else { return }
        c.maxFPS = Self.fpsChoices[max(0, min(Self.fpsChoices.count - 1, fpsPop.indexOfSelectedItem))]
        c.motionSpeed = Self.speedChoices[max(0, min(Self.speedChoices.count - 1, speedPop.indexOfSelectedItem))].1
        let rp = Self.replayChoices[max(0, min(Self.replayChoices.count - 1, replayPop.indexOfSelectedItem))]
        c.playbackOnWake = rp.1 > 0
        if rp.1 > 0 { c.playbackMaxSeconds = rp.1 }
        c.renderWhenOccluded = occludedCheck.state == .on
        c.lowPowerOnBattery = lowPowerCheck.state == .on
        c.syncLockScreen = lockSyncCheck.state == .on
        c.reliefDepth = depthS.value
        c.lightAngle = angleS.value.rounded()
        c.lightIntensity = lightS.value
        c.splay = splayS.value
        c.refraction = refractS.value
        c.dispersion = dispersS.value
        c.frost = frostS.value
        for s in [depthS, angleS, lightS, splayS, refractS, dispersS, frostS] { s?.refresh() }
        owner?.commit(c, from: self)
    }
}

// MARK: - A surface's appearance
//
// One class, three instances. `role` decides whether it offers the mimic
// checkbox at all — the desktop is the thing being mimicked, so it does not.

final class SurfacePane: Pane {

    enum Role { case desktop, lock, saver }

    private let role: Role
    private let blurb: String
    private let paneTitle: String
    private let paneSymbol: String

    override var title_: String { paneTitle }
    override var symbol: String { paneSymbol }

    private var mirrorCheck: NSButton!
    private var shapePop: NSPopUpButton!
    private var finishPop: NSPopUpButton!
    private var rowsField: NSTextField!
    private var rowsStepper: NSStepper!
    private var headingPop: NSPopUpButton!
    private var facingSlider: NSSlider!
    private var facingLabel: NSTextField!
    private var facingRow: NSView!
    private var placePop: NSPopUpButton!
    private var bodyViews: [NSView] = []
    private var places: [Place] = []

    init(role: Role, title: String, symbol: String, blurb: String) {
        self.role = role
        self.paneTitle = title
        self.paneSymbol = symbol
        self.blurb = blurb
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(note(blurb))

        if role != .desktop {
            mirrorCheck = check("Mimic Home Screen settings", #selector(mirrorToggled))
            stack.addArrangedSubview(mirrorCheck)
        }

        shapePop = popup(MosaicShape.allCases.map { "\($0)".capitalized }, #selector(changed))
        finishPop = popup(MosaicFinish.allCases.map { "\($0)".capitalized }, #selector(changed))

        rowsField = NSTextField()
        rowsField.formatter = { let f = NumberFormatter(); f.allowsFloats = false
                                f.minimum = 12; f.maximum = 120; return f }()
        rowsField.widthAnchor.constraint(equalToConstant: 58).isActive = true
        rowsField.target = self; rowsField.action = #selector(rowsTyped)
        rowsStepper = NSStepper()
        rowsStepper.minValue = 12; rowsStepper.maxValue = 120; rowsStepper.increment = 1
        rowsStepper.target = self; rowsStepper.action = #selector(stepperChanged)
        let rowsBox = NSStackView(views: [rowsField, rowsStepper]); rowsBox.spacing = 4

        headingPop = popup(HeadingMode.allCases.map(\.title), #selector(changed))

        facingSlider = NSSlider()
        facingSlider.minValue = 0; facingSlider.maxValue = 359
        facingSlider.target = self; facingSlider.action = #selector(changed)
        facingSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        facingLabel = NSTextField(labelWithString: "")
        facingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        facingLabel.textColor = .secondaryLabelColor
        let facingBox = NSStackView(views: [facingSlider, facingLabel]); facingBox.spacing = 8
        facingRow = row("Facing", facingBox)

        placePop = popup([], #selector(changed))

        bodyViews = [divider(), section("Mosaic"),
                     row("Shape", shapePop), row("Finish", finishPop), row("Rows", rowsBox),
                     note("Cells down the screen. The Pi uses 36; more rows is a finer grid."),
                     divider(), section("Sky"),
                     row("Heading", headingPop), facingRow,
                     note("Custom looks one way and lets the sky drift past. Dynamic follows whatever is "
                        + "up — the sun by day, the moon once it has risen — panning between them at dusk."),
                     row("Show sky over", placePop)]
        bodyViews.forEach { stack.addArrangedSubview($0) }
    }

    private func style(from c: Config) -> Config.SurfaceStyle {
        switch role {
        case .desktop:
            return Config.SurfaceStyle(mirrorsDesktop: false, shape: c.shape, finish: c.finish,
                                       gridRows: c.gridRows, poster: c.poster,
                                       headingMode: c.headingMode, facingAz: c.facingAz,
                                       scenePlaceName: c.scenePlaceName)
        case .lock:  return c.lock
        case .saver: return c.saver
        }
    }

    override func sync(_ c: Config) {
        let st = style(from: c)
        places = c.allPlaces
        mirrorCheck?.state = st.mirrorsDesktop ? .on : .off
        shapePop.selectItem(at: Int(st.shape.rawValue))
        finishPop.selectItem(at: Int(st.finish.rawValue))
        rowsField.integerValue = st.gridRows
        rowsStepper.integerValue = st.gridRows
        headingPop.selectItem(at: Int(st.headingMode.rawValue))
        facingSlider.doubleValue = st.facingAz
        facingLabel.stringValue = Self.bearing(st.facingAz)

        placePop.removeAllItems()
        if places.isEmpty {
            placePop.addItem(withTitle: c.effectivePlace.name); placePop.isEnabled = false
        } else {
            placePop.isEnabled = true
            placePop.addItems(withTitles: places.map(\.name))
            let want = st.scenePlaceName ?? c.scenePlace.name
            if let i = places.firstIndex(where: { $0.name == want }) { placePop.selectItem(at: i) }
        }
        applyVisibility(st)
    }

    private func applyVisibility(_ st: Config.SurfaceStyle) {
        let hidden = (role != .desktop) && st.mirrorsDesktop
        for v in bodyViews { v.isHidden = hidden }
        if !hidden { facingRow.isHidden = st.headingMode != .custom }
    }

    private func collect() -> Config.SurfaceStyle {
        var st = owner.map { style(from: $0.config) } ?? Config.SurfaceStyle()
        st.mirrorsDesktop = (role != .desktop) && (mirrorCheck?.state == .on)
        st.shape = MosaicShape(rawValue: Int32(shapePop.indexOfSelectedItem)) ?? .square
        st.finish = MosaicFinish(rawValue: Int32(finishPop.indexOfSelectedItem)) ?? .glass
        st.gridRows = max(12, min(120, rowsField.integerValue))
        st.headingMode = HeadingMode(rawValue: Int32(headingPop.indexOfSelectedItem)) ?? .custom
        st.facingAz = facingSlider.doubleValue.rounded()
        let i = placePop.indexOfSelectedItem
        st.scenePlaceName = (i >= 0 && i < places.count) ? places[i].name : nil
        return st
    }

    private func write(_ st: Config.SurfaceStyle) {
        guard var c = owner?.config else { return }
        switch role {
        case .desktop:
            c.shape = st.shape; c.finish = st.finish; c.gridRows = st.gridRows
            c.poster = st.poster; c.headingMode = st.headingMode
            c.facingAz = st.facingAz; c.scenePlaceName = st.scenePlaceName
        case .lock:  c.lock = st
        case .saver: c.saver = st
        }
        owner?.commit(c, from: self)
    }

    @objc private func mirrorToggled() {
        var st = collect()
        st.mirrorsDesktop = mirrorCheck.state == .on
        applyVisibility(st)
        write(st)
    }

    @objc private func changed() {
        let st = collect()
        facingLabel.stringValue = Self.bearing(st.facingAz)
        facingRow.isHidden = st.headingMode != .custom
        write(st)
    }

    @objc private func stepperChanged() {
        rowsField.integerValue = rowsStepper.integerValue
        write(collect())
    }

    @objc private func rowsTyped() {
        let v = max(12, min(120, rowsField.integerValue))
        rowsField.integerValue = v
        rowsStepper.integerValue = v
        write(collect())
    }

    static func bearing(_ deg: Double) -> String {
        let names = ["N","NE","E","SE","S","SW","W","NW"]
        return String(format: "%3d°  %@", Int(deg), names[Int((deg / 45).rounded()) % 8])
    }
}

// MARK: - Location
//
// Modelled on the Weather app's city picker, which is the native pattern for
// this: a search field that suggests as you type, and underneath it a list of
// the cities you have kept, each showing its own local time. The one table
// swaps between the two — searching replaces the saved list, clearing the field
// brings it back — so there is never a results list and a saved list competing
// for the same space.

final class LocationPane: Pane, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    override var title_: String { "Location" }
    override var symbol: String { "location" }

    private enum Mode { case saved, results, searching, empty }

    private var detectedLabel: NSTextField!
    private var locationButton: NSButton!
    private var searchField: NSSearchField!
    private var table: NSTableView!
    private var statusLabel: NSTextField!
    private var countLabel: NSTextField!
    private var removeButton: NSButton!

    private var mode: Mode = .saved
    /// Guards the selection feedback loop: selecting a row programmatically
    /// fires the same delegate callback a click does, which commits, which
    /// syncs, which selects again — and the app spins forever.
    private var settingSelection = false
    private let search = CitySearch()
    private var results: [MKLocalSearchCompletion] = []
    private var saved: [Place] = []
    private var config = Config()

    /// The completer coalesces internally, so no debounce is needed — results
    /// arrive as you type, which is the whole point.

    override func build() {
        stack.addArrangedSubview(section("Your location"))
        detectedLabel = NSTextField(labelWithString: "—")
        stack.addArrangedSubview(row("Detected", detectedLabel))
        locationButton = NSButton(title: "Use Location Services", target: self,
                                  action: #selector(requestLocation))
        locationButton.bezelStyle = .rounded
        stack.addArrangedSubview(locationButton)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(section("Cities"))

        searchField = NSSearchField()
        searchField.placeholderString = "Search for a city"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(searchField)

        search.onResults = { [weak self] found in
            guard let self, !self.searchField.stringValue.isEmpty else { return }
            self.results = found
            self.mode = found.isEmpty ? .empty : .results
            self.statusLabel.stringValue = found.isEmpty
                ? "No cities found"
                : "\(found.count) result\(found.count == 1 ? "" : "s") — double-click to add"
            self.table.reloadData()
            self.removeButton.isEnabled = false
        }
        search.onFailure = { [weak self] msg in
            self?.statusLabel.stringValue = msg
        }

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 42
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowActivated)
        let col = NSTableColumn(identifier: .init("city"))
        col.width = 380
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(scroll)

        statusLabel = note("")
        stack.addArrangedSubview(statusLabel)

        removeButton = NSButton(title: "Remove City", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        stack.addArrangedSubview(removeButton)

        countLabel = note("")
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(note("The sun, moon and stars are computed from the selected city, so the "
                                    + "wallpaper can show anywhere — not just where you are."))
    }

    // MARK: - Sync

    override func sync(_ c: Config) {
        config = c
        saved = c.allPlaces

        detectedLabel.stringValue = c.place.map {
            "\($0.name)   \(String(format: "%.3f", $0.latitude)), \(String(format: "%.3f", $0.longitude))"
        } ?? "Not set"
        let have = c.place != nil
        locationButton.isEnabled = !have
        locationButton.title = have ? "Location Detected" : "Use Location Services"

        countLabel.stringValue = c.isPlaceListFull
            ? "\(saved.count) of \(Config.maxPlaces) cities — remove one to add another"
            : "\(saved.count) of \(Config.maxPlaces) cities"

        if mode == .saved { table.reloadData(); selectCurrentScene() }
        updateRemoveState()
    }

    private func selectCurrentScene() {
        guard mode == .saved,
              let i = saved.firstIndex(where: { $0.name == config.scenePlace.name }) else { return }
        guard table.selectedRow != i else { return }        // already there
        settingSelection = true
        table.selectRowIndexes([i], byExtendingSelection: false)
        settingSelection = false
    }

    private func updateRemoveState() {
        guard mode == .saved, table.selectedRow >= 0, table.selectedRow < saved.count else {
            removeButton.isEnabled = false; return
        }
        let sel = saved[table.selectedRow].name
        // The detected location is not removable — resetting is what you want.
        removeButton.isEnabled = config.place?.name != sel
                              && config.otherPlaces.contains { $0.name == sel }
    }

    // MARK: - Search

    func controlTextDidChange(_ note: Notification) {
        guard note.object as? NSSearchField === searchField else { return }
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            search.cancel()
            mode = .saved
            results = []
            statusLabel.stringValue = ""
            table.reloadData()
            selectCurrentScene()
            updateRemoveState()
            return
        }
        mode = .searching
        statusLabel.stringValue = "Searching…"
        search.update(q)
    }

    // MARK: - Table

    func numberOfRows(in t: NSTableView) -> Int {
        switch mode {
        case .saved: return saved.count
        case .results: return results.count
        case .searching, .empty: return 0
        }
    }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        // Search hits are completions, not places — they have no coordinates
        // until one is chosen and resolved.
        if mode == .results {
            let c = results[row]
            let title = NSTextField(labelWithString: c.title)
            title.font = .systemFont(ofSize: 13)
            let sub = NSTextField(labelWithString: c.subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            let text = NSStackView(views: [title, sub])
            text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let plus = NSImageView()
            plus.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
            plus.contentTintColor = .secondaryLabelColor
            let cell = NSStackView(views: [text, spacer, plus])
            cell.orientation = .horizontal; cell.alignment = .centerY; cell.spacing = 8
            cell.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
            return cell
        }

        let place = saved[row]
        let isScene = (mode == .saved) && place.name == config.scenePlace.name
        let isDetected = place.name == config.place?.name

        // Primary line: the city. Secondary: what disambiguates it — its local
        // time for a saved city, its coordinates for a search hit.
        let title = NSTextField(labelWithString: place.name)
        title.font = .systemFont(ofSize: 13, weight: isScene ? .semibold : .regular)

        let sub = NSTextField(labelWithString: subtitle(for: place))
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        var views: [NSView] = [text]
        do {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            views.append(spacer)
            if isDetected {
                let pin = NSImageView()
                pin.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Detected")
                pin.contentTintColor = .secondaryLabelColor
                views.append(pin)
            }
            if isScene {
                let tick = NSImageView()
                tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Showing")
                tick.contentTintColor = .controlAccentColor
                views.append(tick)
            }
        }

        let cell = NSStackView(views: views)
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 8
        cell.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        return cell
    }

    /// Saved cities show their own local time, which is the fastest way to tell
    /// two similarly named places apart and useful in its own right. Search hits
    /// show coordinates, since their timezone is not confirmed until added.
    private func subtitle(for p: Place) -> String {
        if mode == .saved, let id = p.timeZone, let tz = TimeZone(identifier: id) {
            let f = DateFormatter()
            f.timeZone = tz
            f.dateFormat = "h:mm a"
            let now = Date()
            let mins = (tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 60
            let delta = mins == 0 ? "same time"
                : String(format: "%+.1fh", Double(mins) / 60)
            return "\(f.string(from: now))  ·  \(delta)"
        }
        return String(format: "%.3f, %.3f", p.latitude, p.longitude)
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !settingSelection else { updateRemoveState(); return }
        guard mode == .saved, table.selectedRow >= 0, table.selectedRow < saved.count else {
            updateRemoveState(); return
        }
        let picked = saved[table.selectedRow].name
        // Only commit a real change. Committing an identical config still
        // triggers a full re-sync, which is work for nothing.
        guard picked != config.scenePlace.name else { updateRemoveState(); return }
        var c = config
        c.scenePlaceName = picked
        owner?.commit(c, from: self)
        updateRemoveState()
    }

    @objc private func rowActivated() {
        guard mode == .results, table.clickedRow >= 0, table.clickedRow < results.count else { return }
        statusLabel.stringValue = "Adding…"
        CitySearch.resolve(results[table.clickedRow]) { [weak self] place in
            guard let self else { return }
            guard let place else {
                self.statusLabel.stringValue = "Could not locate that city"
                return
            }
            self.add(place)
        }
    }

    private func add(_ p: Place) {
        var c = config
        guard c.addPlace(p) else {
            let a = NSAlert()
            a.messageText = "City list is full"
            a.informativeText = "Elemental keeps up to \(Config.maxPlaces) cities. Remove one first."
            a.runModal()
            return
        }
        searchField.stringValue = ""
        mode = .saved
        results = []
        statusLabel.stringValue = ""
        owner?.commit(c, from: self)
        table.reloadData()
        selectCurrentScene()
    }

    // MARK: - Buttons

    @objc private func requestLocation() {
        owner?.delegate?.location.onUnavailable = { msg in
            let a = NSAlert()
            a.messageText = "Location unavailable"
            a.informativeText = msg
            a.runModal()
        }
        owner?.delegate?.location.requestOnce()
    }

    @objc private func removeSelected() {
        guard mode == .saved, table.selectedRow >= 0, table.selectedRow < saved.count else { return }
        var c = config
        c.removePlace(named: saved[table.selectedRow].name)
        owner?.commit(c, from: self)
        table.reloadData()
        selectCurrentScene()
    }
}

// MARK: - Sidebar

final class SidebarController: NSViewController {

    var items: [Pane] = []
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()

    override func loadView() {
        table.headerView = nil
        table.rowHeight = 30
        table.style = .sourceList
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        let col = NSTableColumn(identifier: .init("main"))
        col.width = 172
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        view = scroll
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
    }
}

extension SidebarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let pane = items[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: pane.title_)
        label.font = .systemFont(ofSize: 13)
        let s = NSStackView(views: [icon, label])
        s.spacing = 8
        s.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        return s
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {

    weak var delegate: AppDelegate?
    private(set) var config = Config()
    private var window: NSWindow!
    private var panes: [Pane] = []
    private var split: NSSplitViewController!
    private var contentItem: NSSplitViewItem!

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        build()
    }

    private func build() {
        panes = [
            GeneralPane(),
            SurfacePane(role: .desktop, title: "Home Screen", symbol: "menubar.dock.rectangle",
                        blurb: "The live wallpaper on your desktop — behind your icons, across all Spaces."),
            SurfacePane(role: .lock, title: "Lock Screen", symbol: "lock.display",
                        blurb: "A still behind the password field, refreshed every minute and again the "
                             + "moment you lock. macOS does not allow animation here."),
            SurfacePane(role: .saver, title: "Screen Saver", symbol: "display",
                        blurb: "Fully animated, and the only animated surface that appears at the lock "
                             + "screen — macOS starts it after the idle timer."),
            LocationPane(),
        ]
        panes.forEach { $0.owner = self }

        let sidebar = SidebarController()
        sidebar.items = panes
        sidebar.onSelect = { [weak self] i in self?.select(i) }

        split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 190
        sideItem.maximumThickness = 190
        sideItem.canCollapse = false
        split.addSplitViewItem(sideItem)

        contentItem = NSSplitViewItem(viewController: panes[0])
        split.addSplitViewItem(contentItem)

        let w = NSWindow(contentViewController: split)
        w.title = "Elemental"
        w.styleMask.insert([.closable, .resizable, .fullSizeContentView])
        w.titlebarAppearsTransparent = false
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 720, height: 620))
        w.minSize = NSSize(width: 660, height: 480)
        w.center()
        window = w
    }

    private func select(_ index: Int) {
        guard index >= 0, index < panes.count else { return }
        let pane = panes[index]
        pane.syncSafely(config)
        split.removeSplitViewItem(contentItem)
        contentItem = NSSplitViewItem(viewController: pane)
        split.addSplitViewItem(contentItem)
    }

    func show(config: Config) {
        self.config = config
        panes.forEach { $0.syncSafely(config) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Update without stealing focus — used when something outside Settings
    /// changes the config, Location Services resolving being the usual case.
    func refreshIfVisible(config: Config) {
        guard window?.isVisible == true else { return }
        self.config = config
        panes.forEach { $0.syncSafely(config) }
    }

    /// A pane changed something. Push it out, then re-sync the OTHER panes so
    /// dependent controls (city lists, mimic states) stay consistent.
    ///
    /// Not the originating pane. Writing values back into the control the user
    /// currently has hold of makes a slider fight the mouse — every drag frame
    /// the knob is reassigned the value it just reported, and any rounding on
    /// the way through shows up as the knob lagging or snapping behind the
    /// pointer. A pane that changes something is already consistent with
    /// itself; it is the others that need telling.
    ///
    /// `sender` is nil for changes from outside the panes (a resolved location,
    /// a config reload), and then everything syncs as before.
    func commit(_ newConfig: Config, from sender: Pane? = nil) {
        config = newConfig
        delegate?.applyConfig(newConfig)
        for pane in panes where pane !== sender { pane.syncSafely(newConfig) }
    }
}
