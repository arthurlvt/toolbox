import SwiftUI
import AppKit
import PDFKit
import PDFCore

// MARK: - Numéroter & filigrane

final class StampStore: ObservableObject {
    @Published var file: FileItem? { didSet { schedulePreview() } }
    @Published var options = StampOptions() { didSet { schedulePreview() } }
    @Published var preview: NSImage?
    @Published var status: StatusMessage?
    @Published var working = false

    private var pendingPreview: DispatchWorkItem?

    init() {
        options.numbering = true
    }

    func choose(_ url: URL) {
        let item = FileItem(url)
        guard item.pageCount != nil else { status = .err("Impossible d'ouvrir « \(item.name) »."); return }
        file = item
        status = nil
    }

    private func schedulePreview() {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func refreshPreview() {
        guard let url = file?.url else { preview = nil; return }
        let o = options
        runInBackground({ Stamper.preview(url, options: o) }) { [weak self] result in
            if case .success(let image?) = result {
                self?.preview = NSImage(cgImage: image, size: .zero)
            }
        }
    }

    func run() {
        guard let file = file else { return }
        let input = file.url
        let base = input.deletingPathExtension().lastPathComponent
        guard let out = Panels.save(suggested: "\(base)_numéroté.pdf", type: .pdf,
                                    directory: input.deletingLastPathComponent()) else { return }
        let o = options
        working = true
        runInBackground({ try Stamper.stamp(input, options: o, to: out) }) { [weak self] result in
            guard let self = self else { return }
            self.working = false
            switch result {
            case .success(let n): self.status = .ok("\(out.lastPathComponent) créé (\(n) pages).", files: [out])
            case .failure(let e): self.status = .err(e)
            }
        }
    }
}

struct StampToolView: View {
    @StateObject private var s = StampStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .stamp)
            if let file = s.file {
                ChosenFileCard(item: file, types: [.pdf]) { s.choose($0) }
                HStack(alignment: .top, spacing: 16) {
                    form.frame(minWidth: 380, maxWidth: 480)
                    previewPane
                }
                HStack {
                    Text("Note : les liens internes du PDF ne sont pas conservés dans le fichier tamponné.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if s.working { ProgressView().controlSize(.small) }
                    Button { s.run() } label: { Label("Appliquer…", systemImage: "number") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.working || s.options.isEmpty)
                }
            } else {
                DropZone(title: "Dépose le PDF à numéroter ou à marquer",
                         subtitle: "Numéros de page, en-tête, pied de page et filigrane, avec aperçu en direct.",
                         types: [.pdf], multiple: false) { urls in
                    if let u = urls.first { s.choose(u) }
                }
                Spacer()
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    private var form: some View {
        Form {
            Section("Numérotation") {
                Toggle("Numéroter les pages", isOn: $s.options.numbering)
                Group {
                    TextField("Format", text: $s.options.numberFormat, prompt: Text("{n} / {total}"))
                    Picker("Position", selection: $s.options.numberPosition) {
                        ForEach(StampPosition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Commencer à \(s.options.firstNumber)", value: $s.options.firstNumber, in: 0...9999)
                    Toggle("Pas de numéro sur la première page", isOn: $s.options.skipFirstPage)
                }
                .disabled(!s.options.numbering)
            }
            Section("En-tête et pied de page") {
                TextField("En-tête (centré)", text: $s.options.header, prompt: Text("Ex. : Analyse 1 — TD 3"))
                TextField("Pied de page (à gauche)", text: $s.options.footer, prompt: Text("Ex. : {fichier} — {date}"))
            }
            Section("Filigrane") {
                TextField("Texte", text: $s.options.watermark, prompt: Text("Ex. : BROUILLON"))
                Slider(value: $s.options.watermarkOpacity, in: 0.05...0.6) { Text("Opacité") }
                    .disabled(s.options.watermark.isEmpty)
            }
            Section {
                Stepper("Taille du texte : \(Int(s.options.fontSize)) pt", value: $s.options.fontSize, in: 6...24)
                Text("Variables : {n} numéro · {total} dernier numéro · {fichier} · {date}")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewPane: some View {
        VStack {
            if let image = s.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
            } else {
                ProgressView()
            }
            Text("Aperçu de la première page numérotée").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Sécurité & infos

struct InfoRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

final class SecurityStore: ObservableObject {
    @Published var file: FileItem?
    @Published var locked = false
    @Published var encrypted = false
    @Published var password = ""
    @Published var confirm = ""
    @Published var meta = PDFMetadata()
    @Published var info: [InfoRow] = []
    @Published var status: StatusMessage?
    @Published var working = false

    func choose(_ url: URL) {
        file = FileItem(url)
        let doc = PDFDocument(url: url)
        locked = doc?.isLocked ?? false
        encrypted = doc?.isEncrypted ?? false
        password = ""
        confirm = ""
        meta = (try? Metadata.read(url)) ?? PDFMetadata()
        info = ((try? PDFOps.info(url)) ?? []).map { InfoRow(key: $0.0, value: $0.1) }
        status = nil
    }

    var canProtect: Bool { !password.isEmpty && password == confirm && !locked }

    private func finish(_ result: Result<Void, Error>, _ message: String, _ out: URL) {
        working = false
        switch result {
        case .success: status = .ok(message, files: [out])
        case .failure(let e): status = .err(e)
        }
    }

    func protect() {
        guard let file = file, canProtect else { return }
        let input = file.url
        guard let out = Panels.save(suggested: input.deletingPathExtension().lastPathComponent + "_protégé.pdf",
                                    type: .pdf, directory: input.deletingLastPathComponent()) else { return }
        let pw = password
        working = true
        runInBackground({ try Security.protect(input, password: pw, to: out) }) { [weak self] r in
            self?.finish(r, "\(out.lastPathComponent) est protégé par mot de passe.", out)
        }
    }

    func unlock() {
        guard let file = file else { return }
        let input = file.url
        guard let out = Panels.save(suggested: input.deletingPathExtension().lastPathComponent + "_déverrouillé.pdf",
                                    type: .pdf, directory: input.deletingLastPathComponent()) else { return }
        let pw = password
        working = true
        runInBackground({ try Security.unlock(input, password: pw, to: out) }) { [weak self] r in
            self?.finish(r, "\(out.lastPathComponent) n'a plus de mot de passe.", out)
        }
    }

    func saveMetadata() {
        guard let file = file else { return }
        let input = file.url
        guard let out = Panels.save(suggested: input.lastPathComponent, type: .pdf,
                                    directory: input.deletingLastPathComponent()) else { return }
        let m = meta
        working = true
        runInBackground({ try Metadata.write(m, input, to: out) }) { [weak self] r in
            self?.finish(r, "Informations enregistrées dans \(out.lastPathComponent).", out)
            if out == input { self?.choose(out) }
        }
    }
}

struct SecurityToolView: View {
    @StateObject private var s = SecurityStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .security)
            if let file = s.file {
                ChosenFileCard(item: file, types: [.pdf]) { s.choose($0) }
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        passwordBox
                        metadataBox
                    }
                    .frame(maxWidth: 520)
                    infoBox
                }
                Spacer()
            } else {
                DropZone(title: "Dépose un PDF",
                         subtitle: "Ajouter ou retirer un mot de passe, modifier le titre, l'auteur et les mots-clés.",
                         types: [.pdf], multiple: false) { urls in
                    if let u = urls.first { s.choose(u) }
                }
                Spacer()
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    private var passwordBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if s.locked || s.encrypted {
                    Label(s.locked ? "Ce PDF est protégé par un mot de passe." : "Ce PDF est chiffré (restrictions).",
                          systemImage: "lock.fill")
                        .foregroundStyle(Color.orange)
                    SecureField("Mot de passe actuel", text: $s.password)
                    HStack {
                        Spacer()
                        Button { s.unlock() } label: { Label("Retirer la protection…", systemImage: "lock.open") }
                            .disabled(s.working || (s.locked && s.password.isEmpty))
                    }
                } else {
                    SecureField("Nouveau mot de passe", text: $s.password)
                    SecureField("Confirmer", text: $s.confirm)
                    if !s.confirm.isEmpty && s.password != s.confirm {
                        Text("Les deux mots de passe ne correspondent pas.").font(.caption).foregroundStyle(Color.red)
                    }
                    HStack {
                        Spacer()
                        Button { s.protect() } label: { Label("Protéger…", systemImage: "lock") }
                            .buttonStyle(.borderedProminent)
                            .disabled(s.working || !s.canProtect)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Mot de passe", systemImage: "key")
        }
    }

    private var metadataBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Titre", text: $s.meta.title)
                TextField("Auteur", text: $s.meta.author)
                TextField("Sujet", text: $s.meta.subject)
                TextField("Mots-clés (séparés par des virgules)", text: $s.meta.keywords)
                HStack {
                    Text("Utile pour retrouver tes PDF avec Spotlight.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { s.saveMetadata() } label: { Label("Enregistrer…", systemImage: "square.and.arrow.down") }
                        .disabled(s.working || s.locked)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(6)
        } label: {
            Label("Informations du document", systemImage: "info.circle")
        }
    }

    private var infoBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.info) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.key).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(row.value).textSelection(.enabled).lineLimit(2)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Détails", systemImage: "doc.text.magnifyingglass")
        }
    }
}
