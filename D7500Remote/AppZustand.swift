// Zentrale Logik der App: Verbindung, Dateiliste, Downloads in die Fotos-App, Fernsteuerung.

import Foundation
import SwiftUI
import UIKit
import Photos
import CoreLocation

enum Format: String, CaseIterable, Identifiable {
    case beide, jpg, nef
    var id: String { rawValue }
    var titel: String {
        switch self {
        case .beide: return "RAW + JPG"
        case .jpg: return "nur JPG"
        case .nef: return "nur RAW"
        }
    }
    func passt(_ typ: String) -> Bool {
        switch self {
        case .beide: return typ == "JPG" || typ == "NEF" || typ == "MOV"
        case .jpg: return typ == "JPG" || typ == "MOV"
        case .nef: return typ == "NEF"
        }
    }
}

struct DownloadStand {
    var name: String
    var geladen: Int
    var groesse: Int
    var start: Date
    var rest: Int
}

@MainActor
final class AppZustand: ObservableObject {
    // Verbindung
    @Published private(set) var verbunden = false
    @Published private(set) var meldung = "Suche Kamera …"
    @Published private(set) var modell = ""
    @Published private(set) var akku: Int?
    @Published private(set) var kartenFrei: Int64?

    // Dateien
    @Published private(set) var dateien: [DateiInfo] = []
    @Published private(set) var gespeichert: Set<String> = []          // Dateinamen, die schon in Fotos sind
    @Published private(set) var download: DownloadStand?
    @Published private(set) var warteschlange: [UInt32] = []
    @Published var fehler: String?

    // Einstellungen der App
    @AppStorage("auto") var auto = false
    @AppStorage("format") var formatRoh = Format.beide.rawValue
    var format: Format { Format(rawValue: formatRoh) ?? .beide }

    // Fernsteuerung
    @Published private(set) var einstellungen: [Einstellung] = []
    @Published private(set) var liveAn = false
    @Published private(set) var liveBild: UIImage?

    let kamera = PTPKamera()
    let route = Routenaufzeichnung()
    private var vorschauCache = NSCache<NSNumber, UIImage>()
    private var schleifenTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var unfertig: [UInt32: Int] = [:]

    init() {
        gespeichert = Set(UserDefaults.standard.stringArray(forKey: "gespeichert") ?? [])
    }

    // MARK: Hintergrund-Schleife

    func starten() {
        guard schleifenTask == nil else { return }
        schleifenTask = Task { await schleife() }
    }

    func anhalten() {
        schleifenTask?.cancel()
        schleifenTask = nil
        liveStoppen()
        kamera.trennen()
        verbunden = false
        meldung = "Pausiert"
    }

