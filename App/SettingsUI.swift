//  SettingsUI.swift — the settings window.
//
//  Laid out the way the current crop of Mac utilities does it (Droppy is the
//  model the user pointed at): a sidebar of colour-badged pages with a search
//  field, a rounded content panel with a back/forward pill, and every page built
//  from the same few pieces — a section title, a card of rows split by
//  hairlines, a strip of tiles for choices, switches for booleans, and rows
//  with a chevron that drill into a page of detail.
//
//  ---- What changed from the old window, and why
//
//  The old one had grown controls that did nothing, and that is the complaint
//  this answers. Every control here was checked against the renderer:
//
//    * the lock-screen and screen-saver style pickers set `shape` and `finish`,
//      which the shader never reads — picking "Dot" drew squares. Surface styles
//      now carry material, rounding and halftone, which it does read.
//    * the row field and stepper were clamped to 12…120 while the engine offered
//      up to 300, and a +1 step usually snapped straight back to the same grid.
//      The stepper now walks the list of row counts that fit the display.
//    * the five density thumbnails offered counts that do not fit and snapped to
//      something else when clicked. Gone; the grip and the stepper remain.
//    * HDR, which macOS refuses to the desktop level, so it only cost power. Its
//      config key stays for the day that changes; the switch is gone.
//    * the relief strips — three thumbnails under every slider — are replaced by
//      one live preview pinned above the controls, which shows the same thing
//      for every slider at once.
//
//  ---- Performance
//
//  Every picture goes through `ScenePreview` — cached, coalesced per slot and
//  rendered off the main thread — exactly as before. A slider writes the config
//  on every tick through `AppDelegate.applyConfig`, whose cheap half runs at
//  once and whose expensive half (save, lock still) is debounced 0.45s.

import SwiftUI
import AppKit
import ServiceManagement

// NO `@State` ANYWHERE IN THIS FILE. In the current SDK it is a compiler macro,
// and its plugin ships with Xcode but not with the Command Line Tools this
// project builds with — so it fails to compile with "plugin for module
// 'SwiftUIMacros' not found". View-local state lives in these small observable
// boxes instead, held with `@StateObject`, which is still a plain wrapper.
final class Flag: ObservableObject { @Published var on = false }
final class TextBox: ObservableObject { @Published var text = "" }

// MARK: - Pages

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, power, home, look, lock, saver, elements, location, automation, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .power: "Low Power"
        case .home: "Home Screen"
        case .look: "Look"
        case .lock: "Lock Screen"
        case .saver: "Screen Saver"
        case .elements: "Elements"
        case .location: "Location"
        case .automation: "Automation"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .power: "leaf.fill"
        case .home: "menubar.dock.rectangle"
        case .look: "cube.fill"
        case .lock: "lock.fill"
        case .saver: "sparkles.tv.fill"
        case .elements: "rectangle.3.group.fill"
        case .location: "location.fill"
        case .automation: "chevron.left.forwardslash.chevron.right"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(white: 0.52)
        case .power: .green
        case .home: .blue
        case .look: .purple
        case .lock: Color(white: 0.42)
        case .saver: .teal
        case .elements: .orange
        case .location: .red
        case .automation: .pink
        case .about: Color(red: 0.2, green: 0.72, blue: 0.4)
        }
    }

    /// What the sidebar search matches besides the title.
    var keywords: String {
        switch self {
        case .general: "login startup weather spaces motion speed shimmer replay wake setup onboarding"
        case .power: "battery low power energy frame rate fps covered occluded"
        case .home: "desktop wallpaper grid density rows cells heading facing sky place city"
        case .look: "material glass metal plastic matte shape round dots halftone relief depth emphasis light splay rise roughness grout shadow refraction dispersion frost"
        case .lock: "lock screen still password"
        case .saver: "screen saver idle"
        case .elements: "dock widgets menu bar furniture rain glass water"
        case .location: "city place search location services"
        case .automation: "api endpoint http url scheme curl shortcuts script automation"
        case .about: "version update icon github"
        }
    }

    /// Pages that are AppKit panes hosted whole.
    var isHostedPane: Bool { self == .elements || self == .location }

    static let groups: [[SettingsPage]] = [
        [.general, .power],
        [.home, .look, .lock, .saver],
        [.elements, .location],
        [.automation, .about],
    ]
}

enum LookDetail: String {
    case relief, surface, glass
    var title: String {
        switch self {
        case .relief: "Relief"
        case .surface: "Surface"
        case .glass: "Glass"
        }
    }
}

struct SettingsRoute: Hashable {
    var page: SettingsPage
    var detail: LookDetail? = nil
}

// MARK: - Store

/// The window's model. Holds a copy of the config, writes every change straight
/// back through `onCommit`, and keeps the navigation history the pill walks.
final class SettingsStore: ObservableObject {

    @Published private(set) var config: Config
    @Published private(set) var route = SettingsRoute(page: .general)
    @Published var search = ""
    @Published private(set) var loginEnabled = false

    private var back: [SettingsRoute] = []
    private var forward: [SettingsRoute] = []

