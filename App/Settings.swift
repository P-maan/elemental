//  Settings.swift — the AppKit panes that live inside the settings window.
//
//  The window itself, its sidebar and most of its pages are SwiftUI now — see
//  SettingsUI.swift. What is left here is the AppKit `Pane` base class and the
//  two panes still built on it, Elements (ElementsPane.swift) and Location,
//  which the SwiftUI window hosts as they are.
//
//  Reachable two ways, so hiding the menu-bar item never locks you out: the
//  menu-bar item, or launching Elemental again from Spotlight or Finder (see
//  applicationShouldHandleReopen in main.swift).
//
//  ---- What this window is trying to be
//
//  It had grown a lot of advanced controls, and the complaint was exact:
//  somebody who does not want something this advanced cannot tell what any of
//  it does. "Splay", "Emphasis" and "Dispersion" are not words, they are shader
//  parameters, and a paragraph of prose under a slider is a worse answer than a
//  picture. So the window is now built around SEEING:
//
//    * every pane opens with a HERO — a large live render of the scene exactly
//      as configured, which updates while you drag.
//    * every relief and glass slider carries a none/half/full strip. Click a
//      tile to jump there.
//    * shape and finish are four thumbnails you pick from, not a dropdown of
//      two nouns and two other nouns.
//    * grid density is shown at five densities rather than described as a
//      number of rows.
//
//  Layout vocabulary — cards, hero, type scale, materials — lives in
//  SettingsKit.swift. Thumbnail rendering lives in PreviewRenderer.swift.
//
//  ---- The performance rule
//
//  Settings had a bad lag problem, fixed by splitting cheap live updates from
//  expensive work debounced by ~0.45s, and nothing here may undo that. The
//  worst bug this project has had was the lock-still exporter doing a render
//  and a PNG encode on the animation's runloop, freezing the wallpaper for
//  337ms a minute; a window full of live thumbnails is exactly the shape that
//  could bring it back. It does not, because every render goes through
//  `ScenePreview`: one shared renderer per pixel size, small targets, cached by
//  the parameters that produced the image, superseded requests dropped before
//  they reach the GPU, and all of it on a background queue that hands back
//  nothing but a finished NSImage.
//
//  Measured, on an M1 Pro: 0.73ms a strip tile, 0.80ms an option tile, 2.36ms a
//  hero, plus one 550ms shader compile the first time a preview is asked for.
//  A 120-event drag of one slider — hero live, seven strips behind a 0.35s
//  debounce — costs 1.2ms of MAIN THREAD time in total (0.009ms per event) and
//  138 renders, 2502 of the 2640 requests having been dropped as superseded
//  before reaching the GPU.

import AppKit
import ServiceManagement
import MapKit

// MARK: - Shared form building

class Pane: NSViewController {

    /// The column of cards.
    let stack = NSStackView()
    weak var owner: SettingsWindowController?

    /// Sidebar presentation.
    var title_: String { "" }
    var symbol: String { "gearshape" }

    /// The pinned area above the scroller. Empty and zero-height until a pane
    /// puts something in it.
    ///
    /// The preview used to be the first card in the scrolling column, which put
    /// it off the top of the window the moment you scrolled down to reach the
    /// control you wanted to drag — and the preview matters MOST while that
    /// control is moving. So it is parented outside the scroll view instead.
    /// Nothing about how previews render or cache changes; this is only where
    /// the view hangs.
    private let headerHost = NSVisualEffectView()
    private let headerContent = NSStackView()
    private var headerCollapse: NSLayoutConstraint!