    private func schleife() async {
        var letzterCheck = Date.distantPast
        var letzterAkku = Date.distantPast
        while !Task.isCancelled {
            if !kamera.verbunden {
                verbunden = false
                await verbinden()
                continue
            }
            do {
                if let h = warteschlange.first, !liveAn {
                    warteschlange.removeFirst()
                    try await laden(h)
                    continue
                }
                if Date().timeIntervalSince(letzterAkku) > 20 {
                    letzterAkku = Date()
                    akku = await kamera.akku()
                }
                if Date().timeIntervalSince(letzterCheck) > 4 {
                    letzterCheck = Date()
                    try await neuePruefen()
                }
            } catch {
                if !kamera.verbunden {
                    verbunden = false
                    meldung = "Verbindung verloren"
                } else {
                    fehler = error.localizedDescription
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func verbinden() async {
        meldung = "Suche Kamera …"
        do {
            try await kamera.verbinden()
            modell = kamera.modell
            akku = await kamera.akku()
            kartenFrei = await kamera.speicherFrei()?.frei
            meldung = "Verbunden"
            verbunden = true
            dateien = []
            try await listeLaden()
        } catch {
            kamera.trennen()
            verbunden = false
            meldung = "Keine Kamera gefunden"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func listeLaden() async throws {
        let hs = try await kamera.handles()
        var neu: [DateiInfo] = []
        for (i, h) in hs.enumerated() {
            let info = try await kamera.objektInfo(h)
            if info.format == PTP.ordnerFormat || info.name.isEmpty { continue }
            neu.append(info)
            if i % 25 == 0 { dateien = sortiert(neu) }
        }
        dateien = sortiert(neu)
    }

    private func sortiert(_ l: [DateiInfo]) -> [DateiInfo] {
        l.sorted { ($0.datumText, $0.name) > ($1.datumText, $1.name) }
    }

    private func neuePruefen() async throws {
        let hs = try await kamera.handles()
        let bekannt = Set(dateien.map(\.handle))
        let vorhanden = Set(hs)
        dateien.removeAll { !vorhanden.contains($0.handle) }
        for h in hs where !bekannt.contains(h) {
            let info = try await kamera.objektInfo(h)
            if info.format == PTP.ordnerFormat || info.name.isEmpty { continue }
            if info.datumText.isEmpty || info.groesse == 0 {          // Kamera schreibt noch
                unfertig[h, default: 0] += 1
                if unfertig[h]! < 3 || info.groesse == 0 { continue }
            }
            dateien = sortiert(dateien + [info])
            if auto && format.passt(info.typ) && !gespeichert.contains(info.name) {
                warteschlange.append(h)
            }
        }
    }

    // MARK: Vorschau

    func vorschau(_ h: UInt32, gross: Bool = false) async -> UIImage? {
        let key = NSNumber(value: gross ? Int64(h) | (1 << 40) : Int64(h))
        if let b = vorschauCache.object(forKey: key) { return b }
        guard verbunden, let d = try? await kamera.vorschau(h, gross: gross), let bild = UIImage(data: d) else { return nil }
        vorschauCache.setObject(bild, forKey: key)
        return bild
    }

    // MARK: Laden in die Fotos-App

    func einreihen(_ handles: [UInt32]) {
        for h in handles where !warteschlange.contains(h) {
            if let d = dateien.first(where: { $0.handle == h }), !gespeichert.contains(d.name) { warteschlange.append(h) }
        }
    }

    func abbrechen() { warteschlange.removeAll() }

    private var wartendePaare: [String: URL] = [:]       // Stamm -> schon geladene Datei (fuer RAW+JPG-Paar)

    private func laden(_ h: UInt32) async throws {
        guard let info = dateien.first(where: { $0.handle == h }), !gespeichert.contains(info.name) else { return }
        let ziel = FileManager.default.temporaryDirectory.appendingPathComponent(info.name)
        try? FileManager.default.removeItem(at: ziel)
        download = DownloadStand(name: info.name, geladen: 0, groesse: info.groesse, start: Date(), rest: warteschlange.count)
        defer { download = nil }
        try await kamera.laden(info, nach: ziel) { [weak self] n in
            Task { @MainActor in self?.download?.geladen = n }
        }

        // RAW + JPG als ein Bild in Fotos speichern, wenn beide geladen werden
        let partner = dateien.first { $0.stamm == info.stamm && $0.handle != info.handle && ($0.typ == "JPG" || $0.typ == "NEF") }
        let partnerKommt = partner.map { p in warteschlange.contains(p.handle) && !gespeichert.contains(p.name) } ?? false
        if partnerKommt && info.typ != "MOV" {
            wartendePaare[info.stamm] = ziel
            return
        }
        var dateienFuerFotos = [ziel]
        if let anderes = wartendePaare.removeValue(forKey: info.stamm) { dateienFuerFotos.append(anderes) }
        try await inFotosSpeichern(dateienFuerFotos, datum: info.datum)
        var namen = [info.name]
        if dateienFuerFotos.count > 1, let p = partner { namen.append(p.name) }
        for n in namen { gespeichert.insert(n) }
        UserDefaults.standard.set(Array(gespeichert), forKey: "gespeichert")
        for url in dateienFuerFotos { try? FileManager.default.removeItem(at: url) }
    }

    private func inFotosSpeichern(_ urls: [URL], datum: Date?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PTPFehler.abgelehnt("Kein Zugriff auf die Fotos-App. Bitte in den iPhone-Einstellungen erlauben.")
        }
        let jpg = urls.first { ["JPG", "JPEG"].contains($0.pathExtension.uppercased()) }
        let raw = urls.first { $0.pathExtension.uppercased() == "NEF" }
        let video = urls.first { ["MOV", "MP4"].contains($0.pathExtension.uppercased()) }
        let ort = datum.flatMap { route.ort(fuer: $0) }
        try await PHPhotoLibrary.shared().performChanges {
            let anfrage = PHAssetCreationRequest.forAsset()
            if let v = video {
                anfrage.addResource(with: .video, fileURL: v, options: nil)
            } else if let j = jpg {
                anfrage.addResource(with: .photo, fileURL: j, options: nil)
                if let r = raw {
                    let opt = PHAssetResourceCreationOptions()
                    opt.uniformTypeIdentifier = "com.nikon.raw-image"
                    anfrage.addResource(with: .alternatePhoto, fileURL: r, options: opt)
                }
            } else if let r = raw {
                anfrage.addResource(with: .photo, fileURL: r, options: nil)
            }
            if let d = datum { anfrage.creationDate = d }
            if let o = ort { anfrage.location = o }
        }
    }

    // MARK: Fernsteuerung

    func einstellungenLaden() async {
        guard verbunden else { einstellungen = []; return }
        var neu: [Einstellung] = []
        for code in kamera.props.sorted() where Eigenschaften.bekannt[code] != nil {
            if let b = try? await kamera.eigenschaft(code) { neu.append(Einstellung(b)) }
        }
        einstellungen = neu.sorted { $0.ordnung < $1.ordnung }
    }

    func setzen(_ e: Einstellung, _ wert: PTPWert) async {
        do {
            try await kamera.setzen(e.code, typ: e.typ, wert: wert)
        } catch {
            fehler = error.localizedDescription
        }
        await einstellungenLaden()
    }

    func uhrzeitStellen() async {
        guard let e = einstellungen.first(where: { $0.code == 0x5011 }) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        await setzen(e, .text(f.string(from: Date())))
    }

    func fokussieren() async -> Bool {
        do { try await kamera.fokussieren(); return true } catch { fehler = error.localizedDescription; return false }
    }

    func ausloesen(mitAF: Bool) async -> Bool {
        do {
            try await kamera.ausloesen(mitAF: mitAF)
            return true
        } catch {
            fehler = error.localizedDescription
            return false
        }
    }

    func liveStarten() async {
        do {
            try await kamera.liveStarten()
            liveAn = true
            liveTask = Task {
                while !Task.isCancelled && liveAn {
                    if let d = try? await kamera.liveBild(), let b = UIImage(data: d) { liveBild = b }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
            }
        } catch {
            fehler = error.localizedDescription
        }
    }

    func liveStoppen() {
        liveAn = false
        liveTask?.cancel()
        liveTask = nil
        liveBild = nil
        Task { await kamera.liveStoppen() }
    }
}
