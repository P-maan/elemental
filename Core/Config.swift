//  Config.swift — user settings, persisted as JSON.
//
//  Lives at ~/Library/Application Support/Elemental/config.json so it can be
//  edited by hand as well as through Settings. The screensaver reads the same
//  file when it can; if the sandbox denies it, the defaults here are already a
//  complete, correct scene, so it renders anyway.

import Foundation

struct Place: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String?

    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// Which of the supplied icon designs the app wears.
///
/// The artwork lives in the three Icon Composer bundles at the project root and
/// is baked into `Icons/*.icns` by `Elemental --make-icons` — see AppIcons.swift. This
/// enum is only the CHOICE, which is why it lives in Core with the rest of the
/// settings and carries no AppKit in it: the screen saver and the offscreen
/// renderer decode the same config file and must not need a window server to
/// read a number they do not use.
enum AppIconStyle: Int, Codable, CaseIterable {
    /// "Elemental 001" — the glass mosaic itself, in a glass frame.
    case mosaic = 1
    /// "ELemental 002" — the El logotype alone. The default: it is the mark,
    /// it reads at 16 points, and it is the same shape as the menu bar item.
    case mark = 2
    /// "ELemental 003" — the full lockup, mark over wordmark.
    case lockup = 3

    var title: String {
        switch self {
        case .mosaic: return "Mosaic"
        case .mark:   return "Mark"
        case .lockup: return "Lockup"
        }
    }

    /// Base name of the .icns in the app's Resources.
    var resourceName: String {
        switch self {
        case .mosaic: return "Elemental001"
        case .mark:   return "Elemental002"
        case .lockup: return "Elemental003"
        }
    }
}

struct Config: Codable, Equatable {

    /// Where the sky is drawn for. Nil until the user has granted location or
    /// entered somewhere manually.
    var place: Place?

    /// Places added by search, alongside the located one.
    var otherPlaces: [Place] = []

    /// Which place the background is drawn for, by name. Nil means whichever
    /// place Location Services resolved. Lets the wallpaper show a city you are
    /// not standing in — the sky over home while you are away, say.
    var scenePlaceName: String?

    /// Whether the permission dialog has ever been shown. Prevents re-asking on
    /// every launch, which is what happens otherwise: an ad-hoc signed build
    /// gets a new code identity on each rebuild, so TCC forgets the grant and
    /// the status returns to notDetermined.
    var hasAskedForLocation: Bool = false

    /// WHICH build we last asked under.
    ///
    /// `hasAskedForLocation` alone was a one-way door. It is set true the first
    /// time the dialog is raised and never cleared, so once a grant is lost the
    /// app can never ask again — and for an ad-hoc signed binary the grant is
    /// lost on *every rebuild*, because locationd keys the record on the code
    /// directory hash and swiftc mints a new one each time. The user who set
    /// this flag in 2026 and then travelled was still being drawn their old
    /// city months later with nothing in the logs to say why.
    ///
    /// So the question is no longer "have we ever asked" but "have we asked
    /// under THIS binary". A rebuild changes the token, which is exactly when
    /// TCC has forgotten and exactly when asking again is legitimate. Same
    /// binary, same token: still asked at most once, so no dialog spam.
    ///
    /// A denial is not affected. Denial leaves the status at `.denied`, which
    /// is never re-prompted — macOS would not show a dialog anyway.
    var locationPromptBuild: String?

    /// Most cities that can be in the list at once, including the detected one.
    static let maxPlaces = 5

    /// Everything selectable, located place first.
    var allPlaces: [Place] { (place.map { [$0] } ?? []) + otherPlaces }

    var isPlaceListFull: Bool { allPlaces.count >= Config.maxPlaces }

    /// Add a searched city and make it the scene. Returns false if it is
    /// already listed or the list is full.
    @discardableResult
    mutating func addPlace(_ p: Place) -> Bool {
        if allPlaces.contains(where: { $0.name == p.name }) {
            scenePlaceName = p.name          // already there: just select it
            return true
        }
        guard !isPlaceListFull else { return false }
        if place == nil { place = p } else { otherPlaces.append(p) }
        scenePlaceName = p.name
        return true
    }

    /// Remove a city. The detected location cannot be removed — resetting is
    /// what you want there.
    mutating func removePlace(named name: String) {
        guard place?.name != name else { return }
        otherPlaces.removeAll { $0.name == name }
        if scenePlaceName == name { scenePlaceName = nil }
    }

    /// True when the scene is following wherever you actually are.
    ///
    /// Defined as "the place being drawn IS the detected one", rather than by
    /// inspecting `scenePlaceName` directly. The two used to disagree: a
    /// `scenePlaceName` naming a place that is no longer in the list — which is
    /// what a stored city name becomes the moment the detected place is
    /// re-geocoded under a different name — makes `scenePlace` fall back to the
    /// detected place while the old test said we were pinned to a city. Callers
    /// gate location refreshes on this, so that disagreement quietly stopped the
    /// scene following you.
    var isShowingDetectedPlace: Bool {
        guard let p = place else { return false }
        return scenePlace.name == p.name
    }

