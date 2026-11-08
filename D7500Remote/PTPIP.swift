// PTP/IP-Verbindung zur Nikon D7500 (direktes WLAN der Kamera).
// Gleiche Logik wie im Mac-Programm (ptpip.py), hier mit Network.framework.

import Foundation
import Network

enum PTPFehler: LocalizedError {
    case getrennt
    case zeitueberschreitung
    case abgelehnt(String)
    case antwort(UInt16, String)
    case protokoll(String)

    var errorDescription: String? {
        switch self {
        case .getrennt: return "Verbindung zur Kamera getrennt"
        case .zeitueberschreitung: return "Die Kamera antwortet nicht"
        case .abgelehnt(let t): return t
        case .antwort(let code, let was): return "\(was): \(PTP.antwortText(code))"
        case .protokoll(let t): return t
        }
    }
}

enum PTP {
    static let ok: UInt16 = 0x2001
    static let beschaeftigt: UInt16 = 0x2019
    static let ordnerFormat: UInt16 = 0x3001
    static let jpegFormat: UInt16 = 0x3801

    static func antwortText(_ code: UInt16) -> String {
        switch code {
        case 0x2001: return "OK"
        case 0x2002: return "Allgemeiner Fehler"
        case 0x2005: return "Nicht unterstützt"
        case 0x2009: return "Ungültige Datei"
        case 0x200F: return "An der Kamera gesperrt"
        case 0x2014: return "Keine Speicherkarte"
        case 0x2018: return "Speicherkarte voll"
        case 0x2019: return "Kamera beschäftigt"
        case 0x201B, 0x201C: return "Ungültiger Wert"
        case 0xA002: return "Nicht scharfgestellt"
        case 0xA004: return "Kamera in falschem Zustand"
        case 0xA00B: return "Live-Bild nicht möglich"
        default: return String(format: "Code 0x%04X", code)
        }
    }
}

// MARK: - Daten-Hilfen

extension Data {
    mutating func u16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }

    func zahl<T: FixedWidthInteger>(_ typ: T.Type, bei pos: Int) -> T {
        var wert: T = 0
        let n = MemoryLayout<T>.size
        guard pos >= 0, pos + n <= count else { return 0 }
        for i in 0..<n { wert |= T(self[startIndex + pos + i]) << (8 * i) }
        return wert
    }
}

/// Liest PTP-Datensaetze (Zahlen, Strings, Arrays) der Reihe nach.
struct Leser {
    let d: Data
    var p = 0
    init(_ d: Data) { self.d = d }

    mutating func pruefe(_ n: Int) throws {
        if p + n > d.count { throw PTPFehler.protokoll("Datensatz zu kurz") }
    }
    mutating func u8() throws -> UInt8 { try pruefe(1); defer { p += 1 }; return d.zahl(UInt8.self, bei: p) }
    mutating func u16() throws -> UInt16 { try pruefe(2); defer { p += 2 }; return d.zahl(UInt16.self, bei: p) }
    mutating func u32() throws -> UInt32 { try pruefe(4); defer { p += 4 }; return d.zahl(UInt32.self, bei: p) }
    mutating func u64() throws -> UInt64 { try pruefe(8); defer { p += 8 }; return d.zahl(UInt64.self, bei: p) }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    mutating func text() throws -> String {
        let n = Int(try u8())
        if n == 0 { return "" }
        try pruefe(2 * n)
        let roh = d.subdata(in: (d.startIndex + p)..<(d.startIndex + p + 2 * n))
        p += 2 * n
        return (String(data: roh, encoding: .utf16LittleEndian) ?? "").replacingOccurrences(of: "\0", with: "")
    }
    mutating func liste16() throws -> [UInt16] { let n = Int(try u32()); return try (0..<n).map { _ in try u16() } }
    mutating func liste32() throws -> [UInt32] { let n = Int(try u32()); return try (0..<n).map { _ in try u32() } }
}

func ptpText(_ s: String) -> Data {
    if s.isEmpty { return Data([0]) }
    var d = Data([UInt8(s.utf16.count + 1)])
    for c in s.utf16 { d.u16(c) }
    d.u16(0)
    return d
}