    weak var app: AppDelegate?
    var onCommit: ((Config) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(config: Config) {
        self.config = config
        // The Low Power status line follows macOS, not just this window.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // ---- config

    /// A change from outside the window.
    func receive(_ c: Config) {
        if c != config { config = c }
    }

    func update(_ f: (inout Config) -> Void) {
        var c = config
        f(&c)
        guard c != config else { return }
        config = c
        onCommit?(c)
    }

    func binding<T>(_ kp: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: kp] },
                set: { v in self.update { $0[keyPath: kp] = v } })
    }

    /// A 0…1 slider, rounded to two decimals so the stored config does not
    /// accumulate the slider's float noise.
    func unit(_ kp: WritableKeyPath<Config, Double>) -> Binding<Double> {
        Binding(get: { self.config[keyPath: kp] },
                set: { v in self.update { $0[keyPath: kp] = (v * 100).rounded() / 100 } })
    }

    // ---- navigation

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func go(_ page: SettingsPage) { navigate(SettingsRoute(page: page)) }
    func open(_ detail: LookDetail) { navigate(SettingsRoute(page: .look, detail: detail)) }

    private func navigate(_ r: SettingsRoute) {
        guard r != route else { return }
        back.append(route)
        forward.removeAll()
        route = r
    }

    func goBack() {
        guard let r = back.popLast() else { return }
        forward.append(route)
        route = r
    }

    func goForward() {
        guard let r = forward.popLast() else { return }
        back.append(route)
        route = r
    }

    // ---- status and actions

    var lowPowerActive: Bool { app?.isLowPowerActive ?? false }

    func refreshStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        objectWillChange.send()
    }

    func toggleLowPower() {
        app?.toggleLowPower()
        receive(app?.currentConfig ?? config)
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change the login item"
            a.informativeText = "\(error.localizedDescription)\n\nYou can also set this in "
                              + "System Settings › General › Login Items."
            a.runModal()
        }
        refreshStatus()
    }

    func runSetupAgain() {
        // Cleared and saved BEFORE asking to present, so a flow that is quit
        // half way still counts as un-onboarded and can be resumed.
        update { $0.hasOnboarded = false }
        NSApp.sendAction(#selector(AppDelegate.startOnboarding), to: nil, from: nil)
    }

    func checkForUpdates() { app?.checkForUpdates() }

    func openSaverSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }

    // ---- grid

    static var displayW: Double { MosaicDensity.displayPixelWidth }
    static var displayH: Double { MosaicDensity.displayPixelHeight }

    static var ladder: [Int] {
        SceneSimulation.fittingRows(pixelWidth: Float(displayW), pixelHeight: Float(displayH))
    }

    static func geometry(_ rows: Int) -> (cols: Int, rows: Int, pitch: Float) {
        SceneSimulation.gridGeometry(pixelWidth: Float(displayW), pixelHeight: Float(displayH),
                                     gridRows: rows)
    }
}

// MARK: - Root

struct SettingsRoot: View {
    @ObservedObject var store: SettingsStore
    let pane: (SettingsPage) -> Pane?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(store: store)
                .frame(width: 236)
            SettingsDetail(store: store, pane: pane)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: Palette.panel)))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.vertical, 10)
                .padding(.trailing, 10)
        }
        .background(Color(nsColor: Palette.sidebar))
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @ObservedObject var store: SettingsStore

    private var filtered: [[SettingsPage]] {
        let q = store.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPage.groups }
        let hits = SettingsPage.allCases.filter {
            $0.title.lowercased().contains(q) || $0.keywords.contains(q)
        }
        return hits.isEmpty ? [] : [hits]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)      // the traffic lights sit here
            SearchField(text: $store.search)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { i, group in
                        if i > 0 { Color.clear.frame(height: 14) }
                        ForEach(group) { page in
                            SidebarRow(page: page, selected: store.route.page == page) {
                                store.go(page)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text("No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color(nsColor: Palette.raised).opacity(0.7)))
    }
}

struct SidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Badge(symbol: page.symbol, tint: page.tint, size: 26)
                Text(page.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: Palette.raised).opacity(selected ? 1 : (hover.on ? 0.45 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

// MARK: - Detail

struct SettingsDetail: View {
    @ObservedObject var store: SettingsStore
    let pane: (SettingsPage) -> Pane?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            if let hero = heroSpec {
                HeroHeader(spec: hero, caption: heroCaption)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
            }
            if store.route.page.isHostedPane, let p = pane(store.route.page) {
                PaneHost(pane: p, config: store.config)
                    .id(store.route.page)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        page
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .id(store.route)
            }
        }
    }

    @ViewBuilder private var page: some View {
        let s = store
        switch store.route.page {
        case .general: GeneralPage(store: s)
        case .power: PowerPage(store: s)
        case .home: HomePage(store: s)
        case .look:
            switch store.route.detail {
            case .relief?: ReliefPage(store: s)
            case .surface?: SurfaceFinishPage(store: s)
            case .glass?: GlassPage(store: s)
            case nil: LookPage(store: s)
            }
        case .lock: SurfacePage(store: s, role: .lock)
        case .saver: SurfacePage(store: s, role: .saver)
        case .automation: AutomationPage(store: s)
        case .about: AboutPage(store: s)
        case .elements, .location: EmptyView()
        }
    }

    /// Pages whose controls change the picture keep a live render pinned above
    /// them, so it is in view while a slider moves.
    private var heroSpec: PreviewSpec? {
        let c = store.config
        switch store.route.page {
        case .home, .look: return PreviewSpec.desktop(c, pixels: ScenePreview.large)
        case .lock:
            return c.lock.mirrorsDesktop ? PreviewSpec.desktop(c, pixels: ScenePreview.large)
                                         : PreviewSpec.surface(c, c.lock, pixels: ScenePreview.large)
        case .saver:
            return c.saver.mirrorsDesktop ? PreviewSpec.desktop(c, pixels: ScenePreview.large)
                                          : PreviewSpec.surface(c, c.saver, pixels: ScenePreview.large)
        default: return nil
        }
    }

    private var heroCaption: String {
        switch (store.route.page, store.route.detail) {
        case (.home, _): "The live wallpaper behind your icons, on every display and Space. Drawn with your settings over \(store.config.scenePlace.name)."
        case (.look, .relief?): "Every cell is a block pushed out of the wall by its own brightness."
        case (.look, .surface?): "The shape of each tile and the finish on its face."
        case (.look, .glass?): "Light passing through each block — subtle by nature, look at the preview."
        case (.look, _): "What the wall is made of. Shared by the desktop, the lock screen and the saver."
        case (.lock, _): "A still behind the password field, refreshed every minute and the moment you lock."
        case (.saver, _): "Fully animated — the only animated surface macOS allows at the lock screen."
        default: ""
        }
    }
}

struct TopBar: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                pillButton("chevron.left", enabled: store.canGoBack) { store.goBack() }
                Rectangle().fill(Color(nsColor: Palette.hairline)).frame(width: 1, height: 18)
                pillButton("chevron.right", enabled: store.canGoForward) { store.goForward() }
            }
            .background(Capsule().fill(Color(nsColor: Palette.pill)))

            Text(store.route.detail?.title ?? store.route.page.title)
                .font(.system(size: 20, weight: .bold))
            Spacer()
            LowPowerChip(store: store)
        }
    }

    private func pillButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}

