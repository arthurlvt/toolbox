import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - « Importer une classe ou un cours » / « Exporter » (Mes cours)

final class CourseImportStore: ObservableObject {
    static let shared = CourseImportStore()

    @Published var plan: CourseImport.Plan?
    @Published var sourceName = ""
    @Published var busy = false
    @Published var expanded = Set<UUID>()

    private var courses: CoursesStore { CoursesStore.shared }

    private var existing: [(course: Course, name: String, aliases: String)] {
        courses.courses.map { ($0, courses.name($0), courses.custom[$0.id]?.aliases ?? "") }
    }

    /// Dossier de cours : celui choisi, sinon ~/Documents/Cours (créé) pour quelqu'un qui n'en a pas encore.
    private func ensureRoot() -> URL {
        if let r = courses.root { return r }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = docs.appendingPathComponent("Cours", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        courses.root = r
        return r
    }

    // MARK: Import

    func chooseAndPlan() {
        let p = NSOpenPanel()
        p.title = L("Importer une classe ou un cours")
        p.message = L("Un .zip (export Toolbox, dossier d'un ami, téléchargement Moodle…), un .tar.gz, un .7z ou un dossier")
        p.prompt = L("Analyser")
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.zip, .archive, .folder, .gzip]
        guard p.runModal() == .OK, let u = p.url else { return }
        plan(u)
    }

    func plan(_ u: URL) {
        busy = true
        sourceName = u.lastPathComponent
        courses.status = .info(L("Ouverture et tri de") + " « \(u.lastPathComponent) »…")
        let ex = existing
        runInBackground({ try CourseImport.plan(u, existing: ex) }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let plan):
                if plan.fileCount == 0 {
                    CourseImport.cleanup(plan)
                    self.courses.status = .err(L("Aucun document trouvé dans cette archive."))
                } else {
                    self.courses.status = nil
                    self.expanded = []
                    self.plan = plan
                }
            case .failure(let e):
                self.courses.status = .err(e)
            }
        }
    }

    func cancel() {
        if let p = plan { CourseImport.cleanup(p) }
        plan = nil
    }

    func apply() {
        guard let p = plan else { return }
        let root = ensureRoot()
        busy = true
        runInBackground({ try CourseImport.apply(p, root: root) }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            CourseImport.cleanup(p)
            self.plan = nil
            switch r {
            case .success(let res):
                // nouvelles matières : on garde les autres noms donnés par l'export (pour le calendrier)
                for (g, dir) in zip(p.groups.filter { $0.target == nil && !$0.files.isEmpty }, res.newSubjects) where !g.aliases.isEmpty {
                    var c = self.courses.custom[dir.path] ?? CourseCustom()
                    c.aliases = g.aliases
                    self.courses.custom[dir.path] = c
                }
                var text = String(format: L("%lld fichier(s) importé(s)"), res.copied.count)
                if !res.newSubjects.isEmpty { text += ", " + String(format: L("%lld nouvelle(s) matière(s)"), res.newSubjects.count) }
                if res.skipped > 0 { text += ", " + String(format: L("%lld déjà présent(s)"), res.skipped) }
                self.courses.status = .ok(text + ".", files: Array(res.copied.prefix(20)))
                self.courses.scan()
            case .failure(let e):
                self.courses.status = .err(e)
            }
        }
    }

    // MARK: Export

    func export(all: Bool) {
        let list: [Course] = all ? courses.courses : (courses.selected.map { [$0] } ?? [])
        guard !list.isEmpty, let root = courses.root else { return }
        // options : notes perso, corrigés
        let alert = NSAlert()
        alert.messageText = all ? L("Exporter toute la classe") : L("Exporter") + " « \(courses.name(list[0])) »"
        alert.informativeText = L("Un .zip propre (sans fichiers de compilation) que Toolbox sait réimporter tout seul, chez toi ou chez un ami.")
        let notes = NSButton(checkboxWithTitle: L("Inclure mes notes et photos du tableau"), target: nil, action: nil)
        let corr = NSButton(checkboxWithTitle: L("Inclure les corrigés"), target: nil, action: nil)
        corr.state = .on
        notes.frame = NSRect(x: 0, y: 26, width: 320, height: 22)
        corr.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 50))
        box.addSubview(notes)
        box.addSubview(corr)
        alert.accessoryView = box
        alert.addButton(withTitle: L("Exporter…"))
        alert.addButton(withTitle: L("Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let label = all ? L("Cours") : courses.name(list[0])
        guard let out = Panels.save(suggested: "\(label) – \(f.string(from: Date())).zip", type: .zip) else { return }
        let subjects = list.map { ($0, courses.name($0), courses.custom[$0.id]?.aliases ?? "") }
        let opts = CourseImport.ExportOptions(includeNotes: notes.state == .on, includeCorrections: corr.state == .on)
        busy = true
        courses.status = .info(L("Création du .zip…"))
        runInBackground({ try CourseImport.export(subjects, root: root, to: out, options: opts) }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let n):
                self.courses.status = .ok(String(format: L("%lld fichier(s) exporté(s) dans"), n) + " « \(out.lastPathComponent) ».", files: [out])
            case .failure(let e):
                self.courses.status = .err(e)
            }
        }
    }
}