// MARK: - TCP-Kanal

final class Kanal {
    private let verbindung: NWConnection
    private let warteschlange = DispatchQueue(label: "d7500.kanal")

    init(host: String, port: UInt16 = 15740) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 6
        verbindung = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func oeffnen(timeout: Double = 6) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var fertig = false
            func ende(_ fehler: Error?) {
                if fertig { return }
                fertig = true
                if let f = fehler { verbindung.cancel(); cont.resume(throwing: f) } else { cont.resume() }
            }
            verbindung.stateUpdateHandler = { zustand in
                switch zustand {
                case .ready: ende(nil)
                case .failed(let f): ende(f)
                case .waiting(let f): ende(f)
                case .cancelled: ende(PTPFehler.getrennt)
                default: break
                }
            }
            verbindung.start(queue: warteschlange)
            warteschlange.asyncAfter(deadline: .now() + timeout) { ende(PTPFehler.zeitueberschreitung) }
        }
    }

    func schliessen() { verbindung.cancel() }

    func senden(_ daten: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            verbindung.send(content: daten, completion: .contentProcessed { fehler in
                if let f = fehler { cont.resume(throwing: f) } else { cont.resume() }
            })
        }
    }

    func lesen(_ n: Int) async throws -> Data {
        var daten = Data()
        daten.reserveCapacity(n)
        while daten.count < n {
            let fehlt = n - daten.count
            let teil: Data = try await withCheckedThrowingContinuation { cont in
                verbindung.receive(minimumIncompleteLength: 1, maximumLength: fehlt) { d, _, _, fehler in
                    if let f = fehler { cont.resume(throwing: f); return }
                    if let d = d, !d.isEmpty { cont.resume(returning: d); return }
                    cont.resume(throwing: PTPFehler.getrennt)
                }
            }
            daten.append(teil)
        }
        return daten
    }

    func paketSenden(_ typ: UInt32, _ inhalt: Data = Data()) async throws {
        var d = Data()
        d.u32(UInt32(8 + inhalt.count))
        d.u32(typ)
        d.append(inhalt)
        try await senden(d)
    }

    func paketLesen() async throws -> (UInt32, Data) {
        let kopf = try await lesen(8)
        let laenge = Int(kopf.zahl(UInt32.self, bei: 0))
        let typ = kopf.zahl(UInt32.self, bei: 4)
        if laenge < 8 { throw PTPFehler.protokoll("Ungültige Paketlänge") }
        return (typ, try await lesen(laenge - 8))
    }
}

// MARK: - Sperre: immer nur ein Befehl gleichzeitig

actor Sperre {
    private var belegt = false
    private var wartende: [CheckedContinuation<Void, Never>] = []

    func nehmen() async {
        if !belegt { belegt = true; return }
        await withCheckedContinuation { wartende.append($0) }
    }

    func freigeben() {
        if wartende.isEmpty { belegt = false } else { wartende.removeFirst().resume() }
    }
}

// MARK: - Kamera

struct DateiInfo: Identifiable, Hashable {
    let handle: UInt32
    var id: UInt32 { handle }
    let format: UInt16
    let groesse: Int
    let breite: Int
    let hoehe: Int
    let name: String
    let datumText: String

    var typ: String {
        let e = (name as NSString).pathExtension.uppercased()
        switch e {
        case "JPG", "JPEG": return "JPG"
        case "NEF": return "NEF"
        case "MOV", "MP4": return "MOV"
        default: return e
        }
    }
    var stamm: String { (name as NSString).deletingPathExtension }

    /// Aufnahmezeit (Kamerazeit = Ortszeit des iPhones)
    var datum: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: String(datumText.prefix(15)))
    }
}

struct EigenschaftsBeschreibung {
    let code: UInt16
    let typ: UInt16
    let schreibbar: Bool
    let wert: PTPWert
    let optionen: [PTPWert]?
}

enum PTPWert: Hashable {
    case zahl(Int64)
    case text(String)

    var zahl: Int64? { if case .zahl(let z) = self { return z }; return nil }
    var text: String? { if case .text(let t) = self { return t }; return nil }
}

