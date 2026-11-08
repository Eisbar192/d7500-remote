// Oberflaeche der iPhone-App (gleiche Gestaltung wie die Mac-App: Graphit + Bernstein).

import SwiftUI
import UIKit

extension Color {
    static let gehaeuse = Color(red: 0x1C / 255, green: 0x1E / 255, blue: 0x21 / 255)
    static let flaeche = Color(red: 0x25 / 255, green: 0x28 / 255, blue: 0x2C / 255)
    static let kante = Color(red: 0x38 / 255, green: 0x3C / 255, blue: 0x42 / 255)
    static let papier = Color(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xE1 / 255)
    static let bernstein = Color(red: 0xF2 / 255, green: 0xA2 / 255, blue: 0x3C / 255)
    static let signalGruen = Color(red: 0x6C / 255, green: 0xCB / 255, blue: 0x8F / 255)
}

extension Font {
    static func zahl(_ groesse: CGFloat) -> Font { .system(size: groesse, weight: .regular, design: .rounded).monospacedDigit() }
}

@main
struct D7500RemoteApp: App {
    @StateObject private var zustand = AppZustand()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Hauptansicht()
                .environmentObject(zustand)
                .environmentObject(zustand.route)
                .preferredColorScheme(.dark)
                .tint(Color.bernstein)
        }
        .onChange(of: phase) { neu in
            if neu == .active { zustand.starten() } else if neu == .background { zustand.anhalten() }
        }
    }
}

struct Hauptansicht: View {
    @EnvironmentObject var z: AppZustand

    var body: some View {
        TabView {
            BilderAnsicht().tabItem { Label("Bilder", systemImage: "photo.on.rectangle") }
            FernAnsicht().tabItem { Label("Fernsteuerung", systemImage: "camera") }
            GPSAnsicht().tabItem { Label("GPS", systemImage: "location") }
        }
        .onAppear { z.starten() }
        .alert("Hinweis", isPresented: Binding(get: { z.fehler != nil }, set: { if !$0 { z.fehler = nil } })) {
            Button("OK", role: .cancel) { z.fehler = nil }
        } message: { Text(z.fehler ?? "") }
    }
}

// MARK: - Statuszeile

struct Statuszeile: View {
    @EnvironmentObject var z: AppZustand

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(z.verbunden ? Color.signalGruen : Color.red).frame(width: 8, height: 8)
            Text(z.verbunden ? "\(z.modell) verbunden" : z.meldung).font(.subheadline)
            Spacer()
            if let a = z.akku {
                Label("\(a) %", systemImage: a <= 20 ? "battery.25" : "battery.75").font(Font.zahl(14))
                    .foregroundStyle(a <= 20 ? Color.red : Color.secondary)
            }
            if let f = z.kartenFrei {
                Text(ByteCountFormatter.string(fromByteCount: f, countStyle: .file) + " frei")
                    .font(Font.zahl(14)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.flaeche)
    }
}