/// The top-right chip: Low Power at a glance, and a one-click toggle.
struct LowPowerChip: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        let on = store.lowPowerActive
        Button { store.toggleLowPower() } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "leaf.fill" : "leaf")
                    .foregroundStyle(on ? Color.green : Color.secondary)
                Text("Low Power")
                    .font(.system(size: 14, weight: .semibold))
                if store.config.lowPower == .automatic {
                    Text("Auto").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().fill(on ? Color.green.opacity(0.18) : Color(nsColor: Palette.pill)))
            .overlay(Capsule().strokeBorder(on ? Color.green.opacity(0.45)
                                               : Color(nsColor: Palette.hairline), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Low Power is on — click to turn it off" : "Click to turn Low Power on")
    }
}

// MARK: - Building blocks

struct Badge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
    }
}

struct SectionTitle: View {
    let text: String
    var info: String? = nil
    init(_ text: String, info: String? = nil) { self.text = text; self.info = info }
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            if let info { InfoButton(text: info) }
        }
        .padding(.leading, 4)
        .padding(.top, 12)
    }
}

struct InfoButton: View {
    let text: String
    @StateObject private var shown = Flag()
    var body: some View {
        Button { shown.on.toggle() } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown.on, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 13))
                .padding(16)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RowsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: Palette.card)))
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: Palette.hairline)).frame(height: 1).padding(.leading, 18)
    }
}

struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .medium))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    func rowPadding() -> some View { padding(.horizontal, 18).padding(.vertical, 13) }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .rowPadding()
    }
}

struct SliderRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                RowLabel(title: title, subtitle: subtitle)
                Spacer(minLength: 12)
                Text(format(value))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
        .rowPadding()
    }
}

struct MenuRow<T: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 0)
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .rowPadding()
    }
}

struct ButtonRow: View {
    let title: String
    var subtitle: String? = nil
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 0)
            Button(button, action: action).controlSize(.large)
        }
        .rowPadding()
    }
}