// MARK: - Aperçu avant import

struct CourseImportSheet: View {
    @ObservedObject var s = CourseImportStore.shared
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Importer « \(s.sourceName) »").font(.title3.weight(.semibold))
                    Text("Voici comment Toolbox a trié l'archive. Change la destination d'une matière si besoin : rien n'est déplacé ni écrasé, les fichiers déjà présents sont sautés.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if courses.root == nil {
                Label("Tu n'as pas encore de dossier de cours : il sera créé dans Documents/Cours.", systemImage: "folder.badge.plus")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let plan = s.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.groups.indices, id: \.self) { i in
                            groupRow(i)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 420)
                HStack {
                    Text("\(plan.fileCount) fichier(s) dans \(plan.groups.count) matière(s)")
                        .font(.caption).foregroundStyle(.secondary)
                    if plan.fromToolbox {
                        Label("Export Toolbox", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Annuler") { s.cancel() }.keyboardShortcut(.cancelAction)
                    Button("Importer") { s.apply() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(s.busy)
                }
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func binding<T>(_ i: Int, _ kp: WritableKeyPath<CourseImport.Group, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { (s.plan?.groups.indices.contains(i) ?? false) ? s.plan!.groups[i][keyPath: kp] : fallback },
                set: { v in if s.plan?.groups.indices.contains(i) == true { s.plan!.groups[i][keyPath: kp] = v } })
    }

    @ViewBuilder
    private func groupRow(_ i: Int) -> some View {
        if let g = s.plan?.groups[i] {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: g.target == nil ? "folder.badge.plus" : "folder.fill")
                        .foregroundStyle(g.target == nil ? Color.green : Color.accentColor)
                    if g.target == nil {
                        TextField("Nom de la matière", text: binding(i, \.name, ""))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    } else {
                        Text(g.name).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Picker("", selection: binding(i, \.target, nil)) {
                        Text("Nouvelle matière").tag(URL?.none)
                        Divider()
                        ForEach(courses.courses) { c in
                            Text(courses.name(c)).tag(Optional(c.url))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Text(summary(g)).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(isExpanded: Binding(get: { s.expanded.contains(g.id) },
                                                    set: { if $0 { s.expanded.insert(g.id) } else { s.expanded.remove(g.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(g.files.prefix(200).enumerated()), id: \.offset) { _, f in
                            HStack(spacing: 6) {
                                Text(L(f.kind.title)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                Text(f.relative).font(.caption).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if g.files.count > 200 {
                            Text("… et \(g.files.count - 200) autres").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    Text("Voir les fichiers").font(.caption)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private func summary(_ g: CourseImport.Group) -> String {
        let parts: [(CourseKind, String)] = [(.cours, L("cours")), (.td, "TD"), (.tp, "TP"), (.cc, "CC"), (.notes, L("notes")), (.autre, L("autres"))]
        return parts.compactMap { k, label in
            let n = g.count(k)
            return n > 0 ? "\(n) \(label)" : nil
        }.joined(separator: " · ")
    }
}