struct VerbindenHilfe: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verbinde deine D7500").font(.title2.weight(.semibold))
            Schritt(n: 1, text: "An der Kamera: **Systemmenü → Wi-Fi → Wi-Fi-Verbindung herstellen**")
            Schritt(n: 2, text: "Am iPhone: **Einstellungen → WLAN → D7500_…** wählen und das Passwort von der Kamera eingeben")
            Schritt(n: 3, text: "Zurück in diese App – sie verbindet sich von selbst")
            Text("SnapBridge vorher schliessen: Die Kamera erlaubt nur eine Verbindung.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { Label("iPhone-Einstellungen öffnen", systemImage: "gear") }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct Schritt: View {
    let n: Int
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(Font.zahl(15)).frame(width: 28, height: 28)
                .overlay(Circle().stroke(Color.kante))
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Bilder

struct BilderAnsicht: View {
    @EnvironmentObject var z: AppZustand
    @AppStorage("auto") private var auto = false
    @AppStorage("format") private var formatRoh = Format.beide.rawValue
    @State private var auswahlModus = false
    @State private var auswahl = Set<UInt32>()
    @State private var detail: DateiInfo?
    @State private var filter = "alle"

    private let spalten = [GridItem(.adaptive(minimum: 108), spacing: 3)]

    var sichtbar: [DateiInfo] {
        z.dateien.filter {
            switch filter {
            case "JPG", "NEF": return $0.typ == filter
            case "neu": return !z.gespeichert.contains($0.name)
            default: return true
            }
        }
    }

    struct Gruppe: Identifiable {
        let titel: String
        var dateien: [DateiInfo]
        var id: String { titel }
    }

    var gruppen: [Gruppe] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = "EEEE, d. MMMM yyyy"
        var r: [Gruppe] = []
        for d in sichtbar {
            let t = d.datum.map { f.string(from: $0) } ?? "Ohne Datum"
            if let i = r.firstIndex(where: { $0.titel == t }) { r[i].dateien.append(d) } else { r.append(Gruppe(titel: t, dateien: [d])) }
        }
        return r
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Statuszeile()
                if !z.verbunden && z.dateien.isEmpty {
                    ScrollView { VerbindenHilfe() }
                } else {
                    Picker("Filter", selection: $filter) {
                        Text("Alle").tag("alle"); Text("JPG").tag("JPG"); Text("RAW").tag("NEF"); Text("Neu").tag("neu")
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(gruppen) { gruppe in
                                Section {
                                    LazyVGrid(columns: spalten, spacing: 3) {
                                        ForEach(gruppe.dateien) { d in
                                            Kachel(datei: d, gewaehlt: auswahl.contains(d.handle))
                                                .onTapGesture { tippen(d) }
                                        }
                                    }
                                } header: {
                                    Text(gruppe.titel).font(.headline).padding(.horizontal, 16).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.gehaeuse.opacity(0.95))
                                }
                            }
                        }
                        .padding(.bottom, 90)
                    }
                }
            }
            .background(Color.gehaeuse)
            .navigationTitle("Bilder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Toggle("Neue Fotos automatisch laden", isOn: $auto)
                        Picker("Format", selection: $formatRoh) {
                            ForEach(Format.allCases) { Text($0.titel).tag($0.rawValue) }
                        }
                        Button("Alle neuen laden") {
                            let f = Format(rawValue: formatRoh) ?? .beide
                            z.einreihen(z.dateien.filter { f.passt($0.typ) && !z.gespeichert.contains($0.name) }.reversed().map(\.handle))
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(auswahlModus ? "Fertig" : "Auswählen") {
                        auswahlModus.toggle()
                        if !auswahlModus { auswahl.removeAll() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { untereLeiste }
            .sheet(item: $detail) { DetailAnsicht(datei: $0) }
        }
    }

    func tippen(_ d: DateiInfo) {
        if auswahlModus {
            if auswahl.contains(d.handle) { auswahl.remove(d.handle) } else { auswahl.insert(d.handle) }
        } else {
            detail = d
        }
    }

    @ViewBuilder var untereLeiste: some View {
        if let dl = z.download {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(dl.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Abbrechen") { z.abbrechen() }.font(.subheadline)
                }
                ProgressView(value: Double(dl.geladen), total: Double(max(dl.groesse, 1)))
                let tempo = Double(dl.geladen) / max(Date().timeIntervalSince(dl.start), 0.1) / 1e6
                Text(String(format: "%.1f MB/s", tempo) + (z.warteschlange.isEmpty ? "" : " – noch \(z.warteschlange.count) in der Warteschlange"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(12)
        } else if auswahlModus && !auswahl.isEmpty {
            Button {
                z.einreihen(Array(auswahl))
                auswahl.removeAll()
                auswahlModus = false
            } label: {
                Text("\(auswahl.count) in Fotos speichern").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Color.gehaeuse).padding(12)
        }
    }
}

struct Kachel: View {
    @EnvironmentObject var z: AppZustand
    let datei: DateiInfo
    let gewaehlt: Bool
    @State private var bild: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let b = bild { Image(uiImage: b).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                Text(datei.typ == "NEF" ? "RAW" : datei.typ).font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(datei.typ == "NEF" ? Color.bernstein : Color.papier).padding(5)
            }
            .overlay(alignment: .topTrailing) {
                if gewaehlt {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.gehaeuse, Color.bernstein).font(.title3).padding(5)
                } else if z.gespeichert.contains(datei.name) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.signalGruen.opacity(0.85)).padding(5)
                }
            }
            .overlay { if gewaehlt { Rectangle().stroke(Color.bernstein, lineWidth: 3) } }
            .task(id: datei.handle) {
                var versuche = 0
                while bild == nil && versuche < 5 && !Task.isCancelled {
                    bild = await z.vorschau(datei.handle)
                    if bild == nil { versuche += 1; try? await Task.sleep(nanoseconds: 1_500_000_000) }
                }
            }
    }
}

