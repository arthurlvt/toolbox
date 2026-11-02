import SwiftUI
import AppKit

// MARK: - Documents administratifs (modèle LaTeX « Administratif »)
//
// Les informations personnelles sont saisies une seule fois (Réglages → Général → Mes informations,
// ou dans la feuille « Nouveau document ») et restent sur le Mac, dans les préférences de l'app
// (donc dans les sauvegardes du profil). Elles ne sont jamais écrites dans le code.

/// Mes informations, telles qu'elles apparaissent sur un courrier.
struct AdminFields {
    var name = ""
    var address = ""        // une ou plusieurs lignes
    var cityLine = ""       // « 13660 Orgon »
    var phone = ""
    var email = ""
    var birthDate = ""
    var birthPlace = ""
    var studentID = ""
    var school = ""         // « Avignon Université – CERI, Licence 1 Informatique »

    /// « 13660 Orgon » → « Orgon »
    var city: String {
        let t = cityLine.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].allSatisfy({ $0.isNumber }) { return String(parts[1]) }
        return t
    }
    var isEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }
}

final class AdminInfo: ObservableObject {
    static let shared = AdminInfo()
    private let d = UserDefaults.standard

    @Published var name: String { didSet { d.set(name, forKey: "admin.name") } }
    @Published var address: String { didSet { d.set(address, forKey: "admin.address") } }
    @Published var cityLine: String { didSet { d.set(cityLine, forKey: "admin.city") } }
    @Published var phone: String { didSet { d.set(phone, forKey: "admin.phone") } }
    @Published var email: String { didSet { d.set(email, forKey: "admin.email") } }
    @Published var birthDate: String { didSet { d.set(birthDate, forKey: "admin.birthDate") } }
    @Published var birthPlace: String { didSet { d.set(birthPlace, forKey: "admin.birthPlace") } }
    @Published var studentID: String { didSet { d.set(studentID, forKey: "admin.studentID") } }
    @Published var school: String { didSet { d.set(school, forKey: "admin.school") } }

    init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "admin.name") ?? ""
        address = d.string(forKey: "admin.address") ?? ""
        cityLine = d.string(forKey: "admin.city") ?? ""
        phone = d.string(forKey: "admin.phone") ?? ""
        email = d.string(forKey: "admin.email") ?? ""
        birthDate = d.string(forKey: "admin.birthDate") ?? ""
        birthPlace = d.string(forKey: "admin.birthPlace") ?? ""
        studentID = d.string(forKey: "admin.studentID") ?? ""
        school = d.string(forKey: "admin.school") ?? ""
    }

    var fields: AdminFields {
        AdminFields(name: name, address: address, cityLine: cityLine, phone: phone, email: email,
                    birthDate: birthDate, birthPlace: birthPlace, studentID: studentID, school: school)
    }

    /// Dernière signature enregistrée dans l'outil Signer (PNG transparent).
    static var latestSignature: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: SignStore.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }
}

enum AdminType: String, CaseIterable, Identifiable {
    case lettre, demande, attestation, procuration, resiliation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lettre: return "Courrier"
        case .demande: return "Demande à la fac"
        case .attestation: return "Attestation sur l'honneur"
        case .procuration: return "Procuration"
        case .resiliation: return "Résiliation"
        }
    }

    var objectPrompt: String {
        switch self {
        case .lettre: return "Ex. : Demande de remboursement"
        case .demande: return "Ex. : Demande de relevé de notes"
        case .attestation: return "Ex. : ne pas percevoir d'autre bourse"
        case .procuration: return "Ex. : retirer mon colis à La Poste"
        case .resiliation: return "Ex. : abonnement salle de sport, contrat n° 12345"
        }
    }

    var objectLabel: String {
        switch self {
        case .attestation: return "J'atteste que…"
        case .procuration: return "Pour…"
        case .resiliation: return "Contrat"
        default: return "Objet"
        }
    }

    var needsRecipient: Bool { self != .attestation && self != .procuration }
}

// MARK: - Champs « Mes informations »

struct AdminInfoFields: View {
    @ObservedObject var i = AdminInfo.shared

