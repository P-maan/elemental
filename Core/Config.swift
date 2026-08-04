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
    var headingMode: HeadingMode = .custom

    var shape: MosaicShape = .square
    var finish: MosaicFinish = .glass

    /// Nominal mosaic rows down the screen.
    var gridRows: Int = 36

    /// Colour quantisation step; higher is chunkier.
    var poster: Double = 16

    /// Glass relief strength, 0 flat to 1 pressed glass block.
    var glassAmplify: Double = 0.3

    /// Frame rate ceiling. The display link still paces to the panel; this only
    /// lowers it. Measured on an M1 Pro at 4112x2658: 60fps costs ~6% of one
    /// core, 30fps ~3%, scaling linearly — the work is per-frame, not per-pixel
    /// bound. The scene's fastest motion is rain, and nothing in it needs more
    /// than 30, so that is the default. Raise it if you want.
    var maxFPS: Int = 30

    /// How fast the world moves, independent of how often it is drawn.
    /// 1.0 is real time; lower is calmer.
    var motionSpeed: Double = 1.0

    /// Desktop widget rectangles, as fractions of the screen. Water lands on
    /// these the way it lands on the dock. macOS will not tell us where widgets
    /// are, so they are configured rather than detected.
    var widgets: [WidgetRect] = []

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

    /// Glass relief strength, 0 flat to 1 pressed glass block.
    var glassAmplify: Double = 0.3
        var headingMode: HeadingMode = .custom
        var facingAz: Double = 180
        var scenePlaceName: String?

    /// Whether the permission dialog has ever been shown. Prevents re-asking on
    /// every launch, which is what happens otherwise: an ad-hoc signed build
    /// gets a new code identity on each rebuild, so TCC forgets the grant and
    /// the status returns to notDetermined.
    var hasAskedForLocation: Bool = false
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
        c.glassAmplify = style.glassAmplify
        c.headingMode = style.headingMode
        c.facingAz = style.facingAz
        c.scenePlaceName = style.scenePlaceName ?? scenePlaceName
        return c
    }

    var lockConfig: Config { resolved(lock) }
    var saverConfig: Config { resolved(saver) }

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
        return Place(name: "Approximate (\(TimeZone.current.identifier))",
                     latitude: 40,
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
        state.gridRows = gridRows
        state.poster = Float(poster)
        state.glassAmplify = Float(glassAmplify)
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
        facingAz           = c.lenient(.facingAz, d.facingAz)
        headingMode        = c.lenient(.headingMode, d.headingMode)
        shape              = c.lenient(.shape, d.shape)
        finish             = c.lenient(.finish, d.finish)
        gridRows           = c.lenient(.gridRows, d.gridRows)
        poster             = c.lenient(.poster, d.poster)
        glassAmplify       = c.lenient(.glassAmplify, d.glassAmplify)
        maxFPS             = c.lenient(.maxFPS, d.maxFPS)
        motionSpeed        = c.lenient(.motionSpeed, d.motionSpeed)
        widgets            = c.lenient(.widgets, d.widgets)
        renderWhenOccluded = c.lenient(.renderWhenOccluded, d.renderWhenOccluded)
        lowPowerOnBattery  = c.lenient(.lowPowerOnBattery, d.lowPowerOnBattery)
        lock               = c.lenient(.lock, d.lock)
        saver              = c.lenient(.saver, d.saver)
        liveWeather        = c.lenient(.liveWeather, d.liveWeather)
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
        glassAmplify    = c.lenient(.glassAmplify, d.glassAmplify)
        headingMode     = c.lenient(.headingMode, d.headingMode)
        facingAz        = c.lenient(.facingAz, d.facingAz)
        scenePlaceName  = try? c.decodeIfPresent(String.self, forKey: .scenePlaceName)
        hasAskedForLocation = c.lenient(.hasAskedForLocation, d.hasAskedForLocation)
    }
}