struct DetailAnsicht: View {
    @EnvironmentObject var z: AppZustand
    @Environment(\.dismiss) private var schliessen
    let datei: DateiInfo
    @State private var bild: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let b = bild { Image(uiImage: b).resizable().scaledToFit() } else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 4) {
                    Text(datei.name).font(.headline)
                    Text("\(datei.breite) × \(datei.hoehe) – " + ByteCountFormatter.string(fromByteCount: Int64(datei.groesse), countStyle: .file))
                        .font(Font.zahl(14)).foregroundStyle(.secondary)
                }
                if z.gespeichert.contains(datei.name) {
                    Label("Schon in der Fotos-App", systemImage: "checkmark.circle").foregroundStyle(Color.signalGruen)
                } else {
                    Button {
                        z.einreihen([datei.handle])
                        schliessen()
                    } label: {
                        Text("In Fotos speichern").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.gehaeuse)
                }
            }
            .padding()
            .background(Color.gehaeuse)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Schliessen") { schliessen() } } }
            .task { bild = await z.vorschau(datei.handle, gross: true) }
        }
    }
}

// MARK: - Fernsteuerung

struct FernAnsicht: View {
    @EnvironmentObject var z: AppZustand
    @State private var mitAF = true
    @State private var arbeitet = false
    @State private var rueckmeldung = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Statuszeile()
                if !z.verbunden {
                    ScrollView { VerbindenHilfe() }
                } else {
                    List {
                        Section {
                            liveBereich
                            bedienung
                        }
                        .listRowBackground(Color.flaeche)
                        ForEach(Eigenschaften.gruppen, id: \.self) { g in
                            let es = z.einstellungen.filter { $0.gruppe == g }
                            if !es.isEmpty {
                                Section(g) {
                                    ForEach(es) { EinstellungsZeile(e: $0) }
                                    if g == "Kamera" {
                                        Button("Kamera-Uhr vom iPhone übernehmen") { Task { await z.uhrzeitStellen() } }
                                    }
                                }
                                .listRowBackground(Color.flaeche)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable { await z.einstellungenLaden() }
                }
            }
            .background(Color.gehaeuse)
            .navigationTitle("Fernsteuerung")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: z.verbunden) { await z.einstellungenLaden() }
            .onDisappear { if z.liveAn { z.liveStoppen() } }
        }
    }

    var liveBereich: some View {
        ZStack {
            Color.black
            if let b = z.liveBild {
                Image(uiImage: b).resizable().scaledToFit()
            } else {
                VStack(spacing: 6) {
                    Text(z.liveAn ? "Warte auf Bild …" : "Live-Bild ist aus").foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(3 / 2, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 6, trailing: 12))
    }

    var bedienung: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button(z.liveAn ? "Live-Bild aus" : "Live-Bild an") {
                    Task { if z.liveAn { z.liveStoppen() } else { await z.liveStarten() } }
                }
                .buttonStyle(.bordered)
                Button("Scharfstellen") {
                    Task { if await z.fokussieren() { rueckmeldung = "Scharf" } }
                }
                .buttonStyle(.bordered)
                Toggle("Vorher scharfstellen", isOn: $mitAF).font(.footnote).fixedSize()
            }
            Spacer()
            VStack(spacing: 6) {
                Button {
                    Task {
                        arbeitet = true
                        rueckmeldung = ""
                        if await z.ausloesen(mitAF: mitAF) { rueckmeldung = "Foto aufgenommen" }
                        arbeitet = false
                    }
                } label: {
                    Circle().fill(arbeitet ? Color.bernstein : Color.papier)
                        .frame(width: 62, height: 62)
                        .padding(5)
                        .overlay(Circle().stroke(Color.kante, lineWidth: 3))
                }
                .buttonStyle(.plain)
                .disabled(arbeitet)
                .accessibilityLabel("Auslösen")
                Text(rueckmeldung).font(.caption).foregroundStyle(.secondary).frame(height: 14)
            }
        }
        .padding(.vertical, 6)
    }
}

