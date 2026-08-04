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

    private var asked = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // a city is plenty
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// Quietly get a fix, but ONLY if permission already exists.
    ///
    /// This is what the wake, unlock and periodic paths call. It must never
    /// show the permission dialog: those paths fire every time the lid opens,
    /// and an app that asks again on every wake is intolerable. If we are not
    /// authorised it simply does nothing and the scene keeps using the stored
    /// location.
    func refreshIfAuthorised() {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// Ask for permission and a single fix. Only from an explicit user action
    /// or genuine first run — never from a wake handler.
    func requestOnce() {
        asked = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            onUnavailable?("Location Services is turned off for Elemental. "
                         + "Enter a location manually in Settings, or enable it in "
                         + "System Settings › Privacy & Security › Location Services.")
        @unknown default:
            onUnavailable?("Location is unavailable.")
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard asked else { return }
        switch m.authorizationStatus {
        case .authorized, .authorizedAlways: m.requestLocation()
        case .denied, .restricted:
            onUnavailable?("Location access was denied. Enter a location manually in Settings.")
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        reverseGeocode(loc) { [weak self] place in
            DispatchQueue.main.async { self?.onResolve?(place) }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
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
