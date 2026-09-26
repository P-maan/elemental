//  Automation.swift — the ways in from outside the app.
//
//  Two doors onto the same settings, so the wall can be driven by anything that
//  can make a request: a shell script, Shortcuts, Raycast, a Stream Deck, cron.
//
//    * A LOCAL HTTP ENDPOINT on 127.0.0.1 (port 7417 by default). JSON in, JSON
//      out. Read the config, change any part of it, flip Low Power, reload.
//    * A URL SCHEME, elemental://, for the things that only need to fire and
//      forget — a Shortcut, a link in a note, `open elemental://lowpower/on`.
//
//  Both go through `AppDelegate.updateConfig`, the same path a Settings control
//  takes, so nothing here can reach a state the window could not.
//
//  ---- Why loopback, and why it is safe to leave on
//
//  The listener is bound to 127.0.0.1, so nothing off this Mac can reach it.
//  The remaining risk for a localhost API is a WEB PAGE in a browser on this
//  Mac making requests to it, and that is closed three ways:
//
//    * any request carrying an `Origin` header is refused — browsers send one
//      on every cross-origin request, and nothing else needs to;
//    * the `Host` header must name localhost/127.0.0.1, which defeats DNS
//      rebinding (a hostile domain re-pointed at 127.0.0.1 still says its own
//      name in Host);
//    * a request with a body must be `Content-Type: application/json`, which a
//      page cannot send cross-origin without a CORS preflight — and no CORS
//      header is ever answered.
//
//  Endpoints (all under /v1):
//
//    GET   /v1/status            what is running and what it is drawing
//    GET   /v1/config            the whole config, as saved
//    PATCH /v1/config            merge a JSON object into it (POST works too)
//    GET   /v1/schema            every documented key, its type and range
//    GET   /v1/grid              the row counts that fit each display
//    POST  /v1/lowpower          {"mode": "on" | "off" | "auto" | "toggle"}
//    POST  /v1/preview           {"weather": "rain" | "snow" | … | "off", "seconds": 90}
//    POST  /v1/reload            rebuild the scene
//    POST  /v1/settings          open the settings window
//
//  URL scheme:
//
//    elemental://set?gridRows=72&material=metal&reliefDepth=0.6
//    elemental://lowpower/on | off | auto | toggle
//    elemental://reload
//    elemental://settings

import AppKit
import Network

// MARK: - The keys worth documenting

enum AutomationSchema {

    struct Key {
        let name: String
        let type: String
        let detail: String
    }

    /// Enum fields accept their NAME as well as their number, so a request can
    /// say "metal" instead of having to know that metal is 1.
    static let enums: [String: [String: Int]] = [
        "material":    ["glass": 0, "metal": 1, "plastic": 2, "matte": 3],
        "headingMode": ["custom": 0, "dynamic": 1],
        "lowPower":    ["automatic": 0, "auto": 0, "on": 1, "off": 2],
        "shape":       ["square": 0, "dot": 1],
        "finish":      ["glass": 0, "flat": 1],
    ]