    override func loadView() {
        stack.orientation = .vertical
        // Cards are stretched to the pane width by `addCard`, one explicit
        // constraint each, rather than by a `.width` stack alignment — that
        // alignment produced a pane whose cards all landed on top of one
        // another, with no constraint warning to say so.
        stack.alignment = .leading
        stack.spacing = UI.cardGap
        stack.edgeInsets = NSEdgeInsets(top: UI.paneInset, left: UI.paneInset,
                                        bottom: UI.paneInset + 8, right: UI.paneInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
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

        // Transparent: the pane is hosted inside the SwiftUI window's rounded
        // content panel, which supplies the background.
        let backdrop = NSView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        // ---- the pinned header
        //
        // Its own material and a hairline under it, so it reads as a header
        // rather than as content that failed to scroll.
        headerHost.material = .headerView
        headerHost.blendingMode = .withinWindow
        headerHost.state = .followsWindowActiveState
        headerHost.translatesAutoresizingMaskIntoConstraints = false

        headerContent.orientation = .horizontal
        headerContent.alignment = .centerY
        headerContent.spacing = 16
        headerContent.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        headerHost.addSubview(headerContent)
        headerHost.addSubview(hairline)

        backdrop.addSubview(headerHost)
        backdrop.addSubview(scroll)

        // Collapsed until `installHeader` puts something in it. A pane with no
        // preview then looks exactly as it did before.
        headerCollapse = headerHost.heightAnchor.constraint(equalToConstant: 0)
        headerCollapse.isActive = true

        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: backdrop.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),

            headerContent.topAnchor.constraint(equalTo: headerHost.topAnchor, constant: 14),
            headerContent.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor, constant: -14),
            headerContent.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor,
                                                   constant: UI.paneInset),
            headerContent.trailingAnchor.constraint(lessThanOrEqualTo: headerHost.trailingAnchor,
                                                    constant: -UI.paneInset),

            hairline.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),

            // The scroller takes everything below it. Its content is laid out
            // against its own bounds, so the header cannot eat the last card —
            // no content inset is involved.
            scroll.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        view = backdrop
        build()
    }

    /// Pin `v` above the scroller, with `caption` beside it.
    ///
    /// Beside rather than under: the header's height is the one thing that has
    /// to stay in hand — everything it takes comes out of the controls on a
    /// short window — and a wide window has room to spare horizontally. So the
    /// picture sets the height and the words fill the space next to it.
    func installHeader(_ v: NSView, caption: String) {
        headerCollapse.isActive = false
        headerContent.addArrangedSubview(v)
        let cap = captionLabel(caption, width: 300)
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        headerContent.addArrangedSubview(cap)
    }

    /// Subclasses populate `stack` here, through `addCard`.
    func build() {}

    /// Add a full-width item to the pane's column.
    ///
    /// The width is constrained explicitly against the stack rather than left
    /// to the stack's alignment, so every card ends up the same width and the
    /// column has one clean edge.
    func addCard(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                 constant: -2 * UI.paneInset).isActive = true
    }

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

    // ---- previews
    //
    // Every pane is built and synced eagerly — `syncSafely` forces `loadView`
    // on all of them — but only one is ever in the window. Rendering thumbnails
    // for panes nobody is looking at would be pure cost, so preview work is
    // gated on the pane actually being on screen and caught up when it appears.

    var isPaneVisible: Bool { isViewLoaded && view.window != nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshPreviews()
    }

    /// The hero, if this pane has one. Cheap to update: one coalesced request.
    func updateLivePreview(_ config: Config) {
        guard let hero, let spec = heroSpec(config) else { return }
        hero.show(spec)
    }

    /// The strips and option tiles — a dozen or more renders, so this is
    /// debounced rather than run on every mouse move.
    func updateRangePreviews(_ config: Config) {
        for r in reliefStrips {
            guard var base = heroSpec(config) else { return }
            base.width = Int(ScenePreview.small.width)
            base.height = Int(ScenePreview.small.height)
            base.nightMoon = r.night
            r.strip.show(base) { s, v in s[keyPath: r.key] = PreviewSpec.pct(v) }
            r.strip.mark(current: r.slider.value, tolerance: 0.03)
        }
    }

    /// Everything, at once. For appearing on screen — when a pane is first
    /// shown there is nothing to coalesce with and the user is waiting.
    func refreshPreviews() {
        guard isPaneVisible, let c = owner?.config else { return }
        updateLivePreview(c)
        updateRangePreviews(c)
    }

    /// Everything, but with the expensive half deferred. This is what a value
    /// CHANGE uses.
    ///
    /// `sync` runs on every commit from anywhere, and calling `refreshPreviews`
    /// from it was measurably wrong: a 120-event drag issued 2640 requests and
    /// pushed 997 of them all the way to the GPU, because the undebounced path
    /// re-rendered all 21 strip tiles on every single mouse move. Through here
    /// the same drag costs 121.
    func refreshPreviewsDebounced() {
        guard isPaneVisible, let c = owner?.config else { return }
        updateLivePreview(c)
        scheduleRangePreviews()
    }

    /// Coalesce the expensive half while a control is being worked. Mirrors the
    /// 0.45s settle in AppDelegate.applyConfig, for the same reason.
    private var rangeTimer: Timer?

    func scheduleRangePreviews() {
        rangeTimer?.invalidate()
        rangeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) {
            [weak self] _ in
            self?.rangeTimer = nil
            guard let self, self.isPaneVisible, let c = self.owner?.config else { return }
            self.updateRangePreviews(c)
        }
    }

    // ---- hero

    private(set) var hero: HeroPreview?

    /// The scene this pane's previews should draw. Subclasses override.
    func heroSpec(_ config: Config) -> PreviewSpec? { nil }

    /// Put a hero in the pane's pinned header, with its caption beside it.
    ///
    /// Drawn smaller than the render is: still 800x500 pixels of scene (one
    /// shared renderer, one cache entry) shown at 320x200 points, because the
    /// header's height comes straight out of the space the controls have on a
    /// short window. A preview you can see while you drag the slider beats a
    /// bigger one you cannot.
    func installHero(_ caption: String) {
        let h = HeroPreview(points: HeroPreview.pinnedPoints)
        hero = h
        installHeader(h, caption: caption)
    }

    // ---- relief strips

    /// A relief slider, its none/half/full strip, and the preview field it
    /// varies. Held together so a strip cannot drift out of step with its
    /// slider — the failure mode that makes a picture worse than no picture.
    struct ReliefStrip {
        let slider: LabelledSlider
        let strip: PreviewStrip
        let key: WritableKeyPath<PreviewSpec, Int>
        let night: Bool
    }
    private(set) var reliefStrips: [ReliefStrip] = []

    /// A slider row that shows what the slider does.
    ///
    /// The row itself on top, and under it three thumbnails of this setting at
    /// none, half and full — click one to jump straight to that value. `key` is
    /// the `PreviewSpec` field the strip varies, which is what lets one helper
    /// serve all seven controls without any of them being wired by hand.
    func reliefRow(_ title: String, _ s: LabelledSlider,
                   _ key: WritableKeyPath<PreviewSpec, Int>,
                   night: Bool = false) -> NSView {
        let strip = PreviewStrip(points: NSSize(width: 66, height: 42),
                                 entries: [(value: 0.0, caption: "none"),
                                           (value: 0.5, caption: "half"),
                                           (value: 1.0, caption: "full")],
                                 spacing: 6)
        strip.onPick = { [weak s] v in
            guard let s else { return }
            s.value = v
            s.refresh()
            // Exactly the path a drag takes, so clicking a tile and dragging to
            // the same place cannot produce different results.
            s.slider.sendAction(s.slider.action, to: s.slider.target)
        }
        reliefStrips.append(ReliefStrip(slider: s, strip: strip, key: key, night: night))

        // The strip lines up under the control, not under the label.
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: UI.labelWidth + 10).isActive = true
        let stripRow = NSStackView(views: [indent, strip])
        stripRow.spacing = 0
        stripRow.alignment = .top

        let col = NSStackView(views: [formRow(title, s.box), stripRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }

    // ---- small builders

    func note(_ t: String) -> NSTextField { captionLabel(t) }

    func row(_ title: String, _ control: NSView) -> NSView { formRow(title, control) }

    func popup(_ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.target = self; p.action = action
        p.font = UI.body
        return p
    }

    func check(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.font = UI.body
        return b
    }

    func slider(_ title: String, _ range: ClosedRange<Double>,
                _ action: Selector, _ format: @escaping (Double) -> String) -> LabelledSlider {
        let ls = LabelledSlider(range: range, format: format)
        ls.slider.target = self; ls.slider.action = action
        ls.container = formRow(title, ls.box)
        return ls
    }
}