struct NavRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    @StateObject private var hover = Flag()
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Badge(symbol: symbol, tint: tint, size: 34)
                RowLabel(title: title, subtitle: subtitle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .rowPadding()
            .background(Color(nsColor: Palette.raised).opacity(hover.on ? 0.35 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// A strip of tiles in a card — Droppy's "Startup & visibility". Each tile is a
/// toggle (`multi`) or one of a set of choices; a selected tile is raised.
struct TileOption: Identifiable {
    let id: String
    let title: String
    var symbol: String? = nil
}

struct TileCard: View {
    var title: String? = nil
    var info: String? = nil
    let options: [TileOption]
    let isOn: (String) -> Bool
    let tap: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let info { InfoButton(text: info) }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                    if i > 0 {
                        Rectangle().fill(Color(nsColor: Palette.hairline)).frame(width: 1)
                    }
                    Button { tap(o.id) } label: {
                        HStack(spacing: 8) {
                            if let s = o.symbol { Image(systemName: s).font(.system(size: 15)) }
                            Text(o.title).font(.system(size: 14, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: Palette.raised).opacity(isOn(o.id) ? 1 : 0))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isOn(o.id) ? .primary : .secondary)
                }
            }
            .frame(height: 50)
        }
        .background(Color(nsColor: Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }
}

// MARK: - Pictures

/// Loads a scene preview through `ScenePreview` — one slot per view, so a drag
/// renders only the latest spec.
final class PreviewLoader: ObservableObject {
    @Published var image: NSImage?
    private var spec: PreviewSpec?

    func load(_ s: PreviewSpec) {
        guard s != spec else { return }
        spec = s
        ScenePreview.shared.request(s, slot: ObjectIdentifier(self)) { [weak self] img in
            // Intermediate frames of a drag are shown too — that is what makes
            // the picture track the control — but never an older one after a
            // newer one has landed.
            guard let self else { return }
            self.image = img
        }
    }
}

struct ScenePicture: View {
    let spec: PreviewSpec
    var corner: CGFloat = 12
    @StateObject private var loader = PreviewLoader()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(nsColor: Palette.raised))
            if let img = loader.image {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onChange(of: spec, initial: true) { _, s in loader.load(s) }
    }
}

struct HeroHeader: View {
    let spec: PreviewSpec
    let caption: String
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ScenePicture(spec: spec, corner: 14)
                .frame(width: 288, height: 180)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            // A FIXED width. With only a maximum, SwiftUI measures the minimum
            // size at a width of nothing — one character a line — and that
            // height became the whole window's minimum, which then grew to
            // twice the screen.
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

struct ThumbChoice: View {
    let spec: PreviewSpec
    let caption: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ScenePicture(spec: spec, corner: 10)
                    .frame(width: 120, height: 75)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                        .padding(-4))
                Text(caption)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The density grip, hosted. It draws its own picture; the config is written
/// on mouse-up and at the end of a scroll, as it always was.
struct GripView: NSViewRepresentable {
    let spec: PreviewSpec
    let rows: Int
    let commit: (Int) -> Void

    final class Coordinator { var commit: (Int) -> Void = { _ in } }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DensityGripView {
        let g = DensityGripView()
        g.onCommit = { [weak coord = context.coordinator] q in coord?.commit(q) }
        g.show(spec)
        g.setRequested(rows)
        return g
    }

    func updateNSView(_ g: DensityGripView, context: Context) {
        context.coordinator.commit = commit
        guard !g.isDragging else { return }
        g.show(spec)
        if g.actualRows != SettingsStore.geometry(rows).rows { g.setRequested(rows) }
    }
}

/// − [n rows ▾] +, walking only the counts that fit this display.
struct DensityStepper: View {
    @Binding var rows: Int
    var body: some View {
        let ladder = SettingsStore.ladder
        let actual = SettingsStore.geometry(rows).rows
        let i = ladder.firstIndex(of: actual) ?? 0
        HStack(spacing: 6) {
            Button { if i > 0 { rows = ladder[i - 1] } } label: {
                Image(systemName: "minus").frame(width: 16, height: 16)
            }
            .disabled(i <= 0)
            Picker("", selection: Binding(get: { actual }, set: { rows = $0 })) {
                ForEach(ladder, id: \.self) { Text("\($0) rows").tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button { if i < ladder.count - 1 { rows = ladder[i + 1] } } label: {
                Image(systemName: "plus").frame(width: 16, height: 16)
            }
            .disabled(i >= ladder.count - 1)
        }
    }
}

struct GridSummary: View {
    let rows: Int
    var body: some View {
        let g = SettingsStore.geometry(rows)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(g.rows) rows × \(g.cols) columns")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text(String(format: "%.1f px cells on this display", g.pitch))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared choices

enum LookPresets {
    static let materials: [(MosaicMaterial, String)] = [
        (.glass, "Glass"), (.metal, "Metal"), (.plastic, "Plastic"), (.matte, "Matte"),
    ]
    /// Shape presets over the two axes that make one: corner rounding, and
    /// whether size carries the tone.
    static let shapes: [(id: String, title: String, rounding: Double, halftone: Double)] = [
        ("square", "Square", 0, 0),
        ("rounded", "Rounded", 0.45, 0),
        ("dots", "Dots", 1, 1),
    ]
    static func shapeID(rounding: Double, halftone: Double) -> String? {
        shapes.first { abs($0.rounding - rounding) < 0.02 && abs($0.halftone - halftone) < 0.02 }?.id
    }
    static let speeds: [(Double, String)] = [
        (0.15, "Glacial — 0.15×"), (0.3, "Very slow — 0.3×"), (0.6, "Slow — 0.6×"),
        (1.0, "Real time"), (1.5, "Brisk — 1.5×"),
    ]
    static let replays: [(Double, String)] = [
        (0, "Off"), (2, "Flick — 2s"), (5, "Normal — 5s"), (10, "Slow — 10s"), (20, "Cinematic — 20s"),
    ]
    static let fps = [10, 15, 30, 60, 120]

    static func bearing(_ deg: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return "\(Int(deg))° \(names[Int((deg / 45).rounded()) % 8])"
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let c = store.config
        TileCard(title: "Startup & visibility",
                 info: "Launch at login starts Elemental with your Mac — it has no Dock icon; "
                     + "open it again from Spotlight to reach these settings. Live weather follows "
                     + "the real sky; off draws a clear calm day. All Spaces draws the wallpaper "
                     + "on every desktop Space rather than only the one it started on.",
                 options: [TileOption(id: "login", title: "Launch at login", symbol: "power"),
                           TileOption(id: "weather", title: "Live weather", symbol: "cloud.sun"),
                           TileOption(id: "spaces", title: "All Spaces", symbol: "square.on.square")],
                 isOn: {
                    switch $0 {
                    case "login": store.loginEnabled
                    case "weather": c.liveWeather
                    default: c.showOnAllSpaces
                    }
                 },
                 tap: {
                    switch $0 {
                    case "login": store.setLogin(!store.loginEnabled)
                    case "weather": store.update { $0.liveWeather.toggle() }
                    default: store.update { $0.showOnAllSpaces.toggle() }
                    }
                 })

        SectionTitle("Appearance and access")
        RowsCard {
            NavRow(symbol: SettingsPage.look.symbol, tint: SettingsPage.look.tint,
                   title: "Look", subtitle: "Material, shape, relief and glass.") { store.go(.look) }
            RowDivider()
            NavRow(symbol: SettingsPage.power.symbol, tint: SettingsPage.power.tint,
                   title: "Low Power", subtitle: "Follows macOS, or on and off by hand.") { store.go(.power) }
            RowDivider()
            NavRow(symbol: SettingsPage.automation.symbol, tint: SettingsPage.automation.tint,
                   title: "Automation", subtitle: "Drive Elemental from scripts, Shortcuts and URLs.") {
                store.go(.automation)
            }
        }

        SectionTitle("Motion", info: "Speed is how fast the world runs — slowing it costs nothing "
                     + "and reads calmer. Wake replay plays back the hours missed during sleep as "
                     + "a time-lapse; gaps under ten minutes always resume instantly.")
        RowsCard {
            SliderRow(title: "Shimmer", subtitle: "A slow drift of light across the wall.",
                      value: store.unit(\.shimmer))
            RowDivider()
            MenuRow(title: "Speed", selection: Binding(
                        get: { LookPresets.speeds.min { abs($0.0 - c.motionSpeed) < abs($1.0 - c.motionSpeed) }!.0 },
                        set: { v in store.update { $0.motionSpeed = v } }),
                    options: LookPresets.speeds)
            RowDivider()
            MenuRow(title: "Wake replay", selection: Binding(
                        get: { c.playbackOnWake
                                ? (LookPresets.replays.min { abs($0.0 - c.playbackMaxSeconds) < abs($1.0 - c.playbackMaxSeconds) }!.0)
                                : 0 },
                        set: { v in store.update { $0.playbackOnWake = v > 0; if v > 0 { $0.playbackMaxSeconds = v } } }),
                    options: LookPresets.replays)
        }

        SectionTitle("Setup")
        RowsCard {
            ButtonRow(title: "First-run setup",
                      subtitle: "Walks the permissions again — the shortest fix when the sky is drawn for the wrong city.",
                      button: "Run Again…") { store.runSetupAgain() }
        }
    }
}

// MARK: - Low Power

struct PowerPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let c = store.config
        TileCard(title: "Low Power",
                 info: "Low Power draws exactly the same picture at a steady fifteen frames a second "
                     + "instead of up to thirty. Automatic turns it on whenever macOS Low Power Mode "
                     + "is on. The menu-bar icon has the same toggle; hold Option there to hand it "
                     + "back to Automatic.",
                 options: [TileOption(id: "auto", title: "Automatic", symbol: "wand.and.stars"),
                           TileOption(id: "on", title: "On", symbol: "leaf.fill"),
                           TileOption(id: "off", title: "Off", symbol: "bolt.fill")],
                 isOn: {
                    switch $0 {
                    case "auto": c.lowPower == .automatic
                    case "on": c.lowPower == .on
                    default: c.lowPower == .off
                    }
                 },
                 tap: { id in
                    store.update {
                        $0.lowPower = id == "auto" ? .automatic : (id == "on" ? .on : .off)
                    }
                 })

        RowsCard {
            HStack(spacing: 12) {
                Circle().fill(store.lowPowerActive ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                RowLabel(title: store.lowPowerActive ? "Low Power is on" : "Low Power is off",
                         subtitle: statusDetail)
                Spacer()
            }
            .rowPadding()
        }

        SectionTitle("Drawing")
        RowsCard {
            MenuRow(title: "Frame rate ceiling",
                    subtitle: "A calm sky asks for far less; rain, lightning and shimmer climb toward this.",
                    selection: store.binding(\.maxFPS),
                    options: LookPresets.fps.map { ($0, "\($0) fps") })
            RowDivider()
            ToggleRow(title: "Keep drawing when covered",
                      subtitle: "Off pauses behind fullscreen apps. Nothing is unloaded either way, so coming back is instant.",
                      isOn: store.binding(\.renderWhenOccluded))
        }
    }

    private var statusDetail: String {
        let sys = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch store.config.lowPower {
        case .automatic: return sys ? "Following macOS, which is in Low Power Mode."
                                    : "Following macOS, which is not in Low Power Mode."
        case .on: return "Set by hand — stays on until you turn it off."
        case .off: return "Set by hand — stays off even in macOS Low Power Mode."
        }
    }
}

// MARK: - Home Screen

struct HomePage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let c = store.config
        SectionTitle("Grid", info: "Only row counts that fit this display are offered: every cell is "
                     + "whole and the same size, and the grid meets all four edges exactly. Drag the "
                     + "corner of the picture, scroll over it, or step with − and +.")
        RowsCard {
            HStack(alignment: .center, spacing: 22) {
                GripView(spec: PreviewSpec.desktop(c, pixels: ScenePreview.large),
                         rows: c.gridRows) { q in store.update { $0.gridRows = q } }
                    .frame(width: DensityGripView.tilePoints.width + 24,
                           height: DensityGripView.tilePoints.height + 24)
                VStack(alignment: .leading, spacing: 14) {
                    GridSummary(rows: c.gridRows)
                    DensityStepper(rows: store.binding(\.gridRows))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }

        SkyEditor(store: store,
                  heading: store.binding(\.headingMode),
                  facing: store.binding(\.facingAz),
                  place: store.binding(\.scenePlaceName))
    }
}

struct SkyEditor: View {
    @ObservedObject var store: SettingsStore
    @Binding var heading: HeadingMode
    @Binding var facing: Double
    @Binding var place: String?

    var body: some View {
        let places = store.config.allPlaces
        SectionTitle("Sky", info: "Custom faces one bearing and lets the sky drift past, as a window "
                     + "does. Dynamic follows whatever is up — the sun by day, the moon once it has "
                     + "risen — panning between them at dusk.")
        TileCard(options: [TileOption(id: "custom", title: "Custom heading", symbol: "location.north.line"),
                           TileOption(id: "dynamic", title: "Follow the sun & moon", symbol: "sun.and.horizon")],
                 isOn: { ($0 == "dynamic") == (heading == .dynamic) },
                 tap: { heading = $0 == "dynamic" ? .dynamic : .custom })
        RowsCard {
            if heading == .custom {
                SliderRow(title: "Facing", value: Binding(get: { facing }, set: { facing = $0.rounded() }),
                          range: 0...359, format: LookPresets.bearing)
                RowDivider()
            }
            if places.isEmpty {
                HStack {
                    RowLabel(title: "Sky over", subtitle: "Add cities in Location.")
                    Spacer()
                    Text(store.config.effectivePlace.name).foregroundStyle(.secondary)
                }
                .rowPadding()
            } else {
                MenuRow(title: "Sky over", selection: Binding(
                            get: { place.flatMap { n in places.contains { $0.name == n } ? n : nil }
                                    ?? store.config.scenePlace.name },
                            set: { place = $0 }),
                        options: places.map { ($0.name, $0.name) })
            }
        }
    }
}

// MARK: - Look

struct LookPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let c = store.config
        let base = PreviewSpec.desktop(c, pixels: ScenePreview.medium)
        SectionTitle("Material")
        RowsCard {
            HStack(spacing: 4) {
                ForEach(LookPresets.materials, id: \.0) { item in
                    let m = item.0
                    ThumbChoice(spec: Self.with(base) { $0.material = m }, caption: item.1,
                                selected: c.material == m) {
                        store.update {
                            $0.material = m
                            $0.finish = (m == .matte) ? .flat : .glass
                        }
                    }
                }
            }
            .padding(10)
        }

        SectionTitle("Shape")
        RowsCard {
            HStack(spacing: 4) {
                let current = LookPresets.shapeID(rounding: c.rounding, halftone: c.halftone)
                ForEach(LookPresets.shapes, id: \.id) { sh in
                    ThumbChoice(spec: Self.with(base) { $0.rounding = sh.rounding; $0.halftone = sh.halftone },
                                caption: sh.title, selected: current == sh.id) {
                        store.update {
                            $0.rounding = sh.rounding
                            $0.halftone = sh.halftone
                            $0.shape = sh.halftone > 0.5 ? .dot : .square
                        }
                    }
                }
            }
            .padding(10)
        }

        SectionTitle("Fine-tune")
        RowsCard {
            NavRow(symbol: "cube.fill", tint: .indigo, title: "Relief",
                   subtitle: "Depth \(pct(c.reliefDepth)) · emphasis \(pct(c.emphasis)) · light \(pct(c.lightIntensity))") {
                store.open(.relief)
            }
            RowDivider()
            NavRow(symbol: "square.grid.3x3.fill", tint: .orange, title: "Surface",
                   subtitle: "Rounding, halftone, roughness, grout and shadow.") {
                store.open(.surface)
            }
            if c.material == .glass {
                RowDivider()
                NavRow(symbol: "drop.fill", tint: .cyan, title: "Glass",
                       subtitle: "Refraction \(pct(c.refraction)) · dispersion \(pct(c.dispersion)) · frost \(pct(c.frost))") {
                    store.open(.glass)
                }
            }
        }
    }

    private func pct(_ d: Double) -> String { "\(Int((d * 100).rounded()))%" }

    static func with(_ s: PreviewSpec, _ f: (inout PreviewSpec) -> Void) -> PreviewSpec {
        var s = s; f(&s); return s
    }
}

struct ReliefPage: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        RowsCard {
            SliderRow(title: "Depth", subtitle: "How far the blocks stand out.",
                      value: store.unit(\.reliefDepth))
            RowDivider()
            SliderRow(title: "Emphasis", subtitle: "Whether blocks follow features — clouds, the moon — or plain tone.",
                      value: store.unit(\.emphasis))
            RowDivider()
            SliderRow(title: "Light", subtitle: "Shading on the side faces and in the crevices.",
                      value: store.unit(\.lightIntensity))
            RowDivider()
            SliderRow(title: "Splay", subtitle: "Unsettles the courses so the wall is not perfectly regular.",
                      value: store.unit(\.splay))
            RowDivider()
            SliderRow(title: "Rise", subtitle: "How long a block takes to grow or sink as the sky changes.",
                      value: store.unit(\.reliefRise),
                      format: { $0 < 0.005 ? "instant" : String(format: "%.1fs", 0.08 + $0 * $0 * 2.4) })
        }
    }
}

struct SurfaceFinishPage: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        RowsCard {
            SliderRow(title: "Corner rounding", subtitle: "From a square tile to a round bead; the block behind follows.",
                      value: store.unit(\.rounding),
                      format: { $0 < 0.02 ? "square" : ($0 > 0.98 ? "round" : "\(Int(($0 * 100).rounded()))%") })
            RowDivider()
            SliderRow(title: "Halftone", subtitle: "At full, a dark cell's tile shrinks away and a bright one grows to meet its neighbours.",
                      value: store.unit(\.halftone))
            RowDivider()
            SliderRow(title: "Roughness", subtitle: "Scatters the reflection, polished to ground.",
                      value: store.unit(\.roughness),
                      format: { $0 < 0.02 ? "polished" : ($0 > 0.98 ? "ground" : "\(Int(($0 * 100).rounded()))%") })
            RowDivider()
            SliderRow(title: "Depth colour", subtitle: "Near blocks keep their colour; flush ones fade toward the haze.",
                      value: store.unit(\.depthMap))
            RowDivider()
            SliderRow(title: "Grout", subtitle: "The painted line between tiles.",
                      value: store.unit(\.grout),
                      format: { $0 < 0.02 ? "none" : "\(Int(($0 * 100).rounded()))%" })
            RowDivider()
            SliderRow(title: "Shadow", subtitle: "The contact shadow where blocks meet.",
                      value: store.unit(\.shadow),
                      format: { $0 < 0.02 ? "none" : "\(Int(($0 * 100).rounded()))%" })
        }
    }
}