    static let keys: [Key] = [
        Key(name: "gridRows", type: "int 9…300",
            detail: "Rows of cells. Snapped to the nearest count that fits the display exactly — GET /v1/grid lists them. Alias: rows."),
        Key(name: "material", type: "glass | metal | plastic | matte", detail: "What the tiles are made of."),
        Key(name: "rounding", type: "0…1", detail: "0 is a square tile, 1 a round bead."),
        Key(name: "halftone", type: "0…1", detail: "How much a tile's SIZE carries its brightness."),
        Key(name: "roughness", type: "0…1", detail: "Polished to ground."),
        Key(name: "grout", type: "0…1", detail: "The painted line between tiles."),
        Key(name: "shadow", type: "0…1", detail: "Contact shadow between blocks."),
        Key(name: "depthMap", type: "0…1", detail: "Tint blocks by height."),
        Key(name: "reliefDepth", type: "0…1", detail: "How far the blocks stand out."),
        Key(name: "emphasis", type: "0…1", detail: "Relief follows features (1) or plain tone (0)."),
        Key(name: "lightIntensity", type: "0…1", detail: "Side-face shading."),
        Key(name: "splay", type: "0…1", detail: "Irregularity in the courses."),
        Key(name: "reliefRise", type: "0…1", detail: "How slowly blocks change height."),
        Key(name: "refraction", type: "0…1", detail: "Glass only: how far you see through a block."),
        Key(name: "dispersion", type: "0…1", detail: "Glass only: colour fringing."),
        Key(name: "frost", type: "0…1", detail: "Glass only: scatter."),
        Key(name: "shimmer", type: "0…1", detail: "A slow drift of light across the wall."),
        Key(name: "motionSpeed", type: "0.15…1.5", detail: "How fast the world runs. 1 is real time."),
        Key(name: "maxFPS", type: "10 | 15 | 30 | 60 | 120", detail: "Frame-rate ceiling."),
        Key(name: "headingMode", type: "custom | dynamic", detail: "Face a bearing, or follow the sun and moon."),
        Key(name: "facingAz", type: "0…359", detail: "The bearing, for custom heading."),
        Key(name: "scenePlaceName", type: "string", detail: "Which saved place the sky is drawn over."),
        Key(name: "liveWeather", type: "bool", detail: "Follow the real weather, or draw a clear calm day."),
        Key(name: "lowPower", type: "automatic | on | off", detail: "The Low Power preset."),
        Key(name: "lowPowerFPS", type: "int 4…30", detail: "Steady frame rate while Low Power is in force. Default 5 (about 1% CPU)."),
        Key(name: "lowPowerSmoothRain", type: "bool", detail: "Steady 20 fps in Low Power while rain or snow is falling. Default true."),
        Key(name: "syncLockScreen", type: "bool", detail: "Show the scene on the lock screen."),
        Key(name: "renderWhenOccluded", type: "bool", detail: "Keep drawing behind fullscreen apps."),
        Key(name: "playbackOnWake", type: "bool", detail: "Replay missed hours after sleep."),
        Key(name: "wetDock", type: "bool", detail: "Weather marks the Dock."),
        Key(name: "wetWidgets", type: "bool", detail: "Weather marks widgets."),
        Key(name: "paneWater", type: "bool", detail: "Rain on the glass."),
        Key(name: "lock", type: "object",
            detail: "Lock-screen style: mirrorsDesktop, material, rounding, halftone, gridRows, headingMode, facingAz."),
        Key(name: "saver", type: "object", detail: "Screen-saver style, same fields as lock."),
    ]

    static var json: [[String: String]] {
        keys.map { ["key": $0.name, "type": $0.type, "detail": $0.detail] }
    }

    /// Replace enum names with their numbers, recursively into lock/saver, and
    /// accept `rows` as the obvious name for `gridRows`.
    static func normalise(_ patch: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in patch {
            let key = (k == "rows") ? "gridRows" : k
            if let map = enums[key], let s = v as? String, let n = map[s.lowercased()] {
                out[key] = n
            } else if key == "lock" || key == "saver", let d = v as? [String: Any] {
                out[key] = normalise(d)
            } else {
                out[key] = v
            }
        }
        return out
    }

    /// Merge `patch` into `config` through the lenient decoder, so a bad value
    /// for one key keeps that key's current value instead of failing the lot.
    /// Nested lock/saver objects merge field by field too. Returns the keys it
    /// did not recognise, so a typo is reported rather than silently eaten.
    static func merge(_ patch: [String: Any], into config: Config) -> (Config, [String]) {
        guard let data = try? JSONEncoder().encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (config, []) }
        var unknown: [String] = []
        for (k, v) in normalise(patch) {
            guard dict[k] != nil || keys.contains(where: { $0.name == k }) else {
                unknown.append(k)
                continue
            }
            if let sub = v as? [String: Any], var cur = dict[k] as? [String: Any] {
                for (sk, sv) in sub { cur[sk] = sv }
                dict[k] = cur
            } else {
                dict[k] = v
            }
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict),
              let c = try? JSONDecoder().decode(Config.self, from: merged)
        else { return (config, unknown) }
        return (c, unknown.sorted())
    }
}

// MARK: - The HTTP endpoint

final class AutomationServer {