struct EinstellungsZeile: View {
    @EnvironmentObject var z: AppZustand
    let e: Einstellung
    @State private var text = ""

    var body: some View {
        if e.schreibbar, let opts = e.optionen, !opts.isEmpty {
            Picker(e.name, selection: Binding(get: { e.wert }, set: { neu in Task { await z.setzen(e, neu) } })) {
                if !opts.contains(e.wert) { Text(e.text).tag(e.wert) }
                ForEach(opts, id: \.self) { Text(Eigenschaften.text(e.code, $0)).tag($0) }
            }
        } else if e.schreibbar, case .text = e.wert, e.code != 0x5011 {
            HStack {
                Text(e.name)
                TextField("nicht gesetzt", text: $text)
                    .multilineTextAlignment(.trailing)
                    .onAppear { text = e.wert.text ?? "" }
                    .onSubmit { Task { await z.setzen(e, .text(text)) } }
            }
        } else {
            LabeledContent(e.name) {
                VStack(alignment: .trailing) {
                    Text(e.text)
                    if e.code == 0x500E { Text("am Moduswahlrad").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: - GPS

struct GPSAnsicht: View {
    @EnvironmentObject var route: Routenaufzeichnung

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Route aufzeichnen", isOn: Binding(get: { route.aktiv }, set: { $0 ? route.starten() : route.stoppen() }))
                    LabeledContent("Aufgezeichnete Punkte", value: "\(route.anzahl)")
                    if let o = route.letzterOrt {
                        LabeledContent("Letzter Ort", value: String(format: "%.5f, %.5f", o.coordinate.latitude, o.coordinate.longitude))
                    }
                    if route.berechtigung == .denied || route.berechtigung == .restricted {
                        Text("Standort ist für D7500 Remote gesperrt. Bitte in den iPhone-Einstellungen erlauben.")
                            .foregroundStyle(.red).font(.footnote)
                    }
                } footer: {
                    Text("Wie bei SnapBridge: Während die Aufzeichnung läuft, merkt sich das iPhone deinen Weg. Fotos, die du danach in die Fotos-App speicherst, bekommen anhand der Aufnahmezeit ihren Ort.")
                }
                .listRowBackground(Color.flaeche)

                Section {
                    if let url = route.gpxDatei() {
                        ShareLink(item: url) { Label("Route als GPX teilen", systemImage: "square.and.arrow.up") }
                    }
                    Button("Route löschen", role: .destructive) { route.loeschen() }
                } footer: {
                    Text("Die GPX-Datei kannst du auch in der Mac-App unter GPS laden, um Fotos zu verorten, die du am Mac geladen hast.")
                }
                .listRowBackground(Color.flaeche)
            }
            .scrollContentBackground(.hidden)
            .background(Color.gehaeuse)
            .navigationTitle("GPS")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