    /// The place the scene actually renders for.
    var scenePlace: Place {
        if let n = scenePlaceName, let p = allPlaces.first(where: { $0.name == n }) { return p }
        return place ?? Config.fallbackPlace()
    }

    /// Compass bearing the display faces, 0 = north. Governs which part of the
    /// sky fills the screen.
    var facingAz: Double = 180

    /// Custom keeps the bearing you set. Dynamic follows whatever is up, so the
    /// sun and moon are always on screen.
    ///
    /// DYNAMIC BY DEFAULT, and the reason is not only that it looks better.
    /// A fixed bearing has to have a value, and the old default was 180 —
    /// facing south. That is a northern-hemisphere assumption baked into a
    /// number: south is where the sun is from London or Delhi, and it is the
    /// one direction the sun never goes from Sydney or Santiago. A southern
    /// user opening this for the first time got a sky with nothing in it.
    ///
    /// Dynamic has no such bias. It follows whatever is actually up, so it is
    /// correct at 28N and 34S without either being a special case, which is
    /// what "works from anywhere" has to mean.
    var headingMode: HeadingMode = .dynamic

    // ---- Appearance, on three independent axes.
    //
    // `shape` and `finish` are kept ONLY to migrate an existing config; nothing
    // reads them after `init(from:)` has run. They cannot simply be deleted: a
    // config written by 0.2 has them and has none of the three below, and a user
    // updating should not have their wallpaper change shape underneath them.
    var shape: MosaicShape = .square
    var finish: MosaicFinish = .glass

    /// What the cells are made of. See `MosaicMaterial`.
    var material: MosaicMaterial = .glass

    /// Outline: 0 a square, 1 a circle, anything between a rounded square.
    /// Replaces the old square-or-dot switch with the continuum it always was.
    var rounding: Double = 0

    /// Whether SIZE carries tone. 0 fills the cell and lets colour carry it; 1
    /// is a halftone, where a dark cell's tile shrinks to nothing and a bright
    /// one grows until it meets its neighbours.
    ///
    /// Separated from `rounding` because they were tangled: choosing dots used
    /// to change BOTH the outline and how the picture was read, so there was no
    /// way to have round tiles that filled their cells, or square ones that
    /// shrank with tone. The second is the sequin wall.
    var halftone: Double = 0

    /// How rough the surface is: 0 polished, 1 ground glass.
    ///
    /// The fourth appearance axis, and the one that makes the other three stop
    /// looking rendered. A perfectly smooth dome returns an identical highlight
    /// from every tile, so a wall of them reads as a repeated stamp rather than
    /// a material. Roughness scatters the reflection — the same reason a frosted
    /// pane glows where a polished one glints — and it is what separates
    /// polished glass from sea glass, chrome from brushed steel, and a toy from
    /// a moulded object.
    var roughness: Double = 0

    /// How much a block's HEIGHT colours it, 0..1.
    ///
    /// The relief already says how far each block stands out and carried that
    /// entirely in its shading, so the wall had depth in its light and none in
    /// its colour. This puts depth on the colour axis by aerial perspective:
    /// proud blocks are the near layer and keep their colour, flush blocks are
    /// the far one and are drawn toward the haze — desaturated, cooler, lower in
    /// contrast, which is the measured behaviour of air in front of something
    /// rather than a chosen palette.
    var depthMap: Double = 0

    /// How strong the painted line between tiles is, 0..1.
    ///
    /// Was a fixed value, and at that strength it darkened the outer band of
    /// every tile to roughly half brightness — a dark ring around each block
    /// rather than a line between them, which is most of what made flat tiles
    /// read as beads. Default is well below the old value; 0 removes it and
    /// lets the relief alone separate the blocks, which is what the relief is
    /// for.
    var grout: Double = 0.35

    /// How dark the contact shadow between blocks is, 0..1.
    ///
    /// A block lower than its neighbour sits in a trench and the light reaching
    /// its face is cut by whatever stands over it. That has always been drawn;
    /// it just could not be turned down, and it is the other half of how much
    /// the wall reads as separate blocks rather than a printed grid.
    var shadow: Double = 1

    /// Nominal mosaic rows down the screen.
    var gridRows: Int = 36

    /// Colour quantisation step; higher is chunkier.
    var poster: Double = 16

    // MARK: - Relief
    //
    // The mosaic is a wall of blocks extruded toward you by their own
    // brightness. These controls are its material and its light; they
    // replace the old single `glassAmplify` bevel knob, whose key is simply
    // ignored when an older config.json is read.

    /// How far the blocks stand out of the wall, 0 flat to 1 deep.
    var reliefDepth: Double = 0.5

    /// How much a block's height follows FEATURES rather than plain tone. At 0
    /// height is straight cell luminance, which on a smooth sky gives a smooth
    /// swell and nothing that reads as an object; at 1 the sky presses flat and
    /// the moon, the sun and lightning stand right out of the wall.
    var emphasis: Double = 0.8

    /// How hard the light is, 0..1. WHERE it comes from is not a setting: the
    /// blocks are lit by the sun and the moon, from the screen positions they
    /// are actually drawn at.
    var lightIntensity: Double = 0.8

