//  Location.swift — where the sky is drawn for.
//
//  Three routes, in order of preference:
//    1. Core Location, asked once on first run
//    2. manual latitude/longitude entry, if that is denied or unavailable
//    3. city search, for adding places by name
//
//  The scene never depends on any of them succeeding: with no location at all
//  it still renders, just for whatever place is configured.

import Foundation
import CoreLocation

final class LocationService: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    /// Called when a place is resolved, on the main queue.
    var onResolve: ((Place) -> Void)?
    /// Called when location is unavailable, so the UI can offer manual entry.
    var onUnavailable: ((String) -> Void)?
    /// Called when a quiet refresh could not run because there is no grant.
    ///
    /// This exists because the quiet path used to fail SILENTLY. `refreshIfAuthorised`
    /// returned on an unmatched status with no log and no callback, so an app
    /// that had lost its authorisation looked identical to an app that was
    /// refreshing normally and finding it had not moved. The whole of "the scene
    /// does not follow me when I travel" lived in that `default: break`.
    var onNeedsAuthorisation: ((CLAuthorizationStatus) -> Void)?

    private var asked = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // a city is plenty
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// Whether a fix can actually be requested right now.
    ///
    /// Tested by raw value rather than by case. On macOS `authorizedWhenInUse`
    /// is marked unavailable and `authorized` is a deprecated alias for
    /// `authorizedAlways` (both raw 3) — but the raw 4 that means when-in-use
    /// can still arrive across the XPC boundary, and a `switch` written in the
    /// obvious way sends it to `@unknown default` and calls it unauthorised.
    /// Anything at or above `authorizedAlways` is a grant.
    var isAuthorised: Bool { manager.authorizationStatus.rawValue >= 3 }

    /// The status in words, for the log. Inferring authorisation from behaviour
    /// is what made this bug take months; printing it makes it one line.
    static func statusName(_ s: CLAuthorizationStatus) -> String {
        switch s.rawValue {
        case 0: return "notDetermined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorizedAlways"
        case 4: return "authorizedWhenInUse"
        default: return "unknown(\(s.rawValue))"
        }
    }

    private func log(_ what: String) {
        NSLog("Elemental location: %@ [status=%@ servicesEnabled=%@]", what,
              Self.statusName(manager.authorizationStatus),
              CLLocationManager.locationServicesEnabled() ? "yes" : "no")
    }

    /// Quietly get a fix, but ONLY if permission already exists.
    ///
    /// This is what the wake, unlock and periodic paths call. It must never
    /// show the permission dialog: those paths fire every time the lid opens,
    /// and an app that asks again on every wake is intolerable.
    ///
    /// What it must ALSO never do is fail invisibly, which is what it did. When
    /// there is no grant the scene keeps using the stored location — that part
    /// was right — but somebody has to be told, or the stored location is
    /// simply the wrong city forever.
    func refreshIfAuthorised() {
        let st = manager.authorizationStatus
        guard isAuthorised else {
            log("quiet refresh skipped — not authorised")
            onNeedsAuthorisation?(st)
            return
        }
        log("quiet refresh — requesting a fix")
        manager.requestLocation()
    }

    /// Ask for permission and a single fix. Only from an explicit user action
    /// or genuine first run — never from a wake handler.
    func requestOnce() {
        asked = true
        let st = manager.authorizationStatus
        if st == .notDetermined {
            log("requesting authorisation")
            manager.requestWhenInUseAuthorization()
            return
        }
        if isAuthorised {
            log("already authorised — requesting a fix")
            manager.requestLocation()
            return
        }
        log("cannot request — authorisation refused")
        onUnavailable?("Location Services is turned off for Elemental. "
                     + "Enter a location manually in Settings, or enable it in "
                     + "System Settings › Privacy & Security › Location Services.")
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        log("authorisation changed")
        guard asked else { return }
        if isAuthorised { m.requestLocation(); return }
        switch m.authorizationStatus {
        case .denied, .restricted:
            onUnavailable?("Location access was denied. Enter a location manually in Settings.")
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        NSLog("Elemental location: fix %.4f, %.4f (±%.0fm) — reverse geocoding",
              loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy)
        reverseGeocode(loc) { [weak self] place in
            NSLog("Elemental location: resolved to %@ (%.4f, %.4f)",
                  place.name, place.latitude, place.longitude)
            DispatchQueue.main.async { self?.onResolve?(place) }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // Logged as well as reported. `onUnavailable` is only attached while the
        // Settings window happens to be open, so for the ordinary case — agent
        // running in the background for weeks — this was the error going
        // nowhere at all.
        log("FAILED: \(error.localizedDescription)")
        onUnavailable?("Could not determine location: \(error.localizedDescription)")
    }

    private func reverseGeocode(_ loc: CLLocation, done: @escaping (Place) -> Void) {
        geocoder.reverseGeocodeLocation(loc) { marks, _ in
            let name = marks?.first?.locality
                    ?? marks?.first?.administrativeArea
                    ?? "Current Location"
            done(Place(name: name,
                       latitude: loc.coordinate.latitude,
                       longitude: loc.coordinate.longitude,
                       timeZone: marks?.first?.timeZone?.identifier))
        }
    }

    // MARK: - Search

    /// Look a place up by name, for adding cities in Settings. Uses Apple's
    /// geocoder, so there is no API key and no third-party dependency.
    func search(_ query: String, done: @escaping ([Place]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { done([]); return }
        geocoder.geocodeAddressString(q) { marks, _ in
            let places: [Place] = (marks ?? []).compactMap { m in
                guard let c = m.location?.coordinate else { return nil }
                var parts: [String] = []
                if let l = m.locality { parts.append(l) }
                if let a = m.administrativeArea, a != m.locality { parts.append(a) }
                if let ctry = m.country, parts.count < 2 { parts.append(ctry) }
                let name = parts.isEmpty ? q : parts.joined(separator: ", ")
                return Place(name: name, latitude: c.latitude, longitude: c.longitude,
                             timeZone: m.timeZone?.identifier)
            }
            DispatchQueue.main.async { done(places) }
        }
    }
}

// MARK: - City search
//
// MKLocalSearchCompleter is what Apple's own apps use for as-you-type place
// suggestions, and it is the right tool here. CLGeocoder — which this file used
// first — is an address *resolver*, not a completer: it returns a single
// region-biased guess, so "Tok" came back as Muzaffarpur and "Amherst" as
// Bexhill-On-Sea. The completer returns a ranked list and handles partial words.
//
// It gives completions, not coordinates. Resolving one to a real location is a
// second step (MKLocalSearch), done only for the city actually chosen.

import MapKit

final class CitySearch: NSObject, MKLocalSearchCompleterDelegate {

    private let completer = MKLocalSearchCompleter()

    /// Fired on the main queue every time the suggestion list changes.
    var onResults: (([MKLocalSearchCompletion]) -> Void)?
    var onFailure: ((String) -> Void)?

    override init() {
        super.init()
        completer.delegate = self
        // Addresses, not points of interest: we want places, not restaurants.
        completer.resultTypes = .address
    }

    /// Update the query. Safe to call on every keystroke — the completer does
    /// its own coalescing, and an empty fragment simply clears the results.
    func update(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            completer.cancel()
            onResults?([])
            return
        }
        completer.queryFragment = q
    }

    func cancel() { completer.cancel() }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        onResults?(c.results)
    }

    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Throttling and transient network errors both land here; a stale
        // suggestion list is better than an error the user cannot act on.
        onFailure?(error.localizedDescription)
    }

    /// Turn a chosen suggestion into a real place. Only ever called for the one
    /// the user picked, so this stays well inside MapKit's rate limits.
    static func resolve(_ completion: MKLocalSearchCompletion,
                        done: @escaping (Place?) -> Void)
    {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        search.start { response, _ in
            guard let mark = response?.mapItems.first?.placemark else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let c = mark.coordinate
            // The completion's own title is already well formatted — "Amherst,
            // MA" — so prefer it over reassembling one from the placemark.
            let name = completion.title.isEmpty ? (mark.locality ?? "Unknown") : completion.title
            let place = Place(name: name,
                              latitude: c.latitude,
                              longitude: c.longitude,
                              timeZone: mark.timeZone?.identifier)
            DispatchQueue.main.async { done(place) }
        }
    }
}