    private weak var app: AppDelegate?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "elemental.automation")
    private(set) var port: Int = 0
    private(set) var lastError: String?
    private(set) var isReady = false

    /// Called on the main queue whenever the listener starts, stops or fails.
    var onStateChange: (() -> Void)?

    init(app: AppDelegate) { self.app = app }

    var isRunning: Bool { listener != nil && isReady }

    func start(port: Int) {
        if listener != nil, self.port == port { return }
        stop()
        self.port = port
        lastError = nil
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            lastError = "Port \(port) is not valid."
            onStateChange?()
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: nothing off this Mac can connect.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
        params.requiredInterfaceType = .loopback
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self, weak l] st in
                DispatchQueue.main.async {
                    guard let self, let l, self.listener === l else { return }
                    switch st {
                    case .ready:
                        self.isReady = true
                        NSLog("Elemental: automation endpoint on http://127.0.0.1:%d", port)
                    case .failed(let e):
                        self.isReady = false
                        self.lastError = "Could not listen on 127.0.0.1:\(port) — \(e.localizedDescription)"
                        l.cancel()
                        self.listener = nil
                        NSLog("Elemental: automation endpoint failed: %@", "\(e)")
                    default: break
                    }
                    self.onStateChange?()
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            lastError = "Could not listen on 127.0.0.1:\(port) — \(error.localizedDescription)"
        }
        onStateChange?()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isReady = false
        onStateChange?()
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    /// Read until the headers and the whole declared body are in, then answer.
    /// Capped at 256 KB — a config is a few kilobytes.
    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 262_144 { self.send(c, 413, ["error": "request too large"]); return }
            if let req = HTTPRequest(buf) {
                self.handle(req, on: c)
            } else if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func handle(_ r: HTTPRequest, on c: NWConnection) {
        // ---- the browser guards; see the header.
        if r.headers["origin"] != nil {
            send(c, 403, ["error": "requests from web pages are not accepted"]); return
        }
        let hostHeader = (r.headers["host"] ?? "").lowercased()
        let host = hostHeader.hasPrefix("[")
            ? String(hostHeader.prefix { $0 != "]" }) + "]"
            : String(hostHeader.split(separator: ":").first ?? "")
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else {
            send(c, 403, ["error": "Host must be 127.0.0.1 or localhost"]); return
        }
        if !r.body.isEmpty,
           !(r.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") {
            send(c, 415, ["error": "send the body as Content-Type: application/json"]); return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (code, body) = self.route(r)
            self.queue.async { self.send(c, code, body) }
        }
    }

    /// Runs on the main queue — everything it touches belongs to AppDelegate.
    private func route(_ r: HTTPRequest) -> (Int, Any) {
        guard let app else { return (503, ["error": "not ready"]) }
        var path = r.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }

        switch (r.method, path) {
        case ("GET", "/"), ("GET", "/v1"):
            return (200, ["name": "Elemental", "api": 1,
                          "endpoints": ["GET /v1/status", "GET /v1/config", "PATCH /v1/config",
                                        "GET /v1/schema", "GET /v1/grid", "POST /v1/lowpower",
                                        "POST /v1/preview",
                                        "POST /v1/reload", "POST /v1/settings"]])

        case ("GET", "/v1/status"):
            return (200, Self.status(app))

        case ("GET", "/v1/config"):
            return (200, Self.configJSON(app.currentConfig))

        case ("PATCH", "/v1/config"), ("POST", "/v1/config"), ("PUT", "/v1/config"):
            guard let obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else {
                return (400, ["error": "body must be a JSON object, e.g. {\"gridRows\": 72}"])
            }
            let (merged, unknown) = AutomationSchema.merge(obj, into: app.currentConfig)
            app.updateConfig { $0 = merged }
            var out: [String: Any] = ["ok": true, "config": Self.configJSON(app.currentConfig)]
            if !unknown.isEmpty { out["ignored"] = unknown }
            return (200, out)

        case ("GET", "/v1/schema"):
            return (200, ["keys": AutomationSchema.json, "enums": AutomationSchema.enums])

        case ("GET", "/v1/grid"):
            return (200, ["displays": Self.grids(app.currentConfig)])

        case ("POST", "/v1/lowpower"):
            let obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
            let mode = ((obj?["mode"] as? String) ?? r.query["mode"] ?? "toggle").lowercased()
            guard Self.setLowPower(mode, app) else {
                return (400, ["error": "mode must be on, off, auto or toggle"])
            }
            return (200, ["ok": true, "lowPower": app.currentConfig.lowPower.title.lowercased(),
                          "active": app.isLowPowerActive])

        case ("POST", "/v1/preview"):
            let obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
            let name = ((obj?["weather"] as? String) ?? r.query["weather"] ?? "").lowercased()
            if name == "off" || name == "none" || name == "live" {
                app.endPreview()
                return (200, ["ok": true, "preview": NSNull()])
            }
            guard let p = WeatherPreview(rawValue: name) else {
                return (400, ["error": "weather must be one of "
                              + WeatherPreview.allCases.map(\.rawValue).joined(separator: ", ")
                              + ", or off"])
            }
            let secs = max(5, min(600, (obj?["seconds"] as? Double) ?? 90))
            app.startPreview(p, seconds: secs)
            return (200, ["ok": true, "preview": p.rawValue, "seconds": secs])

        case ("POST", "/v1/reload"):
            app.reloadScene()
            return (200, ["ok": true])

        case ("POST", "/v1/settings"):
            app.showSettings()
            return (200, ["ok": true])

        default:
            return (404, ["error": "no such endpoint: \(r.method) \(r.path) — GET /v1 lists them"])
        }
    }

    // MARK: Shared with the URL scheme

    @discardableResult
    static func setLowPower(_ mode: String, _ app: AppDelegate) -> Bool {
        switch mode {
        case "on":                app.updateConfig { $0.lowPower = .on }
        case "off":               app.updateConfig { $0.lowPower = .off }
        case "auto", "automatic": app.updateConfig { $0.lowPower = .automatic }
        case "toggle":            app.toggleLowPower()
        default: return false
        }
        return true
    }

    static func configJSON(_ c: Config) -> Any {
        guard let d = try? JSONEncoder().encode(c),
              let o = try? JSONSerialization.jsonObject(with: d) else { return [String: Any]() }
        return o
    }

    static func status(_ app: AppDelegate) -> [String: Any] {
        let c = app.currentConfig
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return ["version": v,
                "preRelease": Config.isPreRelease,
                "lowPower": c.lowPower.title.lowercased(),
                "lowPowerActive": app.isLowPowerActive,
                "place": c.scenePlace.name,
                "liveWeather": c.liveWeather,
                "grid": grids(c),
                "surfaces": app.surfaceStats]
    }

    static func grids(_ c: Config) -> [[String: Any]] {
        NSScreen.screens.map { s in
            let w = Float(s.frame.width * s.backingScaleFactor)
            let h = Float(s.frame.height * s.backingScaleFactor)
            let g = SceneSimulation.gridGeometry(pixelWidth: w, pixelHeight: h, gridRows: c.gridRows)
            return ["display": s.localizedName,
                    "pixels": [Int(w), Int(h)],
                    "requestedRows": c.gridRows,
                    "rows": g.rows, "cols": g.cols,
                    "cellPixels": (Double(g.pitch) * 100).rounded() / 100,
                    "fittingRows": SceneSimulation.fittingRows(pixelWidth: w, pixelHeight: h)]
        }
    }

    // MARK: Responses

    private func send(_ c: NWConnection, _ code: Int, _ body: Any) {
        var json = (try? JSONSerialization.data(withJSONObject: body,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        json.append(0x0A)
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      413: "Payload Too Large", 415: "Unsupported Media Type",
                      503: "Service Unavailable"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(reason)\r\n"
                 + "Content-Type: application/json; charset=utf-8\r\n"
                 + "Content-Length: \(json.count)\r\n"
                 + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(json)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Just enough HTTP/1.1 to read one request: method, path, headers, body.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// nil until the whole request — headers and Content-Length bytes of body —
    /// is in the buffer.
    init?(_ buf: Data) {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            h[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = max(0, Int(h["content-length"] ?? "0") ?? 0)
        let bodyStart = end.upperBound
        guard buf.endIndex - bodyStart >= len else { return nil }
        method = String(first[0]).uppercased()
        let comps = URLComponents(string: String(first[1]))
        path = comps?.path ?? String(first[1])
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        query = q
        headers = h
        body = buf.subdata(in: bodyStart..<(bodyStart + len))
    }
}

// MARK: - The URL scheme

enum AutomationURL {

    /// elemental://set?k=v…, elemental://lowpower/<mode>, elemental://reload,
    /// elemental://settings. Values in `set` are parsed as JSON where they can
    /// be (numbers, true/false, objects) and taken as strings otherwise.
    static func handle(_ url: URL, app: AppDelegate) {
        guard let sc = url.scheme?.lowercased(), sc == "elemental" || sc == "elemental-pre" else { return }
        let host = (url.host ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        NSLog("Elemental: URL %@", url.absoluteString)
        switch host {
        case "set", "config":
            var patch: [String: Any] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                let raw = item.value ?? "true"
                if let d = raw.data(using: .utf8),
                   let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
                    patch[item.name] = v
                } else {
                    patch[item.name] = raw
                }
            }
            let (merged, _) = AutomationSchema.merge(patch, into: app.currentConfig)
            app.updateConfig { $0 = merged }
        case "lowpower":
            AutomationServer.setLowPower(parts.first?.lowercased() ?? "toggle", app)
        case "preview":
            let name = parts.first?.lowercased() ?? "rain"
            if let p = WeatherPreview(rawValue: name) { app.startPreview(p) } else { app.endPreview() }
        case "reload":
            app.reloadScene()
        case "settings", "":
            app.showSettings()
        default:
            break
        }
    }
}

// MARK: - Weather preview
//
// A way to SEE weather that is not happening. The engine only draws what the
// sky is doing, so on a dry day there is no way to find out what rain does to
// the dock and the widgets short of waiting for some — which is also how every
// bug in that code went unnoticed. A preview swaps the live reading for a
// preset for a while and then hands the real sky back. Nothing is saved.

enum WeatherPreview: String, CaseIterable {
    case drizzle, rain, downpour, storm, snow, fog

    var title: String {
        switch self {
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .downpour: "Downpour"
        case .storm: "Storm"
        case .snow: "Snow"
        case .fog: "Fog"
        }
    }

    var symbol: String {
        switch self {
        case .drizzle: "cloud.drizzle"
        case .rain: "cloud.rain"
        case .downpour: "cloud.heavyrain"
        case .storm: "cloud.bolt.rain"
        case .snow: "cloud.snow"
        case .fog: "cloud.fog"
        }
    }

    /// Readings a real station could report for this weather — measurements,
    /// not labels, because the engine keys off measurements.
    /// Built from a clean reading, NOT on top of the live one: the live one
    /// carries radar, nowcast and satellite evidence for the real sky, and the
    /// engine trusts radar over the model — so a preview of rain over a dry
    /// radar picture came out as 6% drizzle with whole columns left dry.
    /// `base` contributes only where the sky is.
    func state(base: WeatherState) -> WeatherState {
        var w = WeatherState()
        w.uv = min(base.uv, 2)
        w.cover = 100; w.cloudLow = 95; w.cloudMid = 40; w.cloudHigh = 0
        w.humidity = 92; w.visibility = 8000; w.snow = 0; w.rain = 0
        w.showers = 0; w.cape = 0; w.windDir = 250
        switch self {
        case .drizzle:
            w.code = 53; w.rain = 0.4; w.temperature = 12; w.wind = 8
        case .rain:
            w.code = 63; w.rain = 3.5; w.temperature = 13; w.wind = 12
        case .downpour:
            w.code = 65; w.rain = 11; w.temperature = 16; w.wind = 18; w.visibility = 3000
        case .storm:
            w.code = 95; w.rain = 9; w.showers = 9; w.cape = 1800; w.liftedIndex = -5
            w.temperature = 22; w.wind = 28; w.gusts = 55; w.visibility = 4000
        case .snow:
            w.code = 73; w.snow = 1.6; w.temperature = -3; w.wind = 9; w.humidity = 88
            w.freezingLevel = 0; w.visibility = 2500
        case .fog:
            w.code = 45; w.visibility = 150; w.humidity = 100; w.temperature = 9
            w.wind = 2; w.cloudMid = 0
        }
        w.precipitation = w.rain + w.snow * 0.7
        w.gusts = max(w.gusts, w.wind)
        w.kind = SceneKind.from(code: w.code)
        let t = Double(w.temperature), rh = max(1.0, Double(w.humidity))
        let g = (17.27 * t) / (237.3 + t) + log(rh / 100)
        w.dewPoint = Float((237.3 * g) / (17.27 - g))
        return w
    }
}