    /// How far the view is displaced through the block. Glass finish only —
    /// a flat tile is opaque and has nothing to transmit.
    var refraction: Double = 0.3

    /// Per-channel split of the refraction, giving a chromatic fringe where the
    /// blocks lean hardest. Glass only.
    var dispersion: Double = 0.15

    /// Scatter of the transmitted image. Glass only.
    var frost: Double = 0

    /// Per-block jitter of height, tilt and rotation, so the wall is not
    /// perfectly coursed. Applies to both finishes.
    var splay: Double = 0.15

    /// How long a block takes to rise or fall to a new height. 0 is the old
    /// behaviour — the height is assigned, so a block that should be taller is
    /// taller in the very next frame — and turning it up lets the wall settle
    /// into a new sky over a second or two instead of snapping to it.
    var reliefRise: Double = 0.4

    /// Frame rate ceiling. The display link still paces to the panel; this only
    /// lowers it. Measured on an M1 Pro at 4112x2658: 60fps costs ~6% of one
    /// core, 30fps ~3%, scaling linearly — the work is per-frame, not per-pixel
    /// bound. The scene's fastest motion is rain, and nothing in it needs more
    /// than 30, so that is the default. Raise it if you want.
    var maxFPS: Int = 30

    /// How fast the world moves, independent of how often it is drawn.
    /// 1.0 is real time; lower is calmer.
    var motionSpeed: Double = 1.0

    /// EXPERIMENTAL. Let the sun's disc, the moon, lightning and glints on wet
    /// glass go brighter than display white, into whatever headroom the panel
    /// is offering at that moment.
    ///
    /// Off by default, and deliberately so: it costs a 16-bit float surface,
    /// an extended colour space and a compositor path that all draw more power,
    /// which is unkind to a battery and works the GPU harder for a wallpaper.
    ///
    /// Read the honest caveat before wiring anything else to this: macOS does
    /// NOT grant EDR to a window below the normal window level, and the
    /// wallpaper sits far below it, at the desktop level. Measured on an M1 Pro
    /// with 16.0 of potential headroom — the identical Metal layer at desktop
    /// level never rises above the 1.2 idle floor, and at normal level reaches
    /// 16.0 within a second. So this setting can only ever do something in the
    /// SCREEN SAVER, which runs above the normal level. The wallpaper honours
    /// it by asking, measuring, and reporting that it was refused, rather than
    /// by pretending. See `WallpaperSurface.refreshHeadroom`.
    var hdr: Bool = false

    /// Desktop widget rectangles, as fractions of the screen. Water lands on
    /// these the way it lands on the dock. macOS will not tell us where widgets
    /// are, so they are configured rather than detected.
    var widgets: [WidgetRect] = []

    /// Where the dock actually is, as fractions of the screen.
    ///
    /// Nil — the default, and what every user who never opens the Elements pane
    /// keeps — means "work it out", which `Furniture.desktop` does from
    /// com.apple.dock's tile size and item count plus the screen's insets. That
    /// is a good guess and not more than one: a stack, a wide separator, a
    /// magnified dock or a second display all move the real thing. When the user
    /// has corrected the dock on the Elements grid, this measurement is better
    /// than the guess and replaces it.
    var dockRect: WidgetRect?

    // MARK: - Weather on the desktop
    //
    // The wallpaper draws BEHIND the dock, the widgets and the menu bar, so
    // weather that lands on one of them shows in the space around it: spray
    // thrown up off the lip, a wet band along the top edge, snow lying on it,
    // frost blooming out of it. Each is opt-out on its own, because which of
    // them you want marked is a matter of taste and of what your desktop
    // actually looks like — a hidden dock has no lip to wet.

    /// Let weather mark the dock.
    var wetDock: Bool = true

    /// Let weather mark the desktop widgets listed in `widgets`.
    var wetWidgets: Bool = true

    /// Let weather mark the menu bar. Off by default: it is the one strip that
    /// is always there whatever you are doing, and water on it reads as a UI
    /// glitch rather than as weather.
    var wetMenuBar: Bool = false

    /// How strongly weather marks the furniture, 0 none to 1 full. Separate
    /// from the switches so it can be dialled back rather than turned off.
    var furnitureWetness: Double = 1.0

    /// The pane itself: droplets clinging, running and beading on the screen as
    /// though you were looking through a window. Off leaves the sky alone.
    var paneWater: Bool = true

    /// How strongly water marks the pane, 0 none to 1 full.
    var paneWaterAmount: Double = 1.0

    /// Keep drawing while the desktop is completely covered.
    ///
    /// Off by default and it should stay off: when every pixel is hidden behind
    /// a fullscreen app, frames are pure battery cost with nothing to show for
    /// them. This does NOT tear anything down — the window, textures and scene
    /// state all stay live, so coming back is one frame with no reload. Turn it
    /// on if you want to satisfy yourself the resume is genuinely instant.
    var renderWhenOccluded: Bool = false

    /// Drop the detail passes and halve the frame rate on battery.
    var lowPowerOnBattery: Bool = true

