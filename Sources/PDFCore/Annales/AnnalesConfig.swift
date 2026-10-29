import Foundation

public struct Etablissement {
    public let key: String
    public let nom: String
    public let motifs: [String]
}

public struct MatiereRule {
    public let key: String          // "analyse1"
    public let niveau: String       // "L1"
    public let nom: String          // "Analyse 1"
    public let titres: [String]
    public let mots: [String]
}

public struct NotionRule {
    public let name: String
    public let mots: [String]
}

/// Configuration lue dans le dossier Annalyse (config/ et latex/), exactement
/// les mêmes fichiers que la version Python : on les modifie sans toucher au code.
public struct AnnalesConfig {
    public static let niveaux = ["L1", "L2", "L3", "M1", "M2"]

    public let root: URL
    public var defaultEtablissement: String?
    public var etablissements: [Etablissement] = []
    public var matieres: [MatiereRule] = []                    // tous niveaux confondus
    public var notions: [String: [String: [NotionRule]]] = [:]  // niveau → matière → notions

    public var templateURL: URL { root.appendingPathComponent("latex/modele_annale.tex") }
    public var classURL: URL { root.appendingPathComponent("latex/annales.cls") }
    public var latexFolder: URL { root.appendingPathComponent("latex") }

    public init(root: URL) {
        self.root = root
    }

    public static func load(root: URL) throws -> AnnalesConfig {
        var c = AnnalesConfig(root: root)
        let configDir = root.appendingPathComponent("config")
        let fm = FileManager.default
        guard fm.fileExists(atPath: configDir.path) else {
            throw PDFToolError.toolMissing("dossier « config » introuvable dans \(root.path)")
        }

        let etabURL = configDir.appendingPathComponent("etablissements.yaml")
        if fm.fileExists(atPath: etabURL.path) {
            let y = try MiniYAML.load(etabURL)
            c.defaultEtablissement = y["defaut"]?.string
            for (key, value) in y["etablissements"]?.pairs ?? [] {
                c.etablissements.append(Etablissement(key: key, nom: value["nom"]?.string ?? key,
                                                      motifs: value["motifs"]?.strings ?? []))
            }
        }

        for niveau in niveaux {
            let dir = configDir.appendingPathComponent(niveau)
            let mURL = dir.appendingPathComponent("matieres.yaml")
            if fm.fileExists(atPath: mURL.path) {
                for (key, rules) in try MiniYAML.load(mURL).pairs {
                    let titres = rules["titres"]?.strings ?? []
                    let nom = rules["nom"]?.string ?? prettyName(titres.first ?? key)
                    c.matieres.append(MatiereRule(key: key, niveau: niveau, nom: nom,
                                                  titres: titres, mots: rules["mots"]?.strings ?? []))
                }
            }
            let nURL = dir.appendingPathComponent("notions.yaml")
            if fm.fileExists(atPath: nURL.path) {
                var byMatiere: [String: [NotionRule]] = [:]
                for (matiere, notions) in try MiniYAML.load(nURL).pairs {
                    byMatiere[matiere] = notions.pairs.map { NotionRule(name: $0.key, mots: $0.value.strings) }
                }
                c.notions[niveau] = byMatiere
            }
        }
        return c
    }

    static func prettyName(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: Accès

    public func matieres(of niveau: String) -> [MatiereRule] { matieres.filter { $0.niveau == niveau } }

    public func matiere(_ key: String?, niveau: String?) -> MatiereRule? {
        guard let key = key else { return nil }
        return matieres.first { $0.key == key && (niveau == nil || $0.niveau == niveau) }
            ?? matieres.first { $0.key == key }
    }

    public func etablissement(_ key: String?) -> Etablissement? {
        guard let key = key else { return nil }
        return etablissements.first { $0.key == key }
    }

    public func notions(niveau: String?, matiere: String?) -> [NotionRule] {
        guard let n = niveau, let m = matiere else { return [] }
        return notions[n]?[m] ?? []
    }

    /// Ajoute une notion (sans mot-clé) au fichier notions.yaml en gardant les commentaires.
    public func ajouterNotion(niveau: String, matiere: String, notion: String) throws {
        let url = root.appendingPathComponent("config/\(niveau)/notions.yaml")
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        while lines.last == "" { lines.removeLast() }
        if !lines.contains("\(matiere):") {
            lines = lines.filter { $0.trimmingCharacters(in: .whitespaces) != "{}" } + ["", "\(matiere):"]
        }
        guard let start = lines.firstIndex(of: "\(matiere):") else { return }
        var end = start + 1
        while end < lines.count && (lines[end].hasPrefix(" ") || lines[end].trimmingCharacters(in: .whitespaces).isEmpty) {
            end += 1
        }
        while end > start + 1 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        lines.insert("  \(notion): []          # ajoutée dans Toolbox : mots-clés à compléter", at: end)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