final class PTPKamera {
    let ip: String
    private var befehlsKanal: Kanal?
    private var ereignisKanal: Kanal?
    private var tid: UInt32 = 0
    private let sperre = Sperre()
    private(set) var verbunden = false
    private(set) var ops = Set<UInt16>()
    private(set) var props = Set<UInt16>()
    private(set) var modell = ""
    private(set) var firmware = ""

    init(ip: String = "192.168.1.1") { self.ip = ip }

    static var geraeteID: Data {
        let schluessel = "d7500.guid"
        let uuid: UUID
        if let s = UserDefaults.standard.string(forKey: schluessel), let u = UUID(uuidString: s) {
            uuid = u
        } else {
            uuid = UUID()
            UserDefaults.standard.set(uuid.uuidString, forKey: schluessel)
        }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    func verbinden() async throws {
        trennen()
        let cmd = Kanal(host: ip)
        try await cmd.oeffnen()
        var anfrage = PTPKamera.geraeteID
        for c in "D7500 Remote iPhone".utf16 { anfrage.u16(c) }
        anfrage.u16(0)
        anfrage.u32(0x0001_0000)
        try await cmd.paketSenden(1, anfrage)
        let (typ, daten) = try await cmd.paketLesen()
        if typ == 5 { cmd.schliessen(); throw PTPFehler.abgelehnt("Die Kamera hat abgelehnt. Ist noch SnapBridge verbunden?") }
        if typ != 2 { cmd.schliessen(); throw PTPFehler.protokoll("Unerwartete Antwort \(typ)") }
        let nummer = daten.zahl(UInt32.self, bei: 0)

        let evt = Kanal(host: ip)
        try await evt.oeffnen()
        var e = Data(); e.u32(nummer)
        try await evt.paketSenden(3, e)
        let (etyp, _) = try await evt.paketLesen()
        if etyp != 4 { cmd.schliessen(); evt.schliessen(); throw PTPFehler.protokoll("Ereigniskanal abgelehnt") }
        befehlsKanal = cmd
        ereignisKanal = evt
        verbunden = true
        Task.detached { [weak self] in await self?.ereignisseVerwerfen(evt) }

        let (c1, info) = try await befehl(0x1001)
        if c1 != PTP.ok { throw PTPFehler.antwort(c1, "Geräteinfo") }
        var r = Leser(info)
        _ = try r.u16(); _ = try r.u32(); _ = try r.u16(); _ = try r.text(); _ = try r.u16()
        ops = Set(try r.liste16()); _ = try r.liste16(); props = Set(try r.liste16())
        _ = try r.liste16(); _ = try r.liste16()
        _ = try r.text()
        modell = try r.text()
        firmware = try r.text()

        tid = 0
        let (c2, _) = try await befehl(0x1002, [1])
        if c2 != PTP.ok && c2 != 0x201E { throw PTPFehler.antwort(c2, "Sitzung") }
        if ops.contains(0x90CB) {
            let (c3, d3) = try await befehl(0x90CB)
            var l = Leser(d3)
            if c3 == PTP.ok, d3.count >= 4, let zusatz = try? l.liste16() {
                props.formUnion(zusatz)
            }
        }
    }

    private func ereignisseVerwerfen(_ k: Kanal) async {
        while true {
            do { _ = try await k.paketLesen() } catch { return }
        }
    }

    func trennen() {
        befehlsKanal?.schliessen()
        ereignisKanal?.schliessen()
        befehlsKanal = nil
        ereignisKanal = nil
        verbunden = false
    }

    /// Sendet einen PTP-Befehl. Mit `senden` werden Daten an die Kamera geschickt.
    func befehl(_ op: UInt16, _ params: [UInt32] = [], senden: Data? = nil) async throws -> (UInt16, Data) {
        await sperre.nehmen()
        defer { Task { await sperre.freigeben() } }
        guard let k = befehlsKanal else { throw PTPFehler.getrennt }
        let id = tid
        tid &+= 1
        var anfrage = Data()
        anfrage.u32(senden == nil ? 1 : 2)
        anfrage.u16(op)
        anfrage.u32(id)
        for p in params { anfrage.u32(p) }
        do {
            try await k.paketSenden(6, anfrage)
            if let s = senden {
                var start = Data(); start.u32(id); start.u64(UInt64(s.count))
                try await k.paketSenden(9, start)
                var ende = Data(); ende.u32(id); ende.append(s)
                try await k.paketSenden(12, ende)
            }
            var daten = Data()
            while true {
                let (typ, inhalt) = try await k.paketLesen()
                switch typ {
                case 10, 12: if inhalt.count > 4 { daten.append(inhalt.subdata(in: (inhalt.startIndex + 4)..<inhalt.endIndex)) }
                case 7: return (inhalt.zahl(UInt16.self, bei: 0), daten)
                case 11: throw PTPFehler.protokoll("Vorgang von der Kamera abgebrochen")
                default: continue
                }
            }
        } catch {
            verbunden = false
            throw error
        }
    }

    // MARK: Infos

    func akku() async -> Int? {
        guard let r = try? await befehl(0x1015, [0x5001]), r.0 == PTP.ok, r.1.count >= 1 else { return nil }
        return Int(r.1[r.1.startIndex])
    }

    func speicherFrei() async -> (frei: Int64, gesamt: Int64)? {
        guard let antwort = try? await befehl(0x1004), antwort.0 == PTP.ok else { return nil }
        var liste = Leser(antwort.1)
        guard let ids = try? liste.liste32() else { return nil }
        for sid in ids where sid & 0xFFFF != 0 {
            guard let a2 = try? await befehl(0x1005, [sid]), a2.0 == PTP.ok else { continue }
            var r = Leser(a2.1)
            guard (try? r.u16()) != nil, (try? r.u16()) != nil, (try? r.u16()) != nil,
                  let gesamt = try? r.u64(), let frei = try? r.u64() else { continue }
            return (Int64(frei), Int64(gesamt))
        }
        return nil
    }

    func handles() async throws -> [UInt32] {
        let (c, d) = try await befehl(0x1007, [0xFFFF_FFFF, 0, 0])
        if c != PTP.ok { throw PTPFehler.antwort(c, "Dateiliste") }
        var r = Leser(d)
        return try r.liste32()
    }

    func objektInfo(_ h: UInt32) async throws -> DateiInfo {
        let (c, d) = try await befehl(0x1008, [h])
        if c != PTP.ok { throw PTPFehler.antwort(c, "Dateiinfo") }
        var r = Leser(d)
        _ = try r.u32()
        let format = try r.u16()
        _ = try r.u16()
        let groesse = Int(try r.u32())
        _ = try r.u16(); _ = try r.u32(); _ = try r.u32(); _ = try r.u32()
        let breite = Int(try r.u32())
        let hoehe = Int(try r.u32())
        _ = try r.u32(); _ = try r.u32(); _ = try r.u16(); _ = try r.u32(); _ = try r.u32()
        let name = try r.text()
        let datum = try r.text()
        return DateiInfo(handle: h, format: format, groesse: groesse, breite: breite, hoehe: hoehe, name: name, datumText: datum)
    }

    func vorschau(_ h: UInt32, gross: Bool = false) async throws -> Data {
        if gross && ops.contains(0x90C4) {
            let (c, d) = try await befehl(0x90C4, [h])
            if c == PTP.ok && !d.isEmpty { return d }
        }
        let (c, d) = try await befehl(0x100A, [h])
        if c != PTP.ok { throw PTPFehler.antwort(c, "Vorschau") }
        return d
    }

    /// Laedt eine Datei in Stuecken in eine Datei auf dem iPhone.
    func laden(_ info: DateiInfo, nach ziel: URL, fortschritt: @escaping (Int) -> Void) async throws {
        FileManager.default.createFile(atPath: ziel.path, contents: nil)
        let datei = try FileHandle(forWritingTo: ziel)
        defer { try? datei.close() }
        var geladen = 0
        if ops.contains(0x101B) && info.groesse > 0 {
            while geladen < info.groesse {
                try Task.checkCancellation()
                let n = min(1 << 20, info.groesse - geladen)
                let (c, d) = try await befehl(0x101B, [info.handle, UInt32(geladen), UInt32(n)])
                if (c != PTP.ok || d.isEmpty) && geladen == 0 { break }      // stueckweise geht nicht
                if c != PTP.ok { throw PTPFehler.antwort(c, "Download") }
                if d.isEmpty { throw PTPFehler.protokoll("Keine Daten erhalten") }
                try datei.write(contentsOf: d)
                geladen += d.count
                fortschritt(geladen)
            }
            if geladen > 0 { return }
        }
        let (c, d) = try await befehl(0x1009, [info.handle])
        if c != PTP.ok { throw PTPFehler.antwort(c, "Download") }
        if d.isEmpty { throw PTPFehler.protokoll("Keine Daten erhalten") }
        try datei.truncate(atOffset: 0)
        try datei.write(contentsOf: d)
        fortschritt(d.count)
    }

    // MARK: Einstellungen

    private func wertLesen(_ r: inout Leser, _ typ: UInt16) throws -> PTPWert {
        switch typ {
        case 1: return .zahl(Int64(try r.i8()))
        case 2: return .zahl(Int64(try r.u8()))
        case 3: return .zahl(Int64(try r.i16()))
        case 4: return .zahl(Int64(try r.u16()))
        case 5: return .zahl(Int64(try r.i32()))
        case 6: return .zahl(Int64(try r.u32()))
        case 7: return .zahl(try r.i64())
        case 8: return .zahl(Int64(bitPattern: try r.u64()))
        case 0xFFFF: return .text(try r.text())
        default: throw PTPFehler.protokoll("Datentyp nicht unterstützt")
        }
    }

    func eigenschaft(_ code: UInt16) async throws -> EigenschaftsBeschreibung {
        let (c, d) = try await befehl(0x1014, [UInt32(code)])
        if c != PTP.ok { throw PTPFehler.antwort(c, "Einstellung") }
        var r = Leser(d)
        _ = try r.u16()
        let typ = try r.u16()
        let schreibbar = try r.u8() == 1
        _ = try wertLesen(&r, typ)
        let wert = try wertLesen(&r, typ)
        let form = try r.u8()
        var optionen: [PTPWert]?
        if form == 1 {
            let lo = try wertLesen(&r, typ), hi = try wertLesen(&r, typ), schritt = try wertLesen(&r, typ)
            if let a = lo.zahl, let b = hi.zahl, let s = schritt.zahl, s > 0, (b - a) / s <= 300 {
                optionen = stride(from: a, through: b, by: Int64.Stride(s)).map { .zahl($0) }
            }
        } else if form == 2 {
            let n = Int(try r.u16())
            optionen = try (0..<n).map { _ in try wertLesen(&r, typ) }
        }
        return EigenschaftsBeschreibung(code: code, typ: typ, schreibbar: schreibbar, wert: wert, optionen: optionen)
    }

    func setzen(_ code: UInt16, typ: UInt16, wert: PTPWert) async throws {
        var d = Data()
        switch (typ, wert) {
        case (0xFFFF, .text(let t)): d = ptpText(t)
        case (1, .zahl(let z)), (2, .zahl(let z)): d.append(UInt8(truncatingIfNeeded: z))
        case (3, .zahl(let z)), (4, .zahl(let z)): d.u16(UInt16(truncatingIfNeeded: z))
        case (5, .zahl(let z)), (6, .zahl(let z)): d.u32(UInt32(truncatingIfNeeded: z))
        case (7, .zahl(let z)), (8, .zahl(let z)): d.u64(UInt64(bitPattern: z))
        default: throw PTPFehler.protokoll("Wert passt nicht zur Einstellung")
        }
        let (c, _) = try await befehl(0x1016, [UInt32(code)], senden: d)
        if c != PTP.ok { throw PTPFehler.antwort(c, "Einstellung setzen") }
        _ = try await warteBereit()
    }

    func wert(_ code: UInt16, typ: UInt16) async -> PTPWert? {
        guard let a = try? await befehl(0x1015, [UInt32(code)]), a.0 == PTP.ok else { return nil }
        var r = Leser(a.1)
        return try? wertLesen(&r, typ)
    }

    // MARK: Ausloesen, Fokus, Live-Bild

    @discardableResult
    func warteBereit(maxSekunden: Double = 15) async throws -> UInt16 {
        guard ops.contains(0x90C8) else { return PTP.ok }
        let ende = Date().addingTimeInterval(maxSekunden)
        while Date() < ende {
            let (c, _) = try await befehl(0x90C8)
            if c != PTP.beschaeftigt { return c }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PTPFehler.zeitueberschreitung
    }

    func fokussieren() async throws {
        guard ops.contains(0x90C1) else { throw PTPFehler.abgelehnt("Autofokus per WLAN nicht verfügbar") }
        var (c, _) = try await befehl(0x90C1)
        if c == PTP.ok { c = try await warteBereit() }
        if c != PTP.ok { throw PTPFehler.antwort(c, "Scharfstellen") }
    }

    /// Löst aus (per Auslöser-Test an der D7500 ermittelt):
    /// Scharfstellen separat, Auslösen ohne AF-Anweisung; ohne Live-Bild notfalls Live-Bild kurz einschalten.
    func ausloesen(mitAF: Bool) async throws {
        if mitAF && ops.contains(0x90C1) {
            var (c, _) = try await befehl(0x90C1)
            if c == PTP.ok { c = try await warteBereit() }
            if c == 0xA002 { throw PTPFehler.abgelehnt("Nicht scharfgestellt – Motiv anvisieren oder am Objektiv auf M stellen") }
        }
        func einmal() async throws -> UInt16 {
            var c: UInt16
            if ops.contains(0x9207) {
                (c, _) = try await befehl(0x9207, [0xFFFF_FFFF, 0])
            } else {
                (c, _) = try await befehl(0x100E, [0, 0])
            }
            if c == PTP.ok { c = try await warteBereit(maxSekunden: 30) }
            return c
        }
        var c = try await einmal()
        let liveLaeuft = await liveBildKommt(1)
        if [0xA004, 0xA002, 0x200F].contains(c) && ops.contains(0x9201) && !liveLaeuft {
            let (cl, _) = try await befehl(0x9201)
            if cl == PTP.ok {
                _ = try? await warteBereit(maxSekunden: 10)
                c = try await einmal()
                _ = try? await befehl(0x9202)
            }
        }
        if c == 0xA002 { throw PTPFehler.abgelehnt("Nicht scharfgestellt – Motiv anvisieren oder am Objektiv auf M stellen") }
        if c != PTP.ok { throw PTPFehler.antwort(c, "Auslösen") }
    }

    private func liveBildKommt(_ versuche: Int = 15) async -> Bool {
        for _ in 0..<versuche {
            if let r = try? await befehl(0x9203), r.0 == PTP.ok, r.1.range(of: Data([0xFF, 0xD8, 0xFF])) != nil { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Startet das Live-Bild. Massgebend ist, ob danach wirklich Bilder kommen.
    func liveStarten() async throws {
        if await liveBildKommt(2) { return }                      // laeuft schon
        var (c, _) = try await befehl(0x9201)                     // Nikon StartLiveView
        if c != PTP.ok && c != PTP.beschaeftigt && ops.contains(0x90C2) {
            let (c2, _) = try await befehl(0x90C2, [1])
            if c2 == PTP.ok { _ = try? await warteBereit(maxSekunden: 5) }
            (c, _) = try await befehl(0x9201)
        }
        if c == PTP.ok || c == PTP.beschaeftigt { _ = try? await warteBereit(maxSekunden: 10) }
        if await liveBildKommt() { return }
        throw PTPFehler.antwort(c == PTP.ok ? 0xA00B : c, String(format: "Live-Bild (Code 0x%04X)", c))
    }

    func liveStoppen() async { _ = try? await befehl(0x9202) }   // Nikon EndLiveView

    func liveBild() async throws -> Data? {
        let (c, d) = try await befehl(0x9203)
        if c == PTP.beschaeftigt { return nil }
        if c != PTP.ok { throw PTPFehler.antwort(c, "Live-Bild") }
        let soi = Data([0xFF, 0xD8, 0xFF])
        guard let r = d.range(of: soi) else { return nil }
        return d.subdata(in: r.lowerBound..<d.endIndex)
    }
}
