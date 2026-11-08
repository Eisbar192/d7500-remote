// Namen und Anzeige der Kamera-Einstellungen (gleich wie eigenschaften.py im Mac-Programm).

import Foundation

struct EigenschaftsInfo {
    let name: String
    let gruppe: String
    let ordnung: Int
}

enum Eigenschaften {
    static let bekannt: [UInt16: EigenschaftsInfo] = [
        0x500E: .init(name: "Aufnahmeprogramm", gruppe: "Belichtung", ordnung: 1),
        0x500D: .init(name: "Belichtungszeit", gruppe: "Belichtung", ordnung: 2),
        0x5007: .init(name: "Blende", gruppe: "Belichtung", ordnung: 3),
        0x500F: .init(name: "ISO", gruppe: "Belichtung", ordnung: 4),
        0x5010: .init(name: "Belichtungskorrektur", gruppe: "Belichtung", ordnung: 5),
        0x500B: .init(name: "Belichtungsmessung", gruppe: "Belichtung", ordnung: 6),
        0x5004: .init(name: "Bildqualität", gruppe: "Bild", ordnung: 10),
        0x5003: .init(name: "Bildgrösse", gruppe: "Bild", ordnung: 11),
        0x5005: .init(name: "Weissabgleich", gruppe: "Bild", ordnung: 12),
        0x500A: .init(name: "Fokusmodus", gruppe: "Fokus", ordnung: 20),
        0x501C: .init(name: "AF-Messfeldsteuerung", gruppe: "Fokus", ordnung: 21),
        0x5008: .init(name: "Brennweite", gruppe: "Fokus", ordnung: 22),
        0x5013: .init(name: "Aufnahmebetriebsart", gruppe: "Aufnahme", ordnung: 30),
        0x5018: .init(name: "Bilder pro Serie", gruppe: "Aufnahme", ordnung: 31),
        0x500C: .init(name: "Blitzmodus", gruppe: "Aufnahme", ordnung: 32),
        0x501E: .init(name: "Fotograf", gruppe: "Urheber", ordnung: 40),
        0x501F: .init(name: "Copyright", gruppe: "Urheber", ordnung: 41),
        0x5011: .init(name: "Datum/Uhrzeit", gruppe: "Kamera", ordnung: 50),
        0x5001: .init(name: "Akku", gruppe: "Kamera", ordnung: 51),
    ]

    static let gruppen = ["Belichtung", "Bild", "Fokus", "Aufnahme", "Urheber", "Kamera"]

    static let listen: [UInt16: [Int64: String]] = [
        0x500E: [1: "M – Manuell", 2: "P – Programmautomatik", 3: "A – Zeitautomatik", 4: "S – Blendenautomatik",
                 0x8010: "AUTO", 0x8011: "Porträt", 0x8012: "Landschaft", 0x8013: "Nahaufnahme", 0x8014: "Sport",
                 0x8015: "Nachtporträt", 0x8016: "Blitz aus", 0x8017: "Kinder", 0x8018: "SCENE", 0x8019: "EFFECTS",
                 0x8050: "U1", 0x8051: "U2"],
        0x5005: [1: "Manuell", 2: "Automatik", 4: "Tageslicht", 5: "Leuchtstofflampe", 6: "Kunstlicht", 7: "Blitz",
                 0x8010: "Bewölkt", 0x8011: "Schatten", 0x8012: "Farbtemperatur (K)", 0x8013: "Eigener Messwert",
                 0x8016: "Natürliches Licht auto"],
        0x500A: [1: "MF – Manuell", 2: "Autofokus", 0x8010: "AF-S – Einzel", 0x8011: "AF-C – Kontinuierlich",
                 0x8012: "AF-A – Automatisch", 0x8013: "AF-F – Permanent"],
        0x500B: [2: "Mittenbetont", 3: "Matrix", 4: "Spot", 0x8010: "Lichterbetont"],
        0x500C: [0: "Aus", 1: "Auto", 2: "Aus", 3: "Aufhellblitz", 4: "Auto + Rote Augen", 5: "Rote-Augen-Korrektur",
                 0x8010: "Langzeitsync", 0x8011: "2. Verschlussvorhang", 0x8012: "Rote Augen + Langzeitsync",
                 0x8013: "Langzeitsync 2. Vorhang"],
        0x5013: [1: "S – Einzelbild", 2: "CH – Serie schnell", 0x8010: "CL – Serie langsam", 0x8011: "Selbstauslöser",
                 0x8012: "Spiegelvorauslösung", 0x8013: "Fernauslöser", 0x8016: "Q – Leise"],
        0x501C: [1: "Mittelpunkt", 2: "Mehrfeld", 0x8010: "Einzelfeld", 0x8011: "Dynamisch", 0x8012: "3D-Tracking",
                 0x8013: "Automatisch", 0x8014: "Messfeldgruppe"],
        0x5004: [0: "JPEG Basic", 1: "JPEG Normal", 2: "JPEG Fine", 3: "JPEG Fine★", 4: "NEF (RAW)",
                 5: "NEF + JPEG Basic", 6: "NEF + JPEG Normal", 7: "NEF + JPEG Fine", 8: "JPEG Basic★",
                 9: "JPEG Normal★", 10: "NEF + JPEG Basic★", 11: "NEF + JPEG Normal★", 12: "NEF + JPEG Fine★"],
    ]