struct GlassPage: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        RowsCard {
            SliderRow(title: "Refraction", subtitle: "How far you see through each block — further toward the edges.",
                      value: store.unit(\.refraction))
            RowDivider()
            SliderRow(title: "Dispersion", subtitle: "Splits that per colour and fringes the edges.",
                      value: store.unit(\.dispersion))
            RowDivider()
            SliderRow(title: "Frost", subtitle: "Scatters the light through the block.",
                      value: store.unit(\.frost))
        }
        Footnote("Glass shows most at night against the moon.")
    }
}

// MARK: - Lock screen and screen saver

struct SurfacePage: View {
    enum Role { case lock, saver }
    @ObservedObject var store: SettingsStore
    let role: Role

    private var kp: WritableKeyPath<Config, Config.SurfaceStyle> { role == .lock ? \.lock : \.saver }

    var body: some View {
        let st = store.config[keyPath: kp]
        if role == .lock {
            RowsCard {
                ToggleRow(title: "Show the scene on the lock screen",
                          subtitle: "Replaces your desktop picture with a still of the scene. macOS does not allow animation behind the password field.",
                          isOn: store.binding(\.syncLockScreen))
            }
        } else {
            RowsCard {
                ButtonRow(title: "Choose Elemental as your screen saver",
                          subtitle: "In System Settings › Screen Saver. It follows these settings and the desktop's weather.",
                          button: "Open…") { store.openSaverSettings() }
            }
        }

        RowsCard {
            ToggleRow(title: "Match Home Screen",
                      subtitle: "Use exactly the desktop's look, grid and sky.",
                      isOn: binding(\.mirrorsDesktop))
        }

        if !st.mirrorsDesktop {
            SectionTitle("Material")
            TileCard(options: LookPresets.materials.map { TileOption(id: "\($0.0.rawValue)", title: $0.1) },
                     isOn: { $0 == "\(st.material.rawValue)" },
                     tap: { id in
                        let m = MosaicMaterial(rawValue: Int32(id) ?? 0) ?? .glass
                        update { $0.material = m; $0.finish = (m == .matte) ? .flat : .glass }
                     })
            SectionTitle("Shape")
            TileCard(options: LookPresets.shapes.map { TileOption(id: $0.id, title: $0.title) },
                     isOn: { $0 == LookPresets.shapeID(rounding: st.rounding, halftone: st.halftone) },
                     tap: { id in
                        guard let sh = LookPresets.shapes.first(where: { $0.id == id }) else { return }
                        update {
                            $0.rounding = sh.rounding; $0.halftone = sh.halftone
                            $0.shape = sh.halftone > 0.5 ? .dot : .square
                        }
                     })
            SectionTitle("Grid")
            RowsCard {
                HStack(spacing: 16) {
                    GridSummary(rows: st.gridRows)
                    Spacer()
                    DensityStepper(rows: binding(\.gridRows))
                }
                .rowPadding()
            }
            SkyEditor(store: store,
                      heading: binding(\.headingMode),
                      facing: binding(\.facingAz),
                      place: binding(\.scenePlaceName))
        }
    }

