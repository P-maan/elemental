//  main.swift — Elemental.app
//
//  A background agent (LSUIElement) that owns one live wallpaper per display,
//  plus a menu-bar item for control. Launching the app again from Spotlight or
//  Finder opens Settings, so hiding the menu-bar item never locks you out of
//  the preferences.

import AppKit
import Metal
import CoreLocation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config: Config
    /// Set when config.json exists but could not be read, so the config above
    /// is a blank default standing in for real settings. The automatic saves at
    /// launch are skipped in that state — see `saveUnlessRecovering`.
    private let configWasUnreadable: Bool

    override init() {
        let loaded = Config.loadFromDisk()
        config = loaded.config
        configWasUnreadable = loaded.fileWasUnreadable
        super.init()
    }

    private var surfaces: [CGDirectDisplayID: WallpaperSurface] = [:]
    private var device: MTLDevice!
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?
    private var astroTimer: Timer?
    private var locationTimer: Timer?
    private var furnitureTimer: Timer?
    private var lockStill: LockStillExporter?

    let location = LocationService()
    private let weather = WeatherService()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatal("This Mac has no Metal device.")
            return
        }
        device = dev

        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        // The chosen icon, applied to the bundle. Costs one image load and is
        // a no-op for the default, which the bundle already carries.
        AppIcons.apply(config.appIcon)
        rebuildSurfaces()

        // Write settings once at launch. This seeds the copy inside the screen
        // saver's bundle, so a freshly installed saver matches the desktop
        // immediately instead of only after the first settings change.
        saveUnlessRecovering()

        // Location: ask once on first run. If it is denied or unavailable the
        // scene still renders — it just uses whatever place is configured, and
        // Settings offers manual entry and city search.
        location.onResolve = { [weak self] place in
            self?.locationDidResolve(place)
        }
        // Errors and refusals used to go nowhere unless Settings happened to be
        // open. Now they are always recorded, so "why is it still drawing my old
        // city" has an answer sitting in the log.
        location.onUnavailable = { msg in
            NSLog("Elemental location: unavailable — %@", msg)
        }
        location.onNeedsAuthorisation = { [weak self] st in
            self?.locationNeedsAuthorisation(st)
        }
        refreshAstro()
        resolveLocationAtLaunch()

        // Astro moves slowly; once a minute is plenty and costs nothing.
        astroTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAstro()
        }

        // The furniture moves without the config changing — the dock is hidden,
        // an app quits, the tile size is dragged, a display is rescaled. Two
        // seconds is well below the time it takes to notice, and an unchanged
        // list costs a comparison and nothing else. See refreshFurnitureIfNeeded.
        furnitureTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.surfaces.values.forEach {
                $0.refreshFurnitureIfNeeded()
                // Re-derive the frame rate here too, and NOT only when a reading
                // lands. `applyFrameRate` reads the EASED weather — what is
                // actually on screen — and at the moment a reading arrives the
                // easer has only just been retargeted, so it still shows the old
                // state. A dry sky turning to rain therefore computed its rate
                // from the dry value and stayed at 6 fps for the entire ramp,
                // which is the whole of the transition the user watches. The
                // rain drew at 6 fps while the number that would have raised it
                // climbed unread until the next fetch, ten minutes later.
                $0.refreshFrameRate()
            }
        }

        // Re-check where we are on a schedule as well as on wake. A laptop that
        // stays open all day can still travel, and a sky drawn for the wrong
        // city is wrong in every element at once — which matters more than any
        // single weather variable being stale.
        locationTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.refreshEverything(reason: "periodic")
        }

        // Weather drives the cloud deck, rain, snow, fog, thunder, haze and
        // wind. Without it the renderer draws a permanently clear sky.
        weather.onUpdate = { [weak self] w in
            guard let self else { return }
            self.surfaces.values.forEach { $0.updateWeather(w) }
            self.writeStatus(w)
            // Hand the same reading to the screen saver.
            //
            // The saver fetches for itself, and when that does not land it draws
            // a default clear sky — with the right place, the right grid and the
            // right theme, because the CONFIG always reached it. That is what
            // made "the saver is not following the weather" look like a settings
            // problem when it never was one. Mimicking the home screen has to
            // include its weather.
            let p = self.config.scenePlace
            SaverWeather.publish(w, lat: p.latitude, lon: p.longitude, place: p.name)
            // Push it to the lock screen too, rather than leaving the still an
            // update behind.
            self.lockStill?.exportNow(config: self.config.lockConfig, astro: self.lockAstro())
        }
        startWeather()

        observeSystem()
        syncLockStillExporter()
        // Everything a settings change applies has to be applied once at launch
        // too, or a fresh start runs on defaults until the user happens to
        // change something — which is exactly what "I have to quit and reopen
        // it before it takes" looks like from the outside.
        applyPlaybackSetting()
        updatePowerState()
        // First run. Presented AFTER the wallpaper exists, so quitting the flow
        // early still leaves a working scene behind rather than a blank desktop.
        if !config.hasOnboarded { presentOnboarding() }

        // Seed the scene-place change detector. Left at nil, the first config
        // change of the session always looked like a move to somewhere new and
        // restarted the weather poller and cleared the falling rain for nothing.
        previousScenePlace = config.scenePlace
    }

    private var onboarding: OnboardingController?

    private func presentOnboarding() {
        onboarding = OnboardingController(
            config: config, device: device, location: location,
            onPlaceFurniture: { [weak self] in
                guard let self else { return }
                // Settings opens on the Elements pane, where "Place Widgets on
                // Screen" is the first control. Driving the overlay directly from
                // here would need SettingsWindowController to expose its panes,
                // and one extra click is a poor reason to widen that surface.
                self.showSettings()
            },
            onFinish: { [weak self] cfg in
                guard let self else { return }
                self.applyConfig(cfg)
                self.onboarding = nil
            })
        onboarding?.present()
    }

    /// Persist the settings the app writes by itself at launch — but not when
    /// the stored file could not be read.
    ///
    /// Launch used to save unconditionally, a few lines after loading. Any
    /// config.json that failed to decode therefore became a blank default that
    /// was immediately written back over both the file and the screen saver's
    /// ByHost copy, with the places, grid, heading and per-surface styles gone
    /// and nothing left to restore from. Saves the user actually asks for still
    /// go through: by then they have seen the defaults and are choosing to
    /// replace them, and the unreadable original is kept at `config.json.bak`.
    private func saveUnlessRecovering() {
        guard !configWasUnreadable else { return }
        config.save()
    }

    /// Start or stop the lock-screen still exporter to match the current
    /// setting. Called at launch AND whenever settings change — previously it
    /// only ran at launch, so turning the option on in Settings appeared to do
    /// nothing until the app was restarted.
    private func syncLockStillExporter() {
        if config.syncLockScreen {
            if lockStill == nil { lockStill = LockStillExporter(device: device) }
            lockStill?.start(configProvider: { [weak self] in self?.config.lockConfig ?? Config() },
                             astroProvider: { [weak self] in self?.lockAstro() ?? AstroState() },
                             weatherProvider: { [weak self] in self?.weather.latest ?? WeatherState() })
        } else {
            lockStill?.stop()
            lockStill = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Relaunching the app is how you get back to Settings when the menu-bar
        // item is hidden.
        showSettings()
        return true
    }

    // MARK: - Location

    /// A token that changes whenever this binary does.
    ///
    /// Elemental is signed ad hoc (`codesign -s -`), so its code directory hash
    /// is minted fresh by every build. locationd files its authorisation record
    /// under that hash, which means a rebuild is indistinguishable from a
    /// different app and the grant is gone. Size-and-mtime of the executable is
    /// a cheap stand-in for the hash: it moves for exactly the same reason, it
    /// needs no Security framework, and getting it wrong costs one extra dialog
    /// rather than a wrong sky.
    private static var buildToken: String {
        guard let exe = Bundle.main.executableURL,
              let a = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let size = a[.size] as? NSNumber,
              let date = a[.modificationDate] as? Date
        else { return "unknown" }
        return String(format: "%llu-%.0f", size.uint64Value, date.timeIntervalSince1970)
    }

    /// Decide, once per launch, whether to ask for location or just refresh it.
    ///
    /// The rule this replaces was "ask if we have no place and have never
    /// asked". Both halves were wrong for a user who travels:
    ///
    ///   * `hasAskedForLocation` never becomes false again, so the FIRST time
    ///     the grant was lost was also the LAST time the app would ever ask.
    ///   * having a stored place was treated as proof that location works. It
    ///     is proof only that it worked once. A stale place is precisely the
    ///     symptom, so using it as the reason not to re-check is circular.
    ///
    /// Now the status decides. Authorised, refresh quietly. Refused, respect it
    /// and say so. Undetermined, ask — but at most once per build, because a
    /// build is exactly the granularity at which TCC forgets.
    private func resolveLocationAtLaunch() {
        let st = location.authorization
        NSLog("Elemental location: launch status=%@ storedPlace=%@ following=%@",
              LocationService.statusName(st),
              config.place?.name ?? "none",
              config.isShowingDetectedPlace ? "yes" : "no")

        if location.isAuthorised {
            location.refreshIfAuthorised()
            return
        }
        guard st == .notDetermined else {
            // Denied or restricted. Asking again cannot show a dialog, so don't.
            locationNeedsAuthorisation(st)
            return
        }

        let token = Self.buildToken
        guard config.locationPromptBuild != token else {
            NSLog("Elemental location: undetermined, but already prompted under this build — not re-asking")
            locationNeedsAuthorisation(st)
            return
        }
        NSLog("Elemental location: undetermined under a new build (%@) — asking", token)
        config.hasAskedForLocation = true
        config.locationPromptBuild = token
        saveUnlessRecovering()
        location.requestOnce()
    }

    /// The scene cannot follow you and something should say so.
    ///
    /// Deliberately not a modal: this fires from wake and unlock handlers, and a
    /// dialog on every lid-open would be worse than the bug. It writes the state
    /// where the user can find it — the menu bar item's tooltip and the status
    /// file — and Settings turns its "Use Location Services" button back on.
    private func locationNeedsAuthorisation(_ st: CLAuthorizationStatus) {
        let name = LocationService.statusName(st)
        NSLog("Elemental location: NOT FOLLOWING YOU — authorisation is %@. "
            + "The scene is pinned to the stored place '%@'. "
            + "Open Settings › Places and press Use Location Services to re-request.",
              name, config.scenePlace.name)
        locationBlocked = true
        statusItem?.button?.toolTip =
            "Elemental — location is \(name); the sky is drawn for \(config.scenePlace.name)"
        settings?.refreshIfVisible(config: config)
    }

    /// True when the last attempt to follow the user was refused. Settings reads
    /// it to re-enable the re-request button, which was otherwise disabled for
    /// good the moment any place got stored.
    private(set) var locationBlocked = false

    /// A location that has genuinely moved should move the scene, not merely
    /// be recorded. The 0.05 degree threshold is about 5km — enough to ignore
    /// GPS jitter while still catching a real journey.
    ///
    /// The threshold governs the sky RESET only. It has never gated the move
    /// itself: the scene is drawn for `config.scenePlace`, which is the newly
    /// stored place either way, and it has nothing to do with picking a city by
    /// hand — that path does not come through here at all.
    private func locationDidResolve(_ place: Place) {
        locationBlocked = false
        statusItem?.button?.toolTip = nil
        let moved = config.place.map { p in
            abs(p.latitude - place.latitude) > 0.05 || abs(p.longitude - place.longitude) > 0.05
        } ?? true
        // Whether we were following the detected place has to be read BEFORE
        // the new one is stored, and then carried across.
        //
        // This is what stopped the scene following you. `scenePlaceName` holds
        // a NAME, and Settings writes the detected city's name into it the
        // moment you click that row in the list. Travel far enough for the
        // reverse geocode to return a different name and that stored name now
        // matches nothing: `scenePlace` quietly falls back to the detected
        // place, so the scene looks right, but `isShowingDetectedPlace` goes
        // false — and `refreshEverything` bails out on exactly that flag. Every
        // later refresh, periodic, wake and unlock alike, returned immediately,
        // so the scene stayed wherever that one fix left it and never followed
        // you again. Re-selecting the city by hand was the only way back, which
        // is precisely "it does not update automatically".
        let wasFollowing = config.isShowingDetectedPlace
        config.place = place
        if wasFollowing { config.scenePlaceName = place.name }
        config.save()
        if moved && config.isShowingDetectedPlace {
            NSLog("Elemental: moved to %@ - resetting sky", place.name)
            // Anything still falling belongs to the sky we left.
            surfaces.values.forEach { $0.locationChanged() }
        }
        // Keep the change detector in step. It is only ever updated inside
        // applyConfig, so a location resolving behind its back left it holding
        // a place the scene had already left.
        previousScenePlace = config.scenePlace
        refreshAstro()
        startWeather()
        // Settings may be open with a greyed-out "Use Location Services"
        // waiting to flip to "Location Detected".
        settings?.refreshIfVisible(config: config)
    }

    func applicationWillTerminate(_ note: Notification) {
        surfaces.values.forEach { $0.close() }
        lockStill?.stop()
        locationTimer?.invalidate()
    }

    // MARK: - Surfaces

    /// Create or update one surface per screen. Surfaces for displays that are
    /// still attached are REUSED — this is not a teardown path.
    private func rebuildSurfaces() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(num.uint32Value)
            seen.insert(id)
            if let existing = surfaces[id] {
                existing.apply(config: config, screen: screen)
            } else if let s = WallpaperSurface(screen: screen, config: config, device: device) {
                s.setAstroProvider { [weak self] date in
                    self?.astro(at: date) ?? AstroState()
                }
                surfaces[id] = s
                s.resume()
            }
        }
        // Only displays that genuinely went away get closed.
        for (id, s) in surfaces where !seen.contains(id) {
            s.close()
            surfaces.removeValue(forKey: id)
        }
        refreshAstro()
    }

    /// Astronomy for an arbitrary instant, for the currently selected city.
    /// Used both for "now" and, during a wake replay, for every point across
    /// the interval that was missed.
    private func astro(at date: Date) -> AstroState {
        let p = config.scenePlace
        return Astro.update(lat: p.latitude, lon: p.longitude,
                            facingAz: config.facingAz, date: date)
    }

    private func currentAstro() -> AstroState { astro(at: Date()) }

    /// The lock screen may be pointed at a different city and heading, so it
    /// gets its own astronomy rather than reusing the desktop's.
    private func lockAstro() -> AstroState {
        let c = config.lockConfig
        let p = c.scenePlace
        return Astro.update(lat: p.latitude, lon: p.longitude, facingAz: c.facingAz, date: Date())
    }

    /// Record what the scene is currently being driven by. Handy when the sky
    /// looks wrong and you want to know whether it is the data that is off or
    /// the drawing.
    private func writeStatus(_ w: WeatherState) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let p = config.scenePlace
        var out = ""
        out += "updated    " + f.string(from: Date()) + "\n"
        out += "place      " + p.name + "  (" + String(p.latitude) + ", " + String(p.longitude) + ")\n"
        out += "condition  " + String(describing: w.kind) + "   wmo code " + String(w.code) + "\n"
        out += "cloud      " + String(Int(w.cover)) + "%\n"
        out += "rain       " + String(w.rain) + " mm    snow " + String(w.snow) + " cm\n"
        out += "wind       " + String(Int(w.wind)) + " km/h from " + String(Int(w.windDir)) + " deg\n"
        out += "humidity   " + String(Int(w.humidity)) + "%\n"
        out += "visibility " + String(Int(w.visibility)) + " m\n"
        out += "uv         " + String(w.uv) + "\n"
        out += "aqi        " + String(Int(w.aqi)) + "   smoke " + String(w.smoke) + "\n"
        out += "\n-- cloud by layer --\n"
        out += "low/mid/hi " + String(Int(w.cloudLow)) + " / " + String(Int(w.cloudMid))
                             + " / " + String(Int(w.cloudHigh)) + " %\n"
        out += "\n-- air --\n"
        out += "temp/feels " + String(w.temperature) + " / " + String(w.apparent) + " C\n"
        out += "dew point  " + String(w.dewPoint) + " C   spread " + String(w.dewSpread) + "\n"
        out += "pressure   " + String(w.pressureMSL) + " hPa\n"
        out += "gusts      " + String(Int(w.gusts)) + " km/h   gustiness " + String(w.gustiness) + "\n"
        out += "\n-- convection --\n"
        out += "cape       " + String(w.cape) + " J/kg\n"
        out += "lifted idx " + String(w.liftedIndex) + "\n"
        out += "freezing   " + String(w.freezingLevel) + " m\n"
        out += "bl height  " + String(w.boundaryLayer) + " m\n"
        out += "\n-- derived --\n"
        out += "storm      " + String(w.convectiveEnergy) + "\n"
        out += "fogginess  " + String(w.fogginess) + "\n"
        out += "frozen     " + String(w.frozenFraction) + "\n"
        out += "rain inten " + String(w.rainIntensity) + "\n"
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? out.write(to: Config.directory.appendingPathComponent("status.txt"),
                       atomically: true, encoding: .utf8)
    }

    private func startWeather() {
        let p = config.scenePlace
        weather.start(at: Coordinate(latitude: p.latitude, longitude: p.longitude))
    }

    private func refreshAstro() {
        let a = currentAstro()
        surfaces.values.forEach { $0.updateAstro(a) }
    }

    /// A settings control changed.
    ///
    /// Split in two, because it used to do everything on every change and a
    /// slider sends one of these per mouse move. The expensive half — a JSON
    /// write plus a ByHost preferences sync, a weather poller restart, and a
    /// full offscreen render encoded to PNG and installed as the desktop
    /// picture — was running dozens of times a second while you dragged. That
    /// is the lag.
    ///
    /// What the eye needs is only the first half: push the appearance to the
    /// live surfaces so the preview tracks the control. Everything else can
    /// wait until the user stops moving.
    func applyConfig(_ newConfig: Config) {
        let iconChanged = newConfig.appIcon != config.appIcon
        config = newConfig
        if iconChanged { AppIcons.apply(config.appIcon) }
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            surfaces[CGDirectDisplayID(num.uint32Value)]?.apply(config: config, screen: screen)
        }
        refreshAstro()
        // A different city means different weather — and anything still falling
        // belongs to the sky we just left. Cheap, and wrong to defer: the old
        // city's rain would keep falling for as long as the debounce.
        if newConfig.scenePlace != previousScenePlace {
            previousScenePlace = newConfig.scenePlace
            surfaces.values.forEach { $0.locationChanged() }
            startWeather()
        }
        updatePowerState()
        applyPlaybackSetting()
        resumeVisible()
        scheduleSettle()
    }

    /// The expensive half, coalesced. Any further change inside the window
    /// replaces the pending one, so a drag costs exactly one of these when it
    /// ends rather than one per frame.
    private var settleTimer: Timer?

    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) {
            [weak self] _ in self?.settleConfig()
        }
    }

    private func settleConfig() {
        settleTimer = nil
        config.save()
        syncLockStillExporter()
    }

    var currentConfig: Config { config }

    // MARK: - System notifications
    //
    // Every one of these is pause/resume. None of them rebuild anything.

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.rebuildSurfaces() }

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.surfaces.values.forEach { $0.pause() } }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.resumeVisible(); self?.refreshEverything(reason: "wake") }
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.surfaces.values.forEach { $0.pause() } }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.resumeVisible(); self?.refreshEverything(reason: "display wake") }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            // Nothing can see the desktop window behind loginwindow, so stop
            // drawing it — the saver takes over as the visible surface.
            self.surfaces.values.forEach { $0.pause() }
            // Put a still of this exact moment on the lock screen.
            self.lockStill?.exportNow(config: self.config.lockConfig, astro: self.lockAstro())
            self.startScreenSaverIfWanted()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
            [weak self] _ in
            self?.lockLog("screenIsUnlocked")
            self?.resumeVisible()
            self?.refreshEverything(reason: "unlock")
        }
        // Screen saver lifecycle, so we can tell "never started" from
        // "started and was dismissed".
        for n in ["com.apple.screensaver.didstart", "com.apple.screensaver.didstop",
                  "com.apple.screensaver.willstart", "com.apple.screensaver.willstop"] {
            dnc.addObserver(forName: .init(n), object: nil, queue: .main) { [weak self] _ in
                self?.lockLog("notification: \(n)")
            }
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) {
                [weak self] _ in self?.updatePowerState() }
        updatePowerState()
    }

    /// Kick the screen saver off at lock rather than waiting out the idle
    /// timer. Small delay so loginwindow has settled first, otherwise the
    /// engine can come up behind it and immediately exit.
    /// Everything that happens on the way to an animated lock screen, written
    /// to a file so it survives the lock and can be read afterwards. The
    /// unified log was giving us nothing, which made this impossible to reason
    /// about — this is deliberately dumb and reliable.
    private func lockLog(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let entry = f.string(from: Date()) + "  " + line + "\n"
        let url = Config.directory.appendingPathComponent("lock-debug.log")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func startScreenSaverIfWanted() {
        lockLog("screenIsLocked received; animateOnLock=\(config.animateOnLock)")
        guard config.animateOnLock else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            let c = NSWorkspace.OpenConfiguration()
            // Never activate: bringing the app forward dismissed the lock
            // screen outright, which is worse than not animating at all.
            c.activates = false
            c.addsToRecentItems = false
            self.lockLog("launching ScreenSaverEngine")
            NSWorkspace.shared.openApplication(at: url, configuration: c) { app, err in
                if let err {
                    self.lockLog("LAUNCH FAILED: \(err)")
                } else {
                    self.lockLog("launched pid=\(app?.processIdentifier ?? -1)")
                    // Did it survive, and did anything actually draw?
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let running = NSRunningApplication
                            .runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine")
                        self.lockLog("3s later: engine instances=\(running.count) "
                                   + "active=\(running.first?.isActive ?? false)")
                    }
                }
            }
        }
    }

    /// Re-read where we are and what the weather is doing.
    ///
    /// Opening the lid is exactly when both are most likely to be stale — you
    /// may have travelled, and hours may have passed. Location is only
    /// re-requested when the scene is actually following you; if you have
    /// pinned it to a city, moving the laptop should not move the sky.
    private var lastLocationRefresh = Date.distantPast
    private var previousScenePlace: Place?
    private func refreshEverything(reason: String) {
        weather.fetchNow()
        guard config.isShowingDetectedPlace else { return }
        // Core Location is cheap but not free, and wake notifications can
        // arrive in bursts.
        // Wake notifications arrive in bursts, so those are throttled hard;
        // the scheduled check is already paced and needs far less.
        let throttle: TimeInterval = (reason == "periodic") ? 60 : 300
        guard Date().timeIntervalSince(lastLocationRefresh) > throttle else { return }
        lastLocationRefresh = Date()
        NSLog("Elemental: refreshing location (%@)", reason)
        // Never requestOnce() here — that can raise the permission dialog, and
        // these paths run on every wake and unlock.
        location.refreshIfAuthorised()
    }

    private func resumeVisible() {
        for s in surfaces.values where s.isVisible || config.renderWhenOccluded { s.resume() }
    }

    private func updatePowerState() {
        let low = config.lowPowerOnBattery && ProcessInfo.processInfo.isLowPowerModeEnabled
        surfaces.values.forEach { $0.applyFrameRate(lowPower: low) }
    }

    /// Push the motion settings to the desktop renderers.
    ///
    /// Two bugs lived here. It set `playbackOnWake` and nothing else, so the
    /// replay's LENGTH and the world's SPEED never reached the desktop at all —
    /// they sat on their defaults, which is why a wake replay ran for the wrong
    /// duration and then snapped to live instead of easing into it. (The saver
    /// was fine; it assigns all three every frame, which is exactly why the two
    /// surfaces disagreed.)
    ///
    /// And it was only ever called from `applyConfig`, i.e. when a setting
    /// changed — never at launch. So a fresh start ran on defaults until you
    /// went and touched something, which is the "quit and reopen it to make it
    /// take" behaviour.
    private func applyPlaybackSetting() {
        for s in surfaces.values {
            s.renderer.playbackOnWake = config.playbackOnWake
            s.renderer.playbackMaxSeconds = config.playbackMaxSeconds
            s.renderer.motionSpeed = config.motionSpeed
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            // The real mark, drawn from the artwork's own path data and marked
            // as a template so the menu bar tints it — see Mark.swift.
            b.image = Mark.menuBarImage()
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Elemental", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Reload Scene", action: #selector(reload), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Elemental", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item
    }

    @objc func showSettings() {
        if settings == nil { settings = SettingsWindowController(delegate: self) }
        settings?.show(config: config)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reload() { rebuildSurfaces() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func fatal(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Elemental cannot start"
        a.informativeText = msg
        a.alertStyle = .critical
        a.runModal()
        NSApp.terminate(nil)
    }
}

// ---------------------------------------------------------------- entry point

let app = NSApplication.shared
let delegate = AppDelegate()

// The Elements pane cannot be verified by reading it — a detector that finds
// nothing and an editor that draws blank both compile. `--elements-selftest`
// renders both to PNGs and exits, before anything is put on screen and before
// any timer that could write config.json has a runloop to fire on.
if ElementsSelfTest.request != nil {
    ElementsSelfTest.run(delegate: delegate)
    exit(0)
}

// The density grip has the same problem: a control that steps but draws the
// same picture at every step compiles. `--density-selftest` drives its corner
// handle and its scroll offscreen and writes what the box shows.
if DensitySelfTest.outDir != nil {
    DensitySelfTest.run()
    exit(0)
}

// `--make-icons [projectRoot]` rebakes Icons/*.icns from the three Icon
// Composer bundles. An authoring step, not a build step: the .icns files are
// checked in, and build.sh only copies them. Same reasoning as the shader —
// nothing at launch may depend on a tool that is not installed.
if let i = CommandLine.arguments.firstIndex(of: "--make-icons") {
    let root = CommandLine.arguments.count > i + 1
        ? CommandLine.arguments[i + 1] : FileManager.default.currentDirectoryPath
    print("Elemental: baking icons from \(root)")
    exit(AppIconArt.makeAll(projectRoot: root) ? 0 : 1)
}

app.delegate = delegate
app.run()