    static func zahlText(_ x: Double, stellen: Int = 1) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.decimalSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = stellen
        return f.string(from: NSNumber(value: x)) ?? "\(x)"
    }

    static func zeitText(_ v0: Int64) -> String {
        var v = Double(UInt32(truncatingIfNeeded: v0))
        let roh = UInt32(truncatingIfNeeded: v0)
        if roh == 0xFFFF_FFFF { return "Bulb" }
        if roh == 0xFFFF_FFFD || roh == 0xFFFF_FFFE { return "Time" }
        if roh > 3_000_000 && roh & 0xFFFF != 0 {
            v = Double(roh >> 16) * 10000 / Double(roh & 0xFFFF)
        }
        if v <= 0 { return "\(v0)" }
        let sek = v / 10000
        if sek >= 0.3 { return zahlText(sek) + "\"" }
        return "1/\(Int((1 / sek).rounded()))"
    }

    static func text(_ code: UInt16, _ wert: PTPWert) -> String {
        switch wert {
        case .text(let t):
            if code == 0x5003 { return t.replacingOccurrences(of: "x", with: " × ") }
            if code == 0x5011, t.count >= 15 {
                let z = Array(t)
                return "\(String(z[6...7])).\(String(z[4...5])).\(String(z[0...3])) \(String(z[9...10])):\(String(z[11...12]))"
            }
            return t.isEmpty ? "–" : t
        case .zahl(let v):
            switch code {
            case 0x500D: return zeitText(v)
            case 0x5007: return "f/" + zahlText(Double(v) / 100)
            case 0x5008: return zahlText(Double(v) / 100) + " mm"
            case 0x5010:
                let ev = Double(v) / 1000
                return ev == 0 ? "±0" : (ev > 0 ? "+" : "") + zahlText(ev) + " EV"
            case 0x500F: return "ISO \(v)"
            case 0x5001: return "\(v) %"
            default:
                if let l = listen[code] { return l[v] ?? String(format: "Wert 0x%llX", v) }
                return "\(v)"
            }
        }
    }
}

/// Eine Einstellung, aufbereitet fuer die Anzeige.
struct Einstellung: Identifiable {
    let code: UInt16
    var id: UInt16 { code }
    let name: String
    let gruppe: String
    let ordnung: Int
    let typ: UInt16
    let schreibbar: Bool
    let wert: PTPWert
    let optionen: [PTPWert]?

    var text: String { Eigenschaften.text(code, wert) }

    init(_ b: EigenschaftsBeschreibung) {
        code = b.code
        let info = Eigenschaften.bekannt[b.code] ?? .init(name: String(format: "Einstellung 0x%04X", b.code), gruppe: "Weitere", ordnung: 99)
        name = info.name
        gruppe = info.gruppe
        ordnung = info.ordnung
        typ = b.typ
        schreibbar = b.schreibbar
        wert = b.wert
        optionen = b.optionen
    }
}
