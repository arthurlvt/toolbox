import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Modèle

enum AnnalesTab: String, CaseIterable, Identifiable {
    case depot = "Dépôt"
    case relecture = "Relecture"
    case banque = "Banque"
    case reglages = "Réglages"
    var id: String { rawValue }
}

struct DepositItem: Identifiable {
    enum Status { case attente, enCours, fini, erreur }
    let id = UUID()
    let url: URL
    var declared: DeclaredInfo
    var status: Status = .attente
    var log: [String] = []
    var message = ""
    var subjects: [SubjectOutput] = []
}

struct ReviewItem: Identifiable {
    let id = UUID()
    let ficheURL: URL
    let fiche: SubjectFiche
    var pdf: URL? {
        let u = ficheURL.deletingPathExtension().appendingPathExtension("pdf")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var tex: URL? {
        let u = ficheURL.deletingPathExtension().appendingPathExtension("tex")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var name: String { ficheURL.deletingPathExtension().lastPathComponent }
}

final class AnnalesStore: ObservableObject {
    // Réglages (mémorisés)
    @Published var annalyseRoot: URL? { didSet { save(); reloadConfig() } }
    @Published var bankRoot: URL? { didSet { save() } }
    @Published var model = "" { didSet { save() } }
    @Published var useImages = true { didSet { save() } }
    @Published var aiTagging = true { didSet { save() } }
    @Published var compress = true { didSet { save() } }
    @Published var numCtx = 16384 { didSet { save() } }
    @Published var ollamaHost = OllamaClient.defaultHost { didSet { save() } }

    @Published var tab: AnnalesTab = .depot
    @Published var models: [OllamaModel] = []
    @Published var ollamaStatus = "Vérification d'Ollama…"
    @Published var ollamaOK = false
    @Published var config: AnnalesConfig?
    @Published var configError = ""

    // Dépôt
    @Published var declared = DeclaredInfo()
    @Published var queue: [DepositItem] = []
    @Published var selectedDeposit: UUID?
    @Published var processing = false
    @Published var status: StatusMessage?

    // Relecture
    @Published var reviews: [ReviewItem] = []
    @Published var selectedReview: UUID?
    @Published var corrections = DeclaredInfo()
    @Published var reviewer = NSFullUserName()

    // Banque
    @Published var searchText = ""
    @Published var searchNiveau = ""
    @Published var searchMatiere = ""
    @Published var searchNotion = ""
    @Published var results: [BankSearchResult] = []
    @Published var summary: [(niveau: String, matiere: String, sujets: Int, enAttente: Int)] = []
    @Published var stats: (total: Int, rows: [(notion: String, sujets: Int, exercices: Int)])?

    // Sujet d'entraînement
    @Published var cart: [Int] = []
    @Published var showCompose = false
    @Published var composeMatiere = ""
    @Published var composeNiveau = ""
    @Published var composeNotions: Set<String> = []
    @Published var composeCount = 4
    @Published var composeTitle = ""
    @Published var composing = false

    private let defaults = UserDefaults.standard
    private var loading = true

    init() {
        if let p = defaults.string(forKey: "annales.root") { annalyseRoot = URL(fileURLWithPath: p) }
        else {
            let guess = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Nextcloud/cours/projets-perso/Annalyse")
            if FileManager.default.fileExists(atPath: guess.appendingPathComponent("config").path) { annalyseRoot = guess }
        }
        if let p = defaults.string(forKey: "annales.bank") { bankRoot = URL(fileURLWithPath: p) }
        else if let root = annalyseRoot { bankRoot = root.appendingPathComponent("banque") }
        model = defaults.string(forKey: "annales.model") ?? ""
        if defaults.object(forKey: "annales.images") != nil { useImages = defaults.bool(forKey: "annales.images") }
        if defaults.object(forKey: "annales.aitags") != nil { aiTagging = defaults.bool(forKey: "annales.aitags") }
        if defaults.object(forKey: "annales.compress") != nil { compress = defaults.bool(forKey: "annales.compress") }
        if let h = defaults.string(forKey: "annales.host"), !h.isEmpty { ollamaHost = h }
        let ctx = defaults.integer(forKey: "annales.ctx")
        if ctx > 0 { numCtx = ctx }
        loading = false
        reloadConfig()
        refreshModels()
    }

    private func save() {
        guard !loading else { return }
        defaults.set(annalyseRoot?.path, forKey: "annales.root")
        defaults.set(bankRoot?.path, forKey: "annales.bank")
        defaults.set(model, forKey: "annales.model")
        defaults.set(useImages, forKey: "annales.images")
        defaults.set(aiTagging, forKey: "annales.aitags")
        defaults.set(compress, forKey: "annales.compress")
        defaults.set(numCtx, forKey: "annales.ctx")
        defaults.set(ollamaHost, forKey: "annales.host")
    }

    func reloadConfig() {
        guard let root = annalyseRoot else { config = nil; configError = "Choisis le dossier Annalyse (avec config/ et latex/)."; return }
        do {
            config = try AnnalesConfig.load(root: root)
            configError = ""
        } catch {
            config = nil
            configError = error.localizedDescription
        }
    }

    func refreshModels() {
        ollamaStatus = "Vérification d'Ollama…"
        Task {
            do {
                let list = try await OllamaClient(host: self.ollamaHost).models()
                await MainActor.run {
                    self.models = list
                    self.ollamaOK = true
                    if list.isEmpty {
                        self.ollamaStatus = "Ollama tourne, mais aucun modèle n'est installé."
                    } else {
                        self.ollamaStatus = "Ollama : \(list.count) modèle(s) installé(s)."
                        if self.model.isEmpty || !list.contains(where: { $0.name == self.model }) {
                            self.model = list.first { $0.name.contains("qwen2.5vl") || $0.name.contains("vl") }?.name ?? list[0].name
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.ollamaOK = false
                    self.models = []
                    self.ollamaStatus = error.localizedDescription
                }
            }
        }
    }

    var ready: Bool { config != nil && bankRoot != nil && ollamaOK && !model.isEmpty }

    /// En dessous de ~4 Go (≈ 3 milliards de paramètres), le modèle invente ou recopie au lieu de transcrire.
    var smallModelWarning: String? {
        guard let m = models.first(where: { $0.name == model }), m.size > 0, m.size < 4_000_000_000 else { return nil }
        return "\(m.name) est un petit modèle (\(m.sizeLabel)) : il risque d'inventer ou de recopier au lieu de transcrire. Installe plutôt « ollama pull qwen2.5vl:7b » (Réglages → Modèle)."
    }

    func makePipeline() throws -> AnnalesPipeline {
        guard let root = annalyseRoot, let bank = bankRoot else { throw PDFToolError.noInput }
        var s = AnnalesSettings(annalyseRoot: root, bankRoot: bank, model: model)
        s.conversion.useImages = useImages
        s.conversion.numCtx = numCtx
        s.aiTagging = aiTagging
        s.compressOutput = compress
        return try AnnalesPipeline(settings: s, client: OllamaClient(host: ollamaHost))
    }

    // MARK: Dépôt

    func add(_ urls: [URL]) {
        let accepted = urls.filter { AnnalesExtractor.supportedExtensions.contains($0.pathExtension.lowercased()) }
        queue += accepted.map { DepositItem(url: $0, declared: declared) }
        if selectedDeposit == nil { selectedDeposit = queue.first?.id }
        if accepted.count < urls.count {
            status = .err("\(urls.count - accepted.count) fichier(s) ignoré(s) : format non pris en charge.")
        }
    }

    func processAll() {
        guard ready, !processing else { return }
        let pipeline: AnnalesPipeline
        do { pipeline = try makePipeline() } catch { status = .err(error); return }
        processing = true
        status = .info("Traitement en cours… (la première conversion charge le modèle, ça peut prendre une minute)")
        let todo = queue.filter { $0.status == .attente }.map { ($0.id, $0.url, $0.declared) }
        Task {
            for (id, url, declared) in todo {
                await MainActor.run { self.update(id) { $0.status = .enCours } }
                do {
                    let outcome = try await pipeline.process(url, declared: declared) { line in
                        DispatchQueue.main.async { self.update(id) { $0.log.append(line) } }
                    }
                    await MainActor.run {
                        self.update(id) {
                            $0.status = .fini
                            $0.message = outcome.message
                            $0.subjects = outcome.subjects
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.update(id) {
                            $0.status = .erreur
                            $0.message = error.localizedDescription
                            $0.log.append("Erreur : \(error.localizedDescription)")
                        }
                    }
                }
            }
            await MainActor.run {
                self.processing = false
                let done = self.queue.filter { $0.status == .fini }.flatMap { $0.subjects }
                let ranged = done.filter { $0.fiche.etat == .range }.count
                let toCheck = done.filter { $0.fiche.etat == .aVerifier }.count
                self.status = .ok("Terminé : \(ranged) rangé(s), \(toCheck) à relire.")
                self.loadReviews()
            }
        }
    }

    func update(_ id: UUID, _ change: (inout DepositItem) -> Void) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        change(&queue[i])
    }

    // MARK: Relecture

    func loadReviews() {
        guard let bank = bankRoot else { reviews = []; return }
        let dir = bank.appendingPathComponent("a_verifier")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        reviews = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let fiche = try? JSONDecoder().decode(SubjectFiche.self, from: data) else { return nil }
            return ReviewItem(ficheURL: url, fiche: fiche)
        }.sorted { $0.name < $1.name }
        if let sel = selectedReview, !reviews.contains(where: { $0.id == sel }) { selectedReview = nil }
        if selectedReview == nil { selectReview(reviews.first) }
    }

    func selectReview(_ item: ReviewItem?) {
        selectedReview = item?.id
        var c = DeclaredInfo()
        if let f = item?.fiche {
            c.niveau = f.meta.niveau ?? ""
            c.matiere = f.meta.matiere ?? ""
            c.anneeUniv = f.meta.anneeUniv ?? ""
            c.session = f.session ?? ""
            c.etablissement = f.meta.etablissement ?? ""
        }
        corrections = c
    }

    var currentReview: ReviewItem? { reviews.first { $0.id == selectedReview } }

    func validateCurrent() {
        guard let item = currentReview else { return }
        let pipeline: AnnalesPipeline
        do { pipeline = try makePipeline() } catch { status = .err(error); return }
        let corr = corrections, who = reviewer
        processing = true
        runInBackground({ try pipeline.validate(ficheURL: item.ficheURL, corrections: corr, reviewer: who) { _ in } }) { [weak self] r in
            guard let self = self else { return }
            self.processing = false
            switch r {
            case .success(let pdf): self.status = .ok("Validé et rangé : \(pdf.lastPathComponent)", files: [pdf])
            case .failure(let e): self.status = .err(e)
            }
            self.loadReviews()
        }
    }

    // MARK: Sujet d'entraînement

    func toggleCart(_ id: Int) {
        if let i = cart.firstIndex(of: id) { cart.remove(at: i) } else { cart.append(id) }
    }

    func openCompose() {
        if composeMatiere.isEmpty { composeMatiere = searchMatiere }
        if composeNiveau.isEmpty { composeNiveau = searchNiveau }
        showCompose = true
    }

    func composeNotionChoices() -> [String] {
        guard let c = config, !composeMatiere.isEmpty else { return [] }
        let niveau = composeNiveau.isEmpty ? (c.matiere(composeMatiere, niveau: nil)?.niveau ?? "") : composeNiveau
        return c.notions(niveau: niveau, matiere: composeMatiere).map { $0.name }
    }

    func compose() {
        guard let bank = bankRoot, let config = config else { return }
        let matiere = composeMatiere, niveau = composeNiveau, notions = Array(composeNotions)
        let count = composeCount, picked = cart
        let nom = config.matiere(matiere, niveau: niveau.isEmpty ? nil : niveau)?.nom ?? matiere
        let titre = composeTitle.isEmpty
            ? (notions.isEmpty ? "Sujet d'entraînement" : "Entraînement : " + notions.sorted().joined(separator: ", "))
            : composeTitle
        let latexFolder = config.latexFolder
        composing = true
        status = .info("Composition du sujet…")
        runInBackground({ () -> ComposeResult in
            let b = try AnnalesBank(root: bank)
            var ids = picked
            if count > 0 && !matiere.isEmpty {
                ids += try b.pickExercises(matiere: matiere, niveau: niveau, notions: notions, count: count,
                                           excluding: Set(picked))
            }
            if ids.isEmpty {
                throw PDFToolError.commandFailed("aucun exercice trouvé pour ces critères (la matière a-t-elle des sujets tagués ?)")
            }
            return try b.compose(ids: ids, titre: titre, matiereNom: nom, latexFolder: latexFolder)
        }) { [weak self] r in
            guard let self = self else { return }
            self.composing = false
            switch r {
            case .success(let res):
                self.showCompose = false
                self.cart = []
                let n = res.fromLatex + res.fromText
                var text = "Sujet de \(n) exercice(s) créé" + (res.pdf == nil ? " (la compilation a échoué : corrige-le dans l'onglet LaTeX)" : "") + "."
                if res.fromText > 0 { text += " \(res.fromText) exercice(s) reconstruit(s) depuis le texte brut : à relire." }
                self.status = .ok(text, files: [res.pdf ?? res.tex])
                AppRouter.shared.incoming = [res.tex]      // ouvre l'éditeur LaTeX avec l'aperçu
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    // MARK: Ménage

    func deleteSujet(_ r: BankSearchResult) {
        guard let bank = bankRoot,
              confirmDestructive("Supprimer ce sujet de la banque ?",
                                 "\(r.niveau) · \(r.matiere) · \(r.annee) · \(r.session) : tous ses exercices sont retirés de la base, et ses PDF / .tex vont à la corbeille. Le même fichier pourra être redéposé.",
                                 button: "Supprimer") else { return }
        runInBackground({ try AnnalesBank(root: bank).deleteSujet(exerciceID: r.id) }) { [weak self] res in
            switch res {
            case .success(let what):
                self?.cart.removeAll()
                self?.status = .ok("Sujet supprimé de la banque : \(what).")
                self?.search()
                self?.loadReviews()
            case .failure(let e):
                self?.status = .err(e)
            }
        }
    }

    func resetBank() {
        guard let bank = bankRoot,
              confirmDestructive("Vider toute la banque ?",
                                 "Les originaux, les sujets rangés, à relire, rejetés et doublons, le registre et la base vont à la corbeille (récupérables tant qu'elle n'est pas vidée). Les sujets d'entraînement sont gardés.",
                                 button: "Tout vider") else { return }
        runInBackground({ try AnnalesBank.reset(root: bank) }) { [weak self] res in
            switch res {
            case .success(let n):
                self?.cart = []
                self?.queue = []
                self?.results = []
                self?.status = .ok("Banque vidée (\(n) élément(s) mis à la corbeille).")
                self?.loadReviews()
                self?.search()
            case .failure(let e):
                self?.status = .err(e)
            }
        }
    }

    // MARK: Banque

    func search() {
        guard let bank = bankRoot else { return }
        let text = searchText, niveau = searchNiveau, matiere = searchMatiere, notion = searchNotion
        runInBackground({ () -> ([BankSearchResult], [(niveau: String, matiere: String, sujets: Int, enAttente: Int)], (total: Int, rows: [(notion: String, sujets: Int, exercices: Int)])?) in
            let b = try AnnalesBank(root: bank)
            let results = try b.search(texte: text, niveau: niveau, matiere: matiere, notion: notion)
            let summary = try b.summary()
            var stats: (total: Int, rows: [(notion: String, sujets: Int, exercices: Int)])?
            if !matiere.isEmpty { stats = try b.stats(matiere: matiere, niveau: niveau) }
            return (results, summary, stats)
        }) { [weak self] r in
            switch r {
            case .success(let (results, summary, stats)):
                self?.results = results
                self?.summary = summary
                self?.stats = stats
            case .failure(let e):
                self?.status = .err(e)
            }
        }
    }
}

// MARK: - Vue principale

struct AnnalesToolView: View {
    @ObservedObject var s: AnnalesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .annales)
            HStack {
                Picker("", selection: $s.tab) {
                    ForEach(AnnalesTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440)
                Spacer()
                Label(s.ollamaStatus, systemImage: s.ollamaOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.ollamaOK ? Color.green : Color.orange)
                    .font(.caption)
                    .lineLimit(1)
                Button { s.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Revérifier Ollama")
            }
            switch s.tab {
            case .depot: DepositPane(s: s)
            case .relecture: ReviewPane(s: s)
            case .banque: BankPane(s: s)
            case .reglages: AnnalesSettingsPane(s: s)
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }
}

// MARK: - Dépôt

struct DepositPane: View {
    @ObservedObject var s: AnnalesStore

    var body: some View {
        if let problem = setupProblem {
            VStack(alignment: .leading, spacing: 10) {
                Label(problem, systemImage: "wrench.and.screwdriver").font(.headline)
                Button("Ouvrir les réglages") { s.tab = .reglages }
            }
            .padding()
            Spacer()
        } else {
            if let warning = s.smallModelWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .font(.callout)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }
            HStack(alignment: .top, spacing: 16) {
                DeclaredForm(s: s, info: $s.declared, title: "Formulaire de dépôt")
                    .frame(width: 330)
                VStack(alignment: .leading, spacing: 10) {
                    if s.queue.isEmpty {
                        DropZone(title: "Dépose des annales, sous n'importe quelle forme",
                                 subtitle: "PDF officiel, scan, photo prise de travers (JPEG, HEIC…), Word, ODT, texte. Toolbox lit, identifie, découpe (un sujet par PDF), retranscrit en LaTeX avec ton modèle annales.cls, vérifie la crédibilité, compile, tague et range.",
                                 types: [.pdf, .image, .data]) { s.add($0) }
                    } else {
                        queueList
                    }
                }
            }
        }
    }

    private var setupProblem: String? {
        if s.config == nil { return s.configError.isEmpty ? "Choisis le dossier Annalyse." : s.configError }
        if s.bankRoot == nil { return "Choisis le dossier de la banque." }
        if !s.ollamaOK { return s.ollamaStatus }
        if s.model.isEmpty { return "Installe un modèle : par exemple « ollama pull qwen2.5vl:7b »." }
        return nil
    }

    private var queueList: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $s.selectedDeposit) {
                    ForEach(s.queue) { item in
                        HStack {
                            statusIcon(item.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(item.message.isEmpty ? subtitle(item) : item.message)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .tag(item.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .fileDrop(types: [.pdf, .image, .data]) { s.add($0) }
                HStack {
                    Button { s.add(Panels.open([.pdf, .image, .data], multiple: true)) } label: { Label("Ajouter", systemImage: "plus") }
                        .disabled(s.processing)
                    Button("Retirer les terminés") { s.queue.removeAll { $0.status == .fini } }
                        .disabled(s.processing)
                    Spacer()
                    if s.processing { ProgressView().controlSize(.small) }
                    Button { s.processAll() } label: { Label("Traiter", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.processing || !s.queue.contains { $0.status == .attente })
                }
            }
            .frame(minWidth: 280)
            depositDetail.frame(minWidth: 360)
        }
    }

    private func subtitle(_ item: DepositItem) -> String {
        switch item.status {
        case .attente: return "En attente"
        case .enCours: return item.log.last ?? "En cours…"
        case .fini: return "Terminé"
        case .erreur: return "Erreur"
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: DepositItem.Status) -> some View {
        switch status {
        case .attente: Image(systemName: "clock").foregroundStyle(.secondary)
        case .enCours: ProgressView().controlSize(.small)
        case .fini: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .erreur: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red)
        }
    }

    @ViewBuilder
    private var depositDetail: some View {
        if let item = s.queue.first(where: { $0.id == s.selectedDeposit }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.url.lastPathComponent).font(.headline)
                if !item.subjects.isEmpty {
                    ForEach(item.subjects) { out in
                        HStack {
                            Image(systemName: icon(out.fiche.etat)).foregroundStyle(color(out.fiche.etat))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(out.title)
                                Text(out.fiche.etat.label + (out.fiche.verdict.map { " · IA : \($0.label)" } ?? "")
                                     + (out.fiche.raisons.isEmpty ? "" : " · " + out.fiche.raisons.joined(separator: " ; ")))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer()
                            if let pdf = out.pdf { Button("PDF") { NSWorkspace.shared.open(pdf) } }
                            if let tex = out.tex { Button(".tex") { Editor.open(tex, line: nil) } }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
                Text("Journal").font(.subheadline.bold())
                ScrollView {
                    Text(item.log.isEmpty ? "—" : item.log.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            .padding(.leading, 8)
        } else {
            Text("Sélectionne un dépôt.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func icon(_ e: SubjectState) -> String {
        switch e {
        case .range: return "checkmark.seal.fill"
        case .aVerifier: return "eye.fill"
        case .rejete: return "hand.raised.fill"
        case .nonConverti: return "doc.fill"
        case .ignore: return "minus.circle"
        }
    }

    private func color(_ e: SubjectState) -> Color {
        switch e {
        case .range: return .green
        case .aVerifier: return .orange
        case .rejete: return .red
        default: return .secondary
        }
    }
}

/// Champs déclarés (dépôt) ou corrigés (relecture). Vide = « deviner ».
struct DeclaredForm: View {
    @ObservedObject var s: AnnalesStore
    @Binding var info: DeclaredInfo
    let title: String
    var showDepositFields = true

    static let sessions = ["", "CC1", "CC2", "CC3", "EXAM", "RATTRAPAGE", "SUBSTITUTION"]

    var body: some View {
        Form {
            Section(title) {
                Picker("Type", selection: $info.typeDocument) {
                    Text("Examen / CC").tag("")
                    Text("TD").tag("td")
                    Text("TP").tag("tp")
                    Text("Cours").tag("cours")
                }
                Picker("Établissement", selection: $info.etablissement) {
                    Text("Deviner").tag("")
                    ForEach(s.config?.etablissements ?? [], id: \.key) { Text($0.nom).tag($0.key) }
                }
                Picker("Niveau", selection: $info.niveau) {
                    Text("Deviner").tag("")
                    ForEach(AnnalesConfig.niveaux, id: \.self) { Text($0).tag($0) }
                }
                Picker("Matière", selection: $info.matiere) {
                    Text("Deviner").tag("")
                    ForEach(matieres, id: \.key) { m in Text("\(m.nom) (\(m.niveau))").tag(m.key) }
                }
                TextField("Année", text: $info.anneeUniv, prompt: Text("Deviner (ex. 2024-2025)"))
                Picker("Session", selection: $info.session) {
                    ForEach(Self.sessions, id: \.self) { Text($0.isEmpty ? "Deviner" : AnnalesMetadataDetector.sessionLabel($0)).tag($0) }
                }
                if showDepositFields {
                    TextField("Enseignant", text: $info.enseignant, prompt: Text("Facultatif"))
                    TextField("Déposé par", text: $info.deposePar, prompt: Text("Prénom"))
                }
            }
            if showDepositFields {
                Section {
                    Text("Laisse « Deviner » : Toolbox lit l'en-tête. Ce que tu déclares est comparé à ce qui est lu ; un désaccord envoie le sujet en relecture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var matieres: [MatiereRule] {
        guard let c = s.config else { return [] }
        return info.niveau.isEmpty ? c.matieres : c.matieres(of: info.niveau)
    }
}

// MARK: - Relecture

struct ReviewPane: View {
    @ObservedObject var s: AnnalesStore

    var body: some View {
        if s.reviews.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal").font(.system(size: 40, weight: .light)).foregroundStyle(Color.green)
                Text("Rien à relire.").font(.title3)
                Button("Actualiser") { s.loadReviews() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { s.loadReviews() }
        } else {
            HSplitView {
                List(selection: Binding(get: { s.selectedReview }, set: { id in s.selectReview(s.reviews.first { $0.id == id }) })) {
                    ForEach(s.reviews) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).lineLimit(1)
                            Text(r.fiche.raisons.first ?? "à relire").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(r.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minWidth: 230, idealWidth: 260)
                .onAppear { s.loadReviews() }

                if let r = s.currentReview {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let v = r.fiche.verdict {
                                        Text("IA : \(v.label)" + (r.fiche.motifs.isEmpty ? "" : " — " + r.fiche.motifs.joined(separator: " ; ")))
                                    }
                                    ForEach(r.fiche.raisons, id: \.self) { Text("• " + $0).font(.callout) }
                                    if !r.fiche.tags.isEmpty {
                                        Text("Tags : " + r.fiche.tags.sorted { $0.key < $1.key }
                                            .map { "ex.\($0.key) \($0.value.joined(separator: ", "))" }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: { Label("Pourquoi à relire", systemImage: "eye") }

                            DeclaredForm(s: s, info: $s.corrections, title: "Métadonnées (corrige si besoin)", showDepositFields: false)
                                .frame(height: 300)
                            TextField("Relu par", text: $s.reviewer).textFieldStyle(.roundedBorder)
                            HStack {
                                if let tex = r.tex { Button("Modifier le .tex") { Editor.open(tex, line: nil) } }
                                Button("Original") { NSWorkspace.shared.open(URL(fileURLWithPath: r.fiche.original)) }
                                Spacer()
                                if s.processing { ProgressView().controlSize(.small) }
                                Button { s.validateCurrent() } label: { Label("Valider et ranger", systemImage: "checkmark.seal") }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(s.processing || r.tex == nil)
                            }
                            Text("Corrige le .tex dans ton éditeur si besoin, puis valide : Toolbox recompile, remplit la relecture sur la fiche de provenance et range le sujet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 360)
                        PDFPreview(url: r.pdf, reloadToken: 0)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.leading, 8)
                } else {
                    Text("Sélectionne un sujet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Banque

struct BankPane: View {
    @ObservedObject var s: AnnalesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Rechercher dans les exercices (ex. intégrale, récursivité)", text: $s.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { s.search() }
                Picker("Niveau", selection: $s.searchNiveau) {
                    Text("Tous").tag("")
                    ForEach(AnnalesConfig.niveaux, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Picker("Matière", selection: $s.searchMatiere) {
                    Text("Toutes").tag("")
                    ForEach(s.config?.matieres ?? [], id: \.key) { Text($0.nom).tag($0.key) }
                }
                .fixedSize()
                Picker("Notion", selection: $s.searchNotion) {
                    Text("Toutes").tag("")
                    ForEach(notions, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Button("Chercher") { s.search() }.keyboardShortcut(.defaultAction)
            }
            HSplitView {
                List(s.results) { r in
                    HStack(alignment: .top, spacing: 8) {
                    Button { s.toggleCart(r.id) } label: {
                        Image(systemName: s.cart.contains(r.id) ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(s.cart.contains(r.id) ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Ajouter à / retirer du sujet d'entraînement")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(r.niveau) · \(r.matiere) · \(r.annee) · \(r.session) · exercice \(r.numero)")
                            .font(.callout.bold())
                        Text(r.extrait).font(.caption).lineLimit(3)
                        Text((r.notions.isEmpty ? "sans notion" : r.notions) + (r.statut == "valide" ? "" : (r.statut == "ia" ? " · vérifié par IA" : " · non vérifié")))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !r.pdf.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: r.pdf)) } }
                    .contextMenu {
                        Button(s.cart.contains(r.id) ? "Retirer du sujet d'entraînement" : "Ajouter au sujet d'entraînement") { s.toggleCart(r.id) }
                        Button("Ouvrir le sujet") { if !r.pdf.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: r.pdf)) } }
                            .disabled(r.pdf.isEmpty)
                        Divider()
                        Button("Supprimer ce sujet de la banque…") { s.deleteSujet(r) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minWidth: 400)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Contenu de la banque").font(.headline)
                        ForEach(Array(s.summary.enumerated()), id: \.offset) { _, row in
                            Text("\(row.niveau) · \(row.matiere) : \(row.sujets) sujet(s)" + (row.enAttente > 0 ? ", \(row.enAttente) à relire" : ""))
                                .font(.callout)
                        }
                        if let st = s.stats {
                            Divider()
                            Text("Notions qui tombent (\(st.total) sujets)").font(.headline)
                            ForEach(Array(st.rows.enumerated()), id: \.offset) { _, row in
                                HStack {
                                    Text(row.notion).frame(width: 170, alignment: .leading).lineLimit(1)
                                    GeometryReader { g in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.accentColor.opacity(0.7))
                                            .frame(width: g.size.width * CGFloat(row.sujets) / CGFloat(max(1, st.total)))
                                    }
                                    .frame(height: 10)
                                    Text("\(row.sujets)/\(st.total)").font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 260)
            }
            HStack {
                Text("Double-clic : ouvrir le sujet · ⊕ : ajouter l'exercice au sujet d'entraînement · clic droit : supprimer")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !s.cart.isEmpty {
                    Button("Vider la sélection") { s.cart = [] }.buttonStyle(.borderless)
                }
                Button { s.openCompose() } label: {
                    Label(s.cart.isEmpty ? "Composer un sujet d'entraînement…" : "Composer un sujet (\(s.cart.count) choisi(s))…",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { s.search() }
        .sheet(isPresented: $s.showCompose) { ComposeSheet(s: s) }
    }

    private var notions: [String] {
        guard let c = s.config else { return [] }
        if !s.searchMatiere.isEmpty {
            let niveau = s.searchNiveau.isEmpty ? (c.matiere(s.searchMatiere, niveau: nil)?.niveau ?? "") : s.searchNiveau
            return c.notions(niveau: niveau, matiere: s.searchMatiere).map { $0.name }
        }
        return []
    }
}

// MARK: - Réglages

struct AnnalesSettingsPane: View {
    @ObservedObject var s: AnnalesStore

    var body: some View {
        Form {
            Section("Dossiers") {
                LabeledContent("Dossier Annalyse") {
                    HStack {
                        Text(s.annalyseRoot?.path ?? "non choisi").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choisir…") { if let u = Panels.folder(directory: s.annalyseRoot) { s.annalyseRoot = u } }
                    }
                }
                if !s.configError.isEmpty {
                    Text(s.configError).font(.caption).foregroundStyle(Color.red)
                } else if let c = s.config {
                    Text("\(c.matieres.count) matière(s), \(c.etablissements.count) établissement(s) ; modèle et classe LaTeX lus dans latex/.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Banque") {
                    HStack {
                        Text(s.bankRoot?.path ?? "non choisi").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choisir…") { if let u = Panels.folder(directory: s.bankRoot ?? s.annalyseRoot) { s.bankRoot = u } }
                        Button("Vider la banque…", role: .destructive) { s.resetBank() }
                            .disabled(s.bankRoot == nil)
                    }
                }
            }
            Section("IA locale (Ollama)") {
                LabeledContent("Adresse") {
                    HStack {
                        TextField("", text: $s.ollamaHost, prompt: Text(OllamaClient.defaultHost))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { s.refreshModels() }
                        Button("Tester") { s.refreshModels() }
                    }
                }
                Label(s.ollamaStatus, systemImage: s.ollamaOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.ollamaOK ? Color.green : Color.orange)
                    .font(.caption)
                    .textSelection(.enabled)
                Picker("Modèle", selection: $s.model) {
                    if s.models.isEmpty { Text("Aucun modèle").tag("") }
                    ForEach(s.models) { Text("\($0.name) (\($0.sizeLabel))").tag($0.name) }
                }
                Toggle("Envoyer les images des pages (si le modèle sait les lire)", isOn: $s.useImages)
                Toggle("Tags des exercices par l'IA (sinon par mots-clés)", isOn: $s.aiTagging)
                Picker("Contexte", selection: $s.numCtx) {
                    Text("8 k (rapide, petits sujets)").tag(8192)
                    Text("16 k (recommandé)").tag(16384)
                    Text("32 k (longs sujets, plus de mémoire)").tag(32768)
                }
                Text("Conseils : « ollama pull qwen2.5vl:7b » lit les images et les formules ; avec 16 Go de RAM ou plus, « qwen2.5vl:32b » est nettement plus fiable. Un modèle texte seul (qwen2.5:14b…) marche aussi, à partir de l'OCR.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sortie") {
                Toggle("Compresser les PDF produits", isOn: $s.compress)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sujet d'entraînement

struct ComposeSheet: View {
    @ObservedObject var s: AnnalesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Composer un sujet d'entraînement").font(.title2.bold())
            Text("Toolbox pioche des exercices dans la banque, les assemble dans un sujet propre (classe annales, provenance de chaque exercice indiquée) et l'ouvre dans l'éditeur LaTeX.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !s.cart.isEmpty {
                Label("\(s.cart.count) exercice(s) choisi(s) à la main dans la banque, placés en premier.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            Form {
                Picker("Matière", selection: $s.composeMatiere) {
                    Text("—").tag("")
                    ForEach(s.config?.matieres ?? [], id: \.key) { Text("\($0.nom) (\($0.niveau))").tag($0.key) }
                }
                Stepper(value: $s.composeCount, in: 0...12) {
                    Text(s.composeCount == 0 ? "Aucun exercice tiré au hasard" : "\(s.composeCount) exercice(s) tiré(s) au hasard")
                }
                TextField("Titre", text: $s.composeTitle, prompt: Text("Ex. : Révisions CC — suites et limites"))
            }
            .formStyle(.grouped)
            .frame(height: 170)
            let choices = s.composeNotionChoices()
            if !choices.isEmpty {
                Text("Notions (aucune cochée = toutes)").font(.headline)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(choices, id: \.self) { n in
                            Toggle(n, isOn: Binding(
                                get: { s.composeNotions.contains(n) },
                                set: { on in if on { s.composeNotions.insert(n) } else { s.composeNotions.remove(n) } }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            HStack {
                if s.composing { ProgressView().controlSize(.small); Text("Assemblage et compilation…").foregroundStyle(.secondary) }
                Spacer()
                Button("Annuler") { s.showCompose = false }.keyboardShortcut(.cancelAction)
                Button("Composer") { s.compose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(s.composing || (s.cart.isEmpty && (s.composeMatiere.isEmpty || s.composeCount == 0)))
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Fenêtre de confirmation pour une action destructive ; renvoie true si l'utilisateur confirme.
func confirmDestructive(_ title: String, _ text: String, button: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.alertStyle = .warning
    let ok = alert.addButton(withTitle: button)
    ok.hasDestructiveAction = true
    alert.addButton(withTitle: "Annuler")
    return alert.runModal() == .alertFirstButtonReturn
}