    var body: some View {
        TextField("Prénom et nom", text: $i.name, prompt: Text("Ex. : Camille Martin"))
        TextField("Adresse", text: $i.address, prompt: Text("N° et rue (Entrée pour une 2e ligne)"), axis: .vertical)
            .lineLimit(1...3)
        TextField("Code postal et ville", text: $i.cityLine, prompt: Text("Ex. : 84000 Avignon"))
        TextField("Téléphone", text: $i.phone)
        TextField("E-mail", text: $i.email)
        TextField("Date de naissance", text: $i.birthDate, prompt: Text("Ex. : 1er janvier 2006 (attestations, procurations)"))
        TextField("Lieu de naissance", text: $i.birthPlace)
        TextField("N° étudiant", text: $i.studentID, prompt: Text("Facultatif"))
        TextField("Établissement et formation", text: $i.school, prompt: Text("Ex. : Avignon Université – Licence 1 Informatique"))
    }
}

struct AdminInfoSettings: View {
    var body: some View {
        Section("Mes informations (documents administratifs)") {
            Text("Utilisées pour pré-remplir les courriers, attestations et procurations du modèle LaTeX « Administratif ». Elles restent sur ce Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            AdminInfoFields()
        }
    }
}

// MARK: - Modèle

extension LatexDocTemplates {
    /// Une ligne LaTeX par ligne saisie (adresse sur plusieurs lignes).
    static func lines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines).map { esc($0) }.filter { !$0.isEmpty }
    }

    static func admin(_ v: Values) -> String {
        let me = v.me
        let type = AdminType(rawValue: v.adminType) ?? .lettre
        let name = esc(me.name.isEmpty ? "Prénom Nom" : me.name)
        let city = esc(me.city.isEmpty ? "Ville" : me.city)
        let objet = esc(v.theme)
        let todo = "\\textcolor{red}{[À compléter]}"

        // bloc expéditeur
        var sender = ["\\textbf{\\monnom}"]
        sender += lines(me.address)
        if !me.cityLine.isEmpty { sender.append(esc(me.cityLine)) }
        if !me.phone.isEmpty { sender.append("Tél. : " + esc(me.phone)) }
        if !me.email.isEmpty { sender.append(esc(me.email)) }
        if !me.studentID.isEmpty, type == .demande || type == .lettre { sender.append("N° étudiant : " + esc(me.studentID)) }

        var recipientLines = lines(v.recipient)
        if recipientLines.isEmpty, type == .demande {
            recipientLines = ["Service de la scolarité"] + (me.school.isEmpty ? [] : [esc(me.school)])
        }
        if recipientLines.isEmpty { recipientLines = ["Destinataire", "Adresse", "Code postal Ville"] }

        let born = [me.birthDate.isEmpty ? "" : "né(e) le " + esc(me.birthDate),
                    me.birthPlace.isEmpty ? "" : "à " + esc(me.birthPlace)].filter { !$0.isEmpty }.joined(separator: " ")
        let living = (lines(me.address) + (me.cityLine.isEmpty ? [] : [esc(me.cityLine)])).joined(separator: ", ")
        let identity = "Je soussigné(e) \\textbf{\\monnom}"
            + (born.isEmpty ? "" : ", " + born)
            + (living.isEmpty ? "" : ", demeurant " + living)

        let signature = v.signature
            ? "\\includegraphics[height=1.8cm]{signature.png}\\\\"
            : "\\vspace{1.8cm}"

        let letterHead = #"""
        \noindent\begin{minipage}[t]{0.55\linewidth}
        \#(sender.joined(separator: "\\\\\n"))
        \end{minipage}

        \vspace{1.2cm}
        \hfill\begin{minipage}[t]{0.45\linewidth}
        \#(recipientLines.joined(separator: "\\\\\n"))
        \end{minipage}

        \vspace{1cm}
        \hfill \maville, le \today
        """#

        let closing = #"""
        \vspace{1cm}
        \hfill\begin{minipage}{0.42\linewidth}\centering
        \#(signature)
        \monnom
        \end{minipage}
        """#

        let body: String
        switch type {
        case .lettre, .demande:
            let intro = type == .demande
                ? "Actuellement inscrit(e)\(me.school.isEmpty ? "" : " en " + esc(me.school))\(me.studentID.isEmpty ? "" : " (n° étudiant " + esc(me.studentID) + ")"), je me permets de vous solliciter afin de \(todo)."
                : "Je me permets de vous écrire afin de \(todo)."
            body = #"""
            \#(letterHead)

            \vspace{0.8cm}
            \textbf{Objet :} \#(objet.isEmpty ? todo : objet)

            \vspace{0.6cm}
            Madame, Monsieur,

            % ↓ Ton texte
            \#(intro)

            \#(todo)

            Je vous remercie par avance de l'attention que vous porterez à ma demande et reste à votre disposition pour tout complément d'information.

            Je vous prie d'agréer, Madame, Monsieur, l'expression de mes salutations distinguées.

            \#(closing)
            """#
        case .resiliation:
            body = #"""
            \#(letterHead)

            \vspace{0.6cm}
            \textbf{Lettre recommandée avec accusé de réception}

            \textbf{Objet :} Résiliation -- \#(objet.isEmpty ? todo : objet)

            \vspace{0.6cm}
            Madame, Monsieur,

            % ↓ Ton texte
            Par la présente, je vous informe de ma décision de résilier le contrat cité en objet, à compter du \#(todo) (ou à la prochaine échéance prévue par le contrat).

            Je vous remercie de bien vouloir m'adresser une confirmation écrite de cette résiliation, ainsi que le solde de tout compte le cas échéant.

            Je vous prie d'agréer, Madame, Monsieur, l'expression de mes salutations distinguées.

            \#(closing)
            """#
        case .attestation:
            body = #"""
            \begin{center}
              {\Large\bfseries ATTESTATION SUR L'HONNEUR\par}
            \end{center}
            \vspace{1cm}

            % ↓ Ton texte
            \#(identity), atteste sur l'honneur \#(objet.isEmpty ? todo : objet).

            Fait pour servir et valoir ce que de droit.

            \vspace{0.8cm}
            Fait à \maville, le \today.

            \#(closing)
            """#
        case .procuration:
            let mandataire = esc(v.mandataire)
            body = #"""
            \begin{center}
              {\Large\bfseries PROCURATION\par}
            \end{center}
            \vspace{1cm}

            % ↓ Ton texte
            \#(identity), donne procuration à \textbf{\#(mandataire.isEmpty ? todo : mandataire)}, né(e) le \#(todo), demeurant \#(todo), pour \#(objet.isEmpty ? todo : objet) en mon nom.

            Le mandataire devra présenter sa pièce d'identité ainsi qu'une copie de la mienne.

            \vspace{0.8cm}
            Fait à \maville, le \today.

            \vspace{0.6cm}
            \noindent\begin{minipage}[t]{0.45\linewidth}\centering
            Le mandataire\\
            \textit{« Bon pour acceptation »}\\[2cm]
            \#(mandataire.isEmpty ? "" : mandataire)
            \end{minipage}\hfill
            \begin{minipage}[t]{0.45\linewidth}\centering
            Le mandant\\
            \textit{« Bon pour pouvoir »}\\[0.3cm]
            \#(v.signature ? "\\includegraphics[height=1.6cm]{signature.png}\\\\" : "\\rule{0pt}{1.7cm}\\\\")
            \monnom
            \end{minipage}
            """#
        }

        return #"""
        % \#(type.title) -- créé le \#(today) avec Toolbox
        % Tes informations viennent de Réglages → Général → Mes informations.
        \documentclass[11pt,a4paper]{article}
        \usepackage{iftex}
        \ifPDFTeX
          \usepackage[utf8]{inputenc}
          \usepackage[T1]{fontenc}
          \usepackage{lmodern}
        \else
          \usepackage{fontspec}
        \fi
        \usepackage[french]{babel}
        \usepackage[margin=2.5cm]{geometry}
        \usepackage{xcolor}
        \usepackage{graphicx}
        \usepackage[hidelinks]{hyperref}
        \pagestyle{empty}
        \setlength{\parindent}{0pt}
        \setlength{\parskip}{0.8em}

        \newcommand{\monnom}{\#(name)}
        \newcommand{\maville}{\#(city)}

        \hypersetup{pdftitle={\#(esc(v.fullTitle))}, pdfauthor={\#(name)}}

        \begin{document}

        \#(body)

        \end{document}
        """#
    }
}