    private func binding<T>(_ f: WritableKeyPath<Config.SurfaceStyle, T>) -> Binding<T> {
        let kp = self.kp
        return Binding(get: { store.config[keyPath: kp][keyPath: f] },
                       set: { v in store.update { $0[keyPath: kp][keyPath: f] = v } })
    }

    private func update(_ f: (inout Config.SurfaceStyle) -> Void) {
        let kp = self.kp
        store.update { f(&$0[keyPath: kp]) }
    }
}

// MARK: - Automation

struct AutomationPage: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var port = TextBox()

    private var scheme: String { Config.isPreRelease ? "elemental-pre" : "elemental" }
    private var base: String { "http://127.0.0.1:\(store.config.automationPort)" }

    var body: some View {
        let c = store.config
        let server = store.app?.automation

        PageHeader(page: .automation,
                   subtitle: "Change anything in these settings from a script, Shortcuts, Raycast or a URL.")

        TileCard(title: "Local endpoint",
                 info: "A small HTTP API on this Mac only (127.0.0.1). Requests from web pages are "
                     + "refused, so a website cannot reach it — only programs you run can.",
                 options: [TileOption(id: "on", title: "On", symbol: "antenna.radiowaves.left.and.right"),
                           TileOption(id: "off", title: "Off", symbol: "xmark")],
                 isOn: { ($0 == "on") == c.automationEnabled },
                 tap: { id in store.update { $0.automationEnabled = id == "on" } })

        RowsCard {
            HStack(spacing: 12) {
                Circle().fill(statusColour(server)).frame(width: 9, height: 9)
                RowLabel(title: statusTitle(server), subtitle: server?.lastError)
                Spacer()
                if c.automationEnabled {
                    Button("Copy") { copy(base) }
                }
            }
            .rowPadding()
            RowDivider()
            HStack(spacing: 16) {
                RowLabel(title: "Port", subtitle: "127.0.0.1 only. Changes apply when you press Return.")
                Spacer()
                TextField("7417", text: $port.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        if let p = Int(port.text), (1024...65535).contains(p) {
                            store.update { $0.automationPort = p }
                        } else {
                            port.text = "\(store.config.automationPort)"
                        }
                    }
            }
            .rowPadding()
        }
        .onAppear { port.text = "\(c.automationPort)" }

        SectionTitle("Try it")
        CodeBlock(lines: [
            "curl -s \(base)/v1/status",
            "curl -s -X PATCH \(base)/v1/config -H 'Content-Type: application/json' -d '{\"gridRows\": 72, \"material\": \"metal\"}'",
            "curl -s -X POST \(base)/v1/lowpower -H 'Content-Type: application/json' -d '{\"mode\": \"on\"}'",
            "curl -s \(base)/v1/schema",
        ])
        Footnote("GET /v1/config returns everything; PATCH merges any part of it. GET /v1/grid lists the row counts that fit each display.")

        SectionTitle("URL scheme", info: "Works whether or not the endpoint is on — handy from Shortcuts' "
                     + "Open URLs action, or a link in a note.")
        CodeBlock(lines: [
            "open '\(scheme)://set?reliefDepth=0.7&material=glass'",
            "open \(scheme)://lowpower/toggle",
            "open \(scheme)://reload",
        ])

        SectionTitle("Keys")
        RowsCard {
            ForEach(Array(AutomationSchema.keys.enumerated()), id: \.offset) { i, k in
                if i > 0 { RowDivider() }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(k.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(k.type).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(k.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
        }
    }

    private func statusColour(_ s: AutomationServer?) -> Color {
        guard store.config.automationEnabled else { return .secondary.opacity(0.5) }
        if s?.lastError != nil { return .red }
        return s?.isRunning == true ? .green : .orange
    }

    private func statusTitle(_ s: AutomationServer?) -> String {
        guard store.config.automationEnabled else { return "Off" }
        if s?.lastError != nil { return "Not listening" }
        return s?.isRunning == true ? "Listening on \(base)" : "Starting…"
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct CodeBlock: View {
    let lines: [String]
    var body: some View {
        RowsCard {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                if i > 0 { RowDivider() }
                HStack(alignment: .top, spacing: 10) {
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
            }
        }
    }
}

/// The big centred badge-and-title header, Droppy's Store page.
struct PageHeader: View {
    let page: SettingsPage
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Badge(symbol: page.symbol, tint: page.tint, size: 76)
                .shadow(color: page.tint.opacity(0.35), radius: 12, y: 4)
            Text(page.title).font(.system(size: 28, weight: .bold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Elemental").font(.system(size: 28, weight: .bold))
            Text("Version \(v) (\(b))\(Config.isPreRelease ? " — pre-release" : "")")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)

        RowsCard {
            ToggleRow(title: "Update automatically",
                      subtitle: "Checks GitHub for new releases and installs them.",
                      isOn: store.binding(\.automaticUpdates))
            RowDivider()
            ButtonRow(title: "Check now", button: "Check for Updates…") { store.checkForUpdates() }
        }

        SectionTitle("App icon", info: "Which mark Elemental wears in Finder, Spotlight and its "
                     + "own alerts. Applied as a custom icon, so nothing code-signed is touched.")
        RowsCard {
            IconPickerView(selected: store.config.appIcon) { s in store.update { $0.appIcon = s } }
                .padding(14)
        }

        RowsCard {
            Button {
                if let u = URL(string: "https://github.com/P-maan/elemental/releases") {
                    NSWorkspace.shared.open(u)
                }
            } label: {
                HStack {
                    RowLabel(title: "Release notes", subtitle: "github.com/P-maan/elemental")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
                .rowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct IconPickerView: NSViewRepresentable {
    let selected: AppIconStyle
    let pick: (AppIconStyle) -> Void

    final class Coordinator { var pick: (AppIconStyle) -> Void = { _ in } }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AppIconPicker {
        let p = AppIconPicker()
        p.onPick = { [weak coord = context.coordinator] s in coord?.pick(s) }
        return p
    }

    func updateNSView(_ p: AppIconPicker, context: Context) {
        context.coordinator.pick = pick
        p.select(selected)
    }
}

// MARK: - Hosted AppKit panes

struct PaneHost: NSViewControllerRepresentable {
    let pane: Pane
    let config: Config

    func makeNSViewController(context: Context) -> Pane {
        pane.syncSafely(config)
        return pane
    }

    // Deliberately empty. A pane re-synced on every store change would have its
    // own controls reassigned under the mouse while it is being dragged — the
    // controller syncs panes itself, excluding the one that made the change.
    func updateNSViewController(_ vc: Pane, context: Context) {}
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {

    weak var delegate: AppDelegate?
    private(set) var config = Config()
    let store: SettingsStore
    private var window: NSWindow!

    private let elementsPane = ElementsPane()
    private let locationPane = LocationPane()
    private var appKitPanes: [Pane] { [elementsPane, locationPane] }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        self.config = delegate.currentConfig
        self.store = SettingsStore(config: delegate.currentConfig)
        super.init()
        store.app = delegate
        store.onCommit = { [weak self] c in self?.storeCommitted(c) }
        appKitPanes.forEach { $0.owner = self }
        delegate.automation.onStateChange = { [weak self] in self?.store.objectWillChange.send() }
        build()
    }

    private func build() {
        let root = SettingsRoot(store: store) { [weak self] page in
            switch page {
            case .elements: self?.elementsPane
            case .location: self?.locationPane
            default: nil
            }
        }
        let host = NSHostingView(rootView: root)
        // Minimum size only. The default also publishes the content's IDEAL
        // size, and a long page then resizes the whole window to fit itself —
        // the window grew to twice the screen height on the Home page.
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.title = "Elemental"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = Palette.sidebar
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 860, height: 580)
        w.setContentSize(NSSize(width: 940, height: 740))
        w.center()
        window = w
    }

    func hide() { window?.orderOut(nil) }

    func show(config: Config) {
        self.config = config
        store.receive(config)
        store.refreshStatus()
        appKitPanes.forEach { $0.syncSafely(config) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Update without stealing focus — something outside Settings changed the
    /// config: Location Services resolving, the menu-bar toggle, the endpoint.
    func refreshIfVisible(config: Config) {
        self.config = config
        store.receive(config)
        guard window?.isVisible == true else { return }
        appKitPanes.forEach { $0.syncSafely(config) }
    }

    /// For the offscreen verification harness: the window and its AppKit panes.
    var inspectable: (window: NSWindow, panes: [Pane]) { (window, appKitPanes) }

    /// A SwiftUI page changed something.
    private func storeCommitted(_ c: Config) {
        config = c
        delegate?.applyConfig(c)
    }

    /// An AppKit pane changed something. Push it out, then re-sync the OTHER
    /// pane and the SwiftUI pages — never the sender, whose controls are
    /// already consistent and may be under the mouse.
    func commit(_ newConfig: Config, from sender: Pane? = nil) {
        config = newConfig
        delegate?.applyConfig(newConfig)
        store.receive(newConfig)
        for pane in appKitPanes where pane !== sender { pane.syncSafely(newConfig) }
    }
}