    // `matchPixelGrid` used to live here: a switch between snapping the cell
    // pitch to the display's pixel height and not bothering. It is gone, and
    // the fit is now always exact. The shader derives the pitch per axis
    // unconditionally, so the grid registered with the display edge whichever
    // way the switch was set — it had stopped doing anything worth a checkbox.

    // MARK: - Per-surface appearance
    //
    // The desktop, the lock screen and the screen saver are drawn by the same
    // engine, so each can either follow the desktop or be its own thing — a
    // calmer grid on the lock screen, a different city on the saver.

    /// One surface's look. Mirroring is the default because having three
    /// independent sets of settings is a worse starting point than one.
    struct SurfaceStyle: Codable, Equatable {
        var mirrorsDesktop: Bool = true
        var shape: MosaicShape = .square
        var finish: MosaicFinish = .glass
        var gridRows: Int = 36
        var poster: Double = 16
        // Relief is deliberately NOT per-surface. It is the material the whole
        // mosaic is made of, and three independent copies of six sliders is a
        // worse answer than one wall that looks the same wherever it is drawn.
        var headingMode: HeadingMode = .custom
        var facingAz: Double = 180
        var scenePlaceName: String?

    // A per-surface `hasAskedForLocation` used to sit here. It was never read by
    // anything: location is asked for once by the app, not once per surface, and
    // the real gate is `locationPromptBuild` on Config itself. Removed rather
    // than left to imply a mechanism that does not exist.
    }

    var lock = SurfaceStyle()
    var saver = SurfaceStyle()

    /// Resolve a surface's style into a full config. Mirroring returns self, so
    /// there is exactly one render path however it is configured.
    func resolved(_ style: SurfaceStyle) -> Config {
        guard !style.mirrorsDesktop else { return self }
        var c = self
        c.shape = style.shape
        c.finish = style.finish
        c.gridRows = style.gridRows
        c.poster = style.poster
        c.headingMode = style.headingMode
        c.facingAz = style.facingAz
        c.scenePlaceName = style.scenePlaceName ?? scenePlaceName
        return c
    }

    var lockConfig: Config { resolved(lock) }
    var saverConfig: Config { resolved(saver) }

    /// Which icon design the app wears. 002 — the El mark — is the default.
    var appIcon: AppIconStyle = .mark

    /// Whether the first-run flow has been completed.
    ///
    /// Not "has the app launched before" — that is a different question and the
    /// wrong one. A user who quits during onboarding should see it again; a user
    /// who finished it should never see it, even after a rebuild mints a new code
    /// identity. So it is set only when the flow reaches an end the user chose.
    var hasOnboarded: Bool = false

    /// How much the wall shimmers, 0 still to 1 lively.
    ///
    /// The scene used to shimmer by accident — cells crossing quantisation
    /// boundaries at slightly different moments — which is why it read as life
    /// sometimes and as noise the rest of the time. Fixing that removed the only
    /// thing keeping a still sky from looking frozen, so it is back on purpose,
    /// spatially coherent and continuous in time. Costs frames: see
    /// `applyFrameRate`.
    var shimmer: Double = 0.35

    /// Look for new versions on GitHub, and offer them.
    ///
    /// On by default, and that default matters more than usual here: this app is
    /// meant to be handed to people who will never go looking for an update, and
    /// an install frozen on the day it was downloaded keeps every bug fixed
    /// afterwards. Checking is quiet; nothing is ever installed without the user
    /// agreeing to it.
    var automaticUpdates: Bool = true

    /// Fetch live weather. Off means the scene renders a clear calm day.
    var liveWeather: Bool = true

    /// After a long gap — sleep, a closed lid, a stretch behind a fullscreen
    /// app — replay the interval that was missed as a quick time-lapse before
    /// settling into the present, rather than teleporting the sun.
    var playbackOnWake: Bool = true

    /// How long the wake replay is allowed to run. Lower is a brisk flick
    /// through the missed hours; higher lets you actually watch them go by.
    var playbackMaxSeconds: Double = 5

    /// Start the screen saver as soon as the screen locks, instead of waiting
    /// out the system idle timer (System Settings › Lock Screen, currently 5
    /// minutes by default).
    ///
    /// This is what makes the lock screen LIVE rather than a still. Locking
    /// alone only shows the desktop picture — macOS does not start the saver
    /// until the idle timeout elapses, so without this you see a frozen frame
    /// for the first five minutes.
    /// Off by default. Starting the saver on top of an already-locked screen
    /// dismissed the lock instead of animating it; the supported order is
    /// saver-first-then-lock, which the system idle timer already does.
    var animateOnLock: Bool = false

    /// Periodically write a still of the current scene and set it as the
    /// desktop picture, so the lock screen shows the scene rather than whatever
    /// was there before. See LockStill.swift for why this is a still.
    ///
    /// Off by default because turning it on replaces your desktop picture,
    /// which is not Elemental's to change without being asked.
    var syncLockScreen: Bool = false

