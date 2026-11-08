// GPS wie bei SnapBridge: Das iPhone zeichnet die Route auf, Fotos bekommen beim Speichern ihren Ort.

import Foundation
import CoreLocation

struct Punkt: Codable {
    let zeit: Date
    let lat: Double
    let lon: Double
    let hoehe: Double?
}

@MainActor
final class Routenaufzeichnung: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var aktiv = false
    @Published private(set) var anzahl = 0
    @Published private(set) var letzterOrt: CLLocation?
    @Published private(set) var berechtigung: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var punkte: [Punkt] = []
    private let datei: URL = {
        let ordner = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner.appendingPathComponent("route.json")
    }()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.activityType = .other
        berechtigung = manager.authorizationStatus
        if let d = try? Data(contentsOf: datei), let p = try? JSONDecoder().decode([Punkt].self, from: d) {
            punkte = p
            anzahl = p.count
        }
        aktiv = UserDefaults.standard.bool(forKey: "route.aktiv")
        if aktiv { starten() }
    }

    func starten() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        aktiv = true
        UserDefaults.standard.set(true, forKey: "route.aktiv")
    }

    func stoppen() {
        manager.stopUpdatingLocation()
        aktiv = false
        UserDefaults.standard.set(false, forKey: "route.aktiv")
        speichern()
    }

    func loeschen() {
        punkte.removeAll()
        anzahl = 0
        speichern()
    }

    private func speichern() {
        if let d = try? JSONEncoder().encode(punkte) { try? d.write(to: datei, options: .atomic) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.berechtigung = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let neue = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 100 }
        Task { @MainActor in
            for l in neue {
                self.punkte.append(Punkt(zeit: l.timestamp, lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                         hoehe: l.verticalAccuracy >= 0 ? l.altitude : nil))
                self.letzterOrt = l
            }
            self.anzahl = self.punkte.count
            if self.punkte.count % 20 == 0 { self.speichern() }
        }
    }

    /// Ort zum Zeitpunkt der Aufnahme (zwischen zwei Punkten interpoliert).
    func ort(fuer zeit: Date, toleranz: TimeInterval = 120, maxLuecke: TimeInterval = 1800) -> CLLocation? {
        guard !punkte.isEmpty else { return nil }
        let i = punkte.firstIndex { $0.zeit >= zeit } ?? punkte.count
        func loc(_ p: Punkt) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), altitude: p.hoehe ?? 0,
                       horizontalAccuracy: 10, verticalAccuracy: p.hoehe == nil ? -1 : 10, timestamp: zeit)
        }
        if i == 0 { return punkte[0].zeit.timeIntervalSince(zeit) <= toleranz ? loc(punkte[0]) : nil }
        if i == punkte.count { return zeit.timeIntervalSince(punkte[i - 1].zeit) <= toleranz ? loc(punkte[i - 1]) : nil }
        let a = punkte[i - 1], b = punkte[i]
        let luecke = b.zeit.timeIntervalSince(a.zeit)
        if luecke > maxLuecke {
            if zeit.timeIntervalSince(a.zeit) <= toleranz { return loc(a) }
            if b.zeit.timeIntervalSince(zeit) <= toleranz { return loc(b) }
            return nil
        }
        let f = luecke > 0 ? zeit.timeIntervalSince(a.zeit) / luecke : 0
        var hoehe: Double? = nil
        if let ha = a.hoehe, let hb = b.hoehe { hoehe = ha + (hb - ha) * f }
        return loc(Punkt(zeit: zeit, lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f, hoehe: hoehe))
    }

    /// Route als GPX-Datei (fuer die Mac-App oder andere Programme).
    func gpxDatei() -> URL? {
        guard !punkte.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="D7500 Remote" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>D7500 Route</name><trkseg>

        """
        for p in punkte {
            gpx += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">"
            if let h = p.hoehe { gpx += "<ele>\(String(format: "%.1f", h))</ele>" }
            gpx += "<time>\(iso.string(from: p.zeit))</time></trkpt>\n"
        }
        gpx += "</trkseg></trk></gpx>\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("D7500-Route_\(f.string(from: Date())).gpx")
        try? gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