/// Slider plus its read-out. `value` keeps the two in step in both directions.
final class LabelledSlider {
    /// Supplied rather than made here, so a pane can hand in a `DetentSlider`
    /// and get the same row with haptics on it.
    let slider: NSSlider
    let label = NSTextField(labelWithString: "")
    let box = NSStackView()
    /// The full row, for showing and hiding.
    var container: NSView!
    private let format: (Double) -> String

    init(range: ClosedRange<Double>, format: @escaping (Double) -> String,
         slider: NSSlider = NSSlider()) {
        self.slider = slider
        self.format = format
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        label.font = UI.value
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
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

// MARK: - Elements
//
// The pane that owns the furniture on your screen — where it is, and what
// weather is allowed to do to it — lives in ElementsPane.swift. It replaces the
// old Weather pane, which had the same switches but no way to say where the
// things being switched actually were.

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
        detectedLabel = bodyLabel("—")
        locationButton = NSButton(title: "Use Location Services", target: self,
                                  action: #selector(requestLocation))
        locationButton.bezelStyle = .rounded
        locationButton.font = UI.body

        let yours = Card("Your location", symbol: "location.circle")
        yours.add(row("Detected", detectedLabel))
        yours.add(locationButton)
        addCard(yours)

        searchField = NSSearchField()
        searchField.placeholderString = "Search for a city"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 420).isActive = true

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
        col.width = 400
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true

        statusLabel = captionLabel("")
        removeButton = NSButton(title: "Remove City", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.font = UI.body
        countLabel = captionLabel("")

        let cities = Card("Cities", symbol: "building.2")
        cities.add(searchField)
        cities.add(scroll)
        cities.add(statusLabel)
        cities.add(removeButton)
        cities.add(countLabel)
        cities.note("The sun, moon and stars are computed from the selected city, so the wallpaper can "
                  + "show anywhere — not just where you are.")
        addCard(cities)
    }

    // MARK: - Sync

    override func sync(_ c: Config) {
        config = c
        saved = c.allPlaces

        detectedLabel.stringValue = c.place.map {
            "\($0.name)   \(String(format: "%.3f", $0.latitude)), \(String(format: "%.3f", $0.longitude))"
        } ?? "Not set"
        // The recovery path has to stay reachable.
        //
        // This was `isEnabled = (c.place == nil)`: the button switched itself
        // off the moment any place was stored and read "Location Detected"
        // forever after. That is the one state in which it is most needed — a
        // stored place is what you have when location worked ONCE and then
        // stopped, which for an ad-hoc signed build is after every rebuild. The
        // user was told location was working while the app had no grant at all
        // and no way to ask for one.
        //
        // So: enabled whenever a fresh fix could actually help. Only a live,
        // authorised, currently-followed location earns the passive label.
        let blocked = owner?.delegate?.locationBlocked ?? false
        let following = c.place != nil && c.isShowingDetectedPlace && !blocked
        locationButton.isEnabled = !following
        locationButton.title = following ? "Location Detected"
                             : (c.place == nil ? "Use Location Services"
                                               : "Update My Location")

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
            sub.font = UI.caption
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
        sub.font = UI.caption
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
        // Stand the placement overlay down first — see .elementalPermissionPrompt.
        NotificationCenter.default.post(name: .elementalPermissionPrompt, object: nil)
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