    // MARK: - Storage

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Elemental", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Copy of a config.json that could not be read at all, kept so a file the
    /// app refuses to parse is still recoverable by hand.
    static var backupURL: URL { directory.appendingPathComponent("config.json.bak") }

    static func load() -> Config { loadFromDisk().config }

    /// Read config.json, reporting whether an existing file was lost.
    ///
    /// `fileWasUnreadable` is true only when a file exists but nothing at all
    /// could be read out of it — it is NOT set for a file that is merely old or
    /// partial, which now decodes fine (see the tolerant `init(from:)` below).
    /// Callers must not `save()` on a true: what they are holding is a blank
    /// default, and writing it back would overwrite both config.json and the
    /// screen saver's ByHost copy of it with nothing.
    static func loadFromDisk() -> (config: Config, fileWasUnreadable: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else {
            return (Config(), false)      // nothing saved yet: defaults are correct
        }
        if let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return (cfg, false)
        }
        // Not JSON, or not an object. Preserve it before anything else runs, so
        // a hand-edit with a stray comma costs a text edit rather than the
        // whole place list.
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: backupURL, options: .atomic)
        NSLog("Elemental: config.json could not be read; a copy is at %@ and it will not be overwritten",
              backupURL.path)
        return (Config(), true)
    }

    /// Preferences domain the screen saver reads from.
    ///
    /// This is a ByHost domain, which is what ScreenSaverDefaults maps to and
    /// what the legacyScreenSaver sandbox permits. Do NOT go back to writing a
    /// file inside the .saver bundle: bundle resources are covered by the code
    /// signature, so modifying one invalidates the seal and macOS then kills
    /// the saver at load with SIGKILL (Code Signature Invalid) — which looks
    /// exactly like a grey screen.
    static let saverDomain = "com.prakritmaan.elemental.saver"

    /// Key the desktop's current reading is published under, in that same domain.
    static let saverWeatherKey = "weather"

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory,
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)

        // Hand the same settings to the screen saver. It cannot read
        // Application Support under its sandbox, but it can read its own ByHost
        // preferences, so the lock screen shows the same place, theme and grid
        // as the desktop instead of falling back to defaults.
        if let json = String(data: data, encoding: .utf8) {
            CFPreferencesSetValue("config" as CFString, json as CFString,
                                  Self.saverDomain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(Self.saverDomain as CFString,
                                     kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
    }

    /// Where to draw the sky for before the user has set anything.
    ///
    /// Longitude is estimated from the system timezone's UTC offset, which is
    /// accurate to roughly a timezone's width — enough that the sun is at the
    /// right height for the time of day on first launch, instead of the scene
    /// opening on a null sky at altitude zero. Latitude is a mid-northern
    /// guess and gets replaced the moment Location Services or a manual entry
    /// resolves.
    static func fallbackPlace() -> Place {
        let offsetHours = Double(TimeZone.current.secondsFromGMT()) / 3600
        // Latitude cannot be derived from a timezone — the whole point of a
        // timezone is that it is a band of longitude. So the hemisphere is taken
        // from the one hint the system does give: a timezone identifier names a
        // region, and the southern ones are enumerable. Getting the SIGN right
        // matters far more than the magnitude, because it decides which way the
        // sun goes round the sky and whether the seasons are inverted; being 15
        // degrees out in latitude only shifts the sun's height a little.
        let tz = TimeZone.current.identifier
        let southern = ["Australia/", "Pacific/Auckland", "America/Argentina",
                        "America/Santiago", "America/Sao_Paulo", "America/Lima",
                        "Africa/Johannesburg", "Africa/Nairobi", "Indian/",
                        "Antarctica/"].contains { tz.hasPrefix($0) }
        return Place(name: "Approximate (\(TimeZone.current.identifier))",
                     latitude: southern ? -33 : 40,
                     longitude: max(-180, min(180, offsetHours * 15)),
                     timeZone: TimeZone.current.identifier)
    }

    /// The place to render for, real or estimated. Honours the scene selection.
    var effectivePlace: Place { scenePlace }

    /// Fold the config into a SceneState.
    ///
    /// Every appearance field must be listed here. Anything omitted silently
    /// keeps the SceneState default, which is how the screen saver ended up
    /// rendering with a different glass relief from the desktop. Astro is filled in separately because
    /// it depends on the clock as well as the place.
    func apply(to state: inout SceneState) {
        state.facingAz = Float(facingAz)
        state.headingMode = headingMode
        state.shape = shape
        state.finish = finish
        state.material = material
        state.rounding = Float(max(0, min(1, rounding)))
        state.halftone = Float(max(0, min(1, halftone)))
        state.roughness = Float(max(0, min(1, roughness)))
        state.depthMap = Float(max(0, min(1, depthMap)))
        state.grout = Float(max(0, min(1, grout)))
        state.shadow = Float(max(0, min(1, shadow)))
        state.gridRows = gridRows
        state.poster = Float(poster)
        state.reliefDepth = Float(reliefDepth)
        state.reliefEmphasis = Float(emphasis)
        state.lightIntensity = Float(lightIntensity)
        state.refraction = Float(refraction)
        state.dispersion = Float(dispersion)
        state.frost = Float(frost)
        state.splay = Float(splay)
        state.shimmer = Float(shimmer)
        state.reliefRise = Float(reliefRise)
    }
}

// MARK: - Tolerant decoding
//
// Swift's synthesized `init(from:)` treats every non-optional property as
// required: a key that is missing from the JSON throws `keyNotFound` instead of
// falling back to the property's default. Nothing above changes shape without
// that mattering — the day a new field is added here, every config.json written
// before it stops decoding AS A WHOLE, `load()` hands back a blank `Config()`,
// and the first `save()` writes that blank over the user's places, grid,
// heading and per-surface styles, plus the screen saver's ByHost copy of them.
//
// So decode key by key. A key that is absent, null or the wrong type keeps the
// declared default and every other key still lands, which makes an older,
// partial or hand-edited file upgrade in place rather than being thrown away.
//
// These live in extensions on purpose: an `init` written inside the struct body
// suppresses the synthesized `init()`, and the defaults it produces are exactly
// what the fallbacks below are reading.

private extension KeyedDecodingContainer {
    /// The value stored under `key`, or `fallback` when it is missing, null or
    /// unreadable. Never throws: one bad key must not cost the whole file.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        // `try?` flattens here: a missing key, a null and a throw all arrive as
        // nil, and all three mean the same thing — keep the default.
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()          // the declared defaults, in one place
        self.init()
        place              = try? c.decodeIfPresent(Place.self, forKey: .place)
        otherPlaces        = c.lenient(.otherPlaces, d.otherPlaces)
        scenePlaceName     = try? c.decodeIfPresent(String.self, forKey: .scenePlaceName)
        hasAskedForLocation = c.lenient(.hasAskedForLocation, d.hasAskedForLocation)
        locationPromptBuild = try? c.decodeIfPresent(String.self, forKey: .locationPromptBuild)
        facingAz           = c.lenient(.facingAz, d.facingAz)
        headingMode        = c.lenient(.headingMode, d.headingMode)
        shape              = c.lenient(.shape, d.shape)
        finish             = c.lenient(.finish, d.finish)
        gridRows           = c.lenient(.gridRows, d.gridRows)
        poster             = c.lenient(.poster, d.poster)
        reliefDepth        = c.lenient(.reliefDepth, d.reliefDepth)
        emphasis           = c.lenient(.emphasis, d.emphasis)
        lightIntensity     = c.lenient(.lightIntensity, d.lightIntensity)
        refraction         = c.lenient(.refraction, d.refraction)
        dispersion         = c.lenient(.dispersion, d.dispersion)
        frost              = c.lenient(.frost, d.frost)
        splay              = c.lenient(.splay, d.splay)
        reliefRise         = c.lenient(.reliefRise, d.reliefRise)
        maxFPS             = c.lenient(.maxFPS, d.maxFPS)
        motionSpeed        = c.lenient(.motionSpeed, d.motionSpeed)
        hdr                = c.lenient(.hdr, d.hdr)
        widgets            = c.lenient(.widgets, d.widgets)
        dockRect           = try? c.decodeIfPresent(WidgetRect.self, forKey: .dockRect)
        wetDock            = c.lenient(.wetDock, d.wetDock)
        wetWidgets         = c.lenient(.wetWidgets, d.wetWidgets)
        wetMenuBar         = c.lenient(.wetMenuBar, d.wetMenuBar)
        furnitureWetness   = c.lenient(.furnitureWetness, d.furnitureWetness)
        paneWater          = c.lenient(.paneWater, d.paneWater)
        paneWaterAmount    = c.lenient(.paneWaterAmount, d.paneWaterAmount)
        renderWhenOccluded = c.lenient(.renderWhenOccluded, d.renderWhenOccluded)
        lowPowerOnBattery  = c.lenient(.lowPowerOnBattery, d.lowPowerOnBattery)
        lock               = c.lenient(.lock, d.lock)
        saver              = c.lenient(.saver, d.saver)
        appIcon            = c.lenient(.appIcon, d.appIcon)
        liveWeather        = c.lenient(.liveWeather, d.liveWeather)
        // Trap 10 in HANDOFF.md: every stored property must appear here or it
        // silently fails to load — which for this one would mean onboarding
        // replaying on every launch forever.
        hasOnboarded       = c.lenient(.hasOnboarded, d.hasOnboarded)
        automaticUpdates   = c.lenient(.automaticUpdates, d.automaticUpdates)
        shimmer            = c.lenient(.shimmer, d.shimmer)

        // ---- Appearance: take the new axes if they are there, otherwise
        // derive them from the old pair so an existing install looks identical
        // after an update. `dot` meant round AND size-carries-tone, which is
        // exactly the two axes it was conflating.
        if let m: MosaicMaterial = try? c.decodeIfPresent(MosaicMaterial.self, forKey: .material) {
            material = m
            rounding = c.lenient(.rounding, d.rounding)
            halftone = c.lenient(.halftone, d.halftone)
        } else {
            material = (finish == .flat) ? .matte : .glass
            rounding = (shape == .dot) ? 1 : 0
            halftone = (shape == .dot) ? 1 : 0
        }
        // Independent of the block above: these are newer than the material
        // migration, so a config written by any earlier version simply has no
        // key for them and takes the default, which is off. Both are additions
        // to how the wall looks, and an update should not silently restyle a
        // wall somebody already chose.
        roughness = c.lenient(.roughness, d.roughness)
        depthMap  = c.lenient(.depthMap,  d.depthMap)
        grout     = c.lenient(.grout,     d.grout)
        shadow    = c.lenient(.shadow,    d.shadow)
        playbackOnWake     = c.lenient(.playbackOnWake, d.playbackOnWake)
        playbackMaxSeconds = c.lenient(.playbackMaxSeconds, d.playbackMaxSeconds)
        animateOnLock      = c.lenient(.animateOnLock, d.animateOnLock)
        syncLockScreen     = c.lenient(.syncLockScreen, d.syncLockScreen)
    }
}

extension Config.SurfaceStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.SurfaceStyle()
        self.init()
        mirrorsDesktop  = c.lenient(.mirrorsDesktop, d.mirrorsDesktop)
        shape           = c.lenient(.shape, d.shape)
        finish          = c.lenient(.finish, d.finish)
        gridRows        = c.lenient(.gridRows, d.gridRows)
        poster          = c.lenient(.poster, d.poster)
        headingMode     = c.lenient(.headingMode, d.headingMode)
        facingAz        = c.lenient(.facingAz, d.facingAz)
        scenePlaceName  = try? c.decodeIfPresent(String.self, forKey: .scenePlaceName)
    }
}

// MARK: - Handing the desktop's weather to the screen saver
//
// The saver runs its own `WeatherService` and does its own network fetch. When
// that fetch does not land — which is the reported failure — it renders a
// default `WeatherState()`: a clear calm day, whatever the sky is actually
// doing. The SETTINGS reached it correctly the whole time, which is exactly what
// made this look like a settings problem when it never was one. Mimicking the
// home screen has to mean mimicking its WEATHER, not only its place and grid.
//
// So the app publishes every reading it takes into the same ByHost domain the
// config already travels through — the one domain the legacyScreenSaver sandbox
// is documented to allow — and the saver prefers that over anything it manages
// to fetch for itself. The saver's own fetch stays as the fallback for when the
// app is not running at all.
enum SaverWeather {

    /// What gets written. The coordinate travels WITH the reading because the
    /// saver is allowed to render a different place from the desktop: when
    /// `mirrorsDesktop` is off and the user has picked their own city for the
    /// saver, the desktop's weather is the wrong answer and must be ignored
    /// rather than quietly painted over the other city's sky.
    private struct Payload: Codable {
        var weather: WeatherState
        var lat: Double
        var lon: Double
        var at: Double            // epoch seconds, for staleness
        var place: String?        // the resolved place NAME, see `read`
    }

    /// Called by the app whenever a reading lands.
    static func publish(_ w: WeatherState, lat: Double, lon: Double, place: String?) {
        let p = Payload(weather: w, lat: lat, lon: lon,
                        at: Date().timeIntervalSince1970, place: place)
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        CFPreferencesSetValue(Config.saverWeatherKey as CFString, json as CFString,
                              Config.saverDomain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(Config.saverDomain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// The raw published payload, for the health check. Nil if nothing is there.
    static func published() -> (weather: WeatherState, lat: Double, lon: Double,
                                at: Double, place: String?)? {
        CFPreferencesSynchronize(Config.saverDomain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard let json = CFPreferencesCopyValue(Config.saverWeatherKey as CFString,
                                                Config.saverDomain as CFString,
                                                kCFPreferencesCurrentUser,
                                                kCFPreferencesCurrentHost) as? String,
              let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return (p.weather, p.lat, p.lon, p.at, p.place)
    }

    /// Read by the saver, for the place it is actually drawing.
    ///
    /// `maxAge` is deliberately generous. A reading three hours old is a far
    /// better answer than a default clear sky, and the easer will carry it to
    /// whatever the saver's own fetch eventually reports rather than snapping.
    ///
    /// The place test is a NAME match first, then a wide coordinate fallback,
    /// and the width is the point. The two sides legitimately disagree: the app
    /// publishes from its live `scenePlace`, which Location Services keeps
    /// re-resolving, while the saver reads the copy last written to disk by
    /// `Config.save()`. Measured on the development machine those were 0.18
    /// degrees apart for the same city — so a few-kilometre epsilon rejects the
    /// reading and hands back a default clear sky, which is the exact failure
    /// this type exists to remove. 0.35 degrees is about 39 km: comfortably
    /// inside one metropolitan area, and nowhere near a city the user actually
    /// chose as a different one.
    static func read(lat: Double, lon: Double, place: String? = nil,
                     maxAge: TimeInterval = 3 * 3600) -> WeatherState? {
        CFPreferencesSynchronize(Config.saverDomain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard let json = CFPreferencesCopyValue(Config.saverWeatherKey as CFString,
                                                Config.saverDomain as CFString,
                                                kCFPreferencesCurrentUser,
                                                kCFPreferencesCurrentHost) as? String,
              let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard Date().timeIntervalSince1970 - p.at < maxAge else { return nil }
        if let a = p.place, let b = place, a == b { return p.weather }
        guard abs(p.lat - lat) < 0.35, abs(p.lon - lon) < 0.35 else { return nil }
        return p.weather
    }
}

// MARK: - Is the screen saver actually working?

/// A diagnosis of the saver, from the desktop side.
///
/// The saver is the hardest surface to reason about from here: it runs in
/// another process, inside a sandbox, only while the screen is locked or idle,
/// and it cannot write anywhere the app can read. Every failure it has had this
/// far — a stale bundle after a rebuild, config that never arrived, weather that
/// arrived for the wrong place, a reading three hours old — looks identical from
/// the user's chair, which is "the saver is wrong". So each is checked
/// separately and named separately, because the fixes are not the same.
///
/// Deliberately read-only. Repair is a user action, never a side effect of
/// looking: installing into ~/Library/Screen Savers is exactly the kind of
/// thing that should not happen because someone opened a settings pane.
struct SaverHealth {

    enum Finding: Equatable {
        case notInstalled
        case bundleStale(installed: Date, current: Date)
        case configMissing
        case configStale(age: TimeInterval)
        case weatherMissing
        case weatherStale(age: TimeInterval)
        case weatherWrongPlace(published: String?, expected: String)

        /// What the user should be told, in one line.
        var summary: String {
            switch self {
            case .notInstalled:
                return "Elemental.saver is not installed in ~/Library/Screen Savers."
            case .bundleStale:
                return "The installed screen saver is older than this app — reinstall it."
            case .configMissing:
                return "The screen saver has never received your settings."
            case .configStale(let age):
                return String(format: "The screen saver's settings are %.0f minutes old.", age / 60)
            case .weatherMissing:
                return "The screen saver has no weather from the desktop; it will fetch its own."
            case .weatherStale(let age):
                return String(format: "The weather handed to the screen saver is %.0f minutes old.", age / 60)
            case .weatherWrongPlace(let p, let e):
                return "The screen saver's weather is for \(p ?? "an unknown place"), not \(e)."
            }
        }

        /// Whether the app can put this right on its own.
        var isRepairable: Bool {
            switch self {
            case .configMissing, .configStale, .weatherMissing, .weatherStale, .weatherWrongPlace:
                return true
            case .notInstalled, .bundleStale:
                return false            // needs a file written to ~/Library — ask first
            }
        }
    }

    var findings: [Finding] = []
    var isHealthy: Bool { findings.isEmpty }

    /// Where a saver bundle would be installed.
    static var installedSaverURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Savers/Elemental.saver", isDirectory: true)
    }

    /// Look, and report. Never writes.
    static func check(config: Config, appBuildDate: Date? = nil) -> SaverHealth {
        var h = SaverHealth()
        let fm = FileManager.default
        let saverURL = installedSaverURL

        if !fm.fileExists(atPath: saverURL.path) {
            h.findings.append(.notInstalled)
        } else if let appDate = appBuildDate,
                  let inst = (try? saverURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate,
                  // A minute of slack: the two are copied moments apart by the
                  // same build, and a sub-minute difference is not staleness.
                  inst < appDate.addingTimeInterval(-60) {
            h.findings.append(.bundleStale(installed: inst, current: appDate))
        }

        // Settings reach it through the ByHost domain, which is the one channel
        // the legacyScreenSaver sandbox allows.
        let cfgJSON = CFPreferencesCopyValue(
            "config" as CFString, Config.saverDomain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? String
        if cfgJSON == nil {
            h.findings.append(.configMissing)
        }

        // Weather travels the same way. A saver that mirrors the desktop and has
        // no published reading will fetch its own, which is not wrong but is not
        // mirroring either — so it is reported rather than passed silently.
        let want = config.scenePlace
        if let shared = SaverWeather.published() {
            if Date().timeIntervalSince1970 - shared.at > 3 * 3600 {
                h.findings.append(.weatherStale(age: Date().timeIntervalSince1970 - shared.at))
            }
            let sameName = shared.place != nil && shared.place == want.name
            let sameSpot = abs(shared.lat - want.latitude) < 0.35
                        && abs(shared.lon - want.longitude) < 0.35
            if !sameName && !sameSpot {
                h.findings.append(.weatherWrongPlace(published: shared.place, expected: want.name))
            }
        } else {
            h.findings.append(.weatherMissing)
        }
        return h
    }

    /// Put right everything that can be put right without touching ~/Library.
    ///
    /// Republishing is the whole repair: both the settings and the weather reach
    /// the saver through the same domain, and every failure mode above that is
    /// not "the bundle is wrong" is really "that domain is empty or stale".
    @discardableResult
    static func repair(config: Config, weather: WeatherState?) -> Bool {
        config.save()                       // rewrites the ByHost config copy
        if let w = weather {
            let p = config.scenePlace
            SaverWeather.publish(w, lat: p.latitude, lon: p.longitude, place: p.name)
        }
        return true
    }
}
