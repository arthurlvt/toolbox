import Foundation

// MARK: - Moodle : devoirs (dates limites, dépôts) et annonces des cours

extension Moodle {

    /// Booléen tolérant : Moodle renvoie selon les versions true/false, 0/1 ou "0"/"1".
    public struct Flag: Decodable, Hashable {
        public let value: Bool
        public init(_ v: Bool) { value = v }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { value = b }
            else if let i = try? c.decode(Int.self) { value = i != 0 }
            else if let s = try? c.decode(String.self) { value = s == "1" || s.lowercased() == "true" }
            else { value = false }
        }
    }

    // MARK: Devoirs

    public struct AssignConfig: Decodable, Hashable {
        public let plugin: String?
        public let subtype: String?
        public let name: String?
        public let value: String?
    }

    public struct Assignment: Decodable, Identifiable, Hashable {
        public let id: Int
        public let cmid: Int
        public let course: Int
        public let name: String
        public let duedate: Int?
        public let cutoffdate: Int?
        public let allowsubmissionsfromdate: Int?
        public let nosubmissions: Int?
        public let submissiondrafts: Int?
        public let requiresubmissionstatement: Int?
        public let intro: String?
        public let configs: [AssignConfig]?

        public init(id: Int, cmid: Int, course: Int, name: String, duedate: Int?, cutoffdate: Int? = nil,
                    allowsubmissionsfromdate: Int? = nil, nosubmissions: Int? = 0, submissiondrafts: Int? = 0,
                    requiresubmissionstatement: Int? = 0, intro: String? = nil, configs: [AssignConfig]? = nil) {
            self.id = id; self.cmid = cmid; self.course = course; self.name = name; self.duedate = duedate
            self.cutoffdate = cutoffdate; self.allowsubmissionsfromdate = allowsubmissionsfromdate
            self.nosubmissions = nosubmissions; self.submissiondrafts = submissiondrafts
            self.requiresubmissionstatement = requiresubmissionstatement; self.intro = intro; self.configs = configs
        }

        func config(_ plugin: String, _ name: String) -> String? {
            configs?.first { $0.plugin == plugin && $0.subtype == "assignsubmission" && $0.name == name }?.value
        }
        /// Le devoir se rend par fichiers (sinon : texte en ligne, papier…).
        public var acceptsFiles: Bool { nosubmissions != 1 && config("file", "enabled") == "1" }
        public var maxFiles: Int { Int(config("file", "maxfilesubmissions") ?? "") ?? 1 }
        public var maxBytes: Int { Int(config("file", "maxsubmissionsizebytes") ?? "") ?? 0 }
        /// Types acceptés, tels que Moodle les donne (« .pdf,.zip », « document »…), vide = tout.
        public var fileTypes: String { config("file", "filetypeslist") ?? "" }
        /// Il faut cliquer « Envoyer le devoir » après le dépôt.
        public var needsSubmitButton: Bool { submissiondrafts == 1 }
        public var due: Date? { (duedate ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(duedate!)) : nil }
        public var cutoff: Date? { (cutoffdate ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(cutoffdate!)) : nil }

        /// L'extension du fichier est-elle acceptée ? (vérification simple ; Moodle tranche de toute façon)
        public func accepts(fileName: String) -> Bool {
            let list = fileTypes.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let exts = list.filter { $0.hasPrefix(".") }
            // groupes (« document », « image »…) : on laisse Moodle décider
            guard !list.isEmpty, exts.count == list.count else { return true }
            let ext = "." + (fileName as NSString).pathExtension.lowercased()
            return exts.contains(ext)
        }
    }

    public struct AssignCourses: Decodable {
        public struct C: Decodable { public let id: Int; public let assignments: [Assignment] }
        public let courses: [C]
    }

    public struct SubmittedFile: Decodable, Hashable {
        public let filename: String?
        public let filesize: Int?
        public let fileurl: String?
        public let timemodified: Int?
    }

    public struct Submission: Decodable, Hashable {
        public struct FileArea: Decodable, Hashable { public let area: String?; public let files: [SubmittedFile]? }
        public struct Plugin: Decodable, Hashable { public let type: String?; public let fileareas: [FileArea]? }
        public let id: Int?
        public let status: String?
        public let timemodified: Int?
        public let plugins: [Plugin]?

        public var files: [SubmittedFile] {
            (plugins ?? []).filter { $0.type == "file" }.flatMap { $0.fileareas ?? [] }.flatMap { $0.files ?? [] }
                .filter { ($0.filename ?? ".") != "." }
        }
    }

    public struct SubmissionStatus: Decodable, Hashable {
        public struct Attempt: Decodable, Hashable {
            public let submission: Submission?
            public let teamsubmission: Submission?
            public let locked: Flag?
            public let graded: Flag?
            public let canedit: Flag?
            public let caneditowner: Flag?
            public let cansubmit: Flag?
            public let extensionduedate: Int?
            public let gradingstatus: String?
        }
        public let lastattempt: Attempt?

        public init(lastattempt: Attempt?) { self.lastattempt = lastattempt }

        public var submission: Submission? { lastattempt?.teamsubmission ?? lastattempt?.submission }
        /// « new », « draft », « submitted », « reopened »
        public var state: String { submission?.status ?? "new" }
        public var files: [SubmittedFile] { submission?.files ?? [] }
        /// Rendu pour de bon (envoyé, ou déposé sur un devoir sans bouton « Envoyer »).
        public func isDone(_ a: Assignment) -> Bool {
            state == "submitted" || (!a.needsSubmitButton && !files.isEmpty)
        }
        public var canEdit: Bool { (lastattempt?.canedit?.value ?? true) && !(lastattempt?.locked?.value ?? false) }
        public var canSubmit: Bool { lastattempt?.cansubmit?.value ?? false }
        public var extension_: Date? {
            guard let e = lastattempt?.extensionduedate, e > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(e))
        }
    }

    public struct Warning: Decodable { public let message: String?; public let warningcode: String? }

    // MARK: Notes

    public struct GradeItem: Decodable, Hashable {
        public let id: Int
        public let itemname: String?
        public let itemtype: String?
        public let graderaw: Double?
        public let gradeformatted: String?
        public let grademax: Double?
        public let gradedategraded: Int?
        public let gradehiddenbydate: Flag?
        public let gradeishidden: Flag?

        public init(id: Int, itemname: String?, itemtype: String?, graderaw: Double?, gradeformatted: String?, grademax: Double?,
                    gradedategraded: Int? = nil, gradehiddenbydate: Flag? = nil, gradeishidden: Flag? = nil) {
            self.id = id; self.itemname = itemname; self.itemtype = itemtype; self.graderaw = graderaw
            self.gradeformatted = gradeformatted; self.grademax = grademax; self.gradedategraded = gradedategraded
            self.gradehiddenbydate = gradehiddenbydate; self.gradeishidden = gradeishidden
        }

        /// Une vraie note d'épreuve, publiée (pas le total du cours ni d'une catégorie).
        public var isPublished: Bool {
            graderaw != nil && itemtype != "course" && itemtype != "category"
                && gradehiddenbydate?.value != true && gradeishidden?.value != true
        }

        /// Clé qui change si la note change (correction, rattrapage).
        public var key: String { "\(id)|\(graderaw.map { String($0) } ?? "")|\(gradedategraded ?? 0)" }

        static func number(_ x: Double) -> String {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.maximumFractionDigits = 2
            f.minimumFractionDigits = 0
            return f.string(from: NSNumber(value: x)) ?? String(x)
        }

        /// « 13,5/20 » (ou ce que Moodle affiche : lettre, pourcentage…)
        public var text: String {
            let shown = (gradeformatted ?? "").trimmingCharacters(in: .whitespaces)
            if let raw = graderaw, let max = grademax, max > 0, shown.isEmpty || shown == "-" || Double(shown.replacingOccurrences(of: ",", with: ".")) != nil {
                return Self.number(raw) + "/" + Self.number(max)
            }
            if !shown.isEmpty && shown != "-" { return shown }
            return graderaw.map(Self.number) ?? "?"
        }
    }

    struct GradeReport: Decodable {
        struct User: Decodable { let gradeitems: [GradeItem]? }
        let usergrades: [User]
    }

    // MARK: Annonces

    public struct Forum: Decodable, Hashable {
        public let id: Int
        public let course: Int
        public let type: String?
        public let name: String?
    }

    public struct Discussion: Decodable, Hashable, Identifiable {
        public let id: Int                 // premier message
        public let discussion: Int?        // la discussion
        public let name: String?
        public let subject: String?
        public let message: String?
        public let userfullname: String?
        public let timemodified: Int?
        public let created: Int?

        public init(id: Int, discussion: Int?, name: String?, subject: String?, message: String?, userfullname: String?,
                    timemodified: Int?, created: Int?) {
            self.id = id; self.discussion = discussion; self.name = name; self.subject = subject; self.message = message
            self.userfullname = userfullname; self.timemodified = timemodified; self.created = created
        }

        public var key: Int { discussion ?? id }
        public var title: String { (subject?.isEmpty == false ? subject : name) ?? "" }
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(created ?? timemodified ?? 0)) }
    }

    struct Discussions: Decodable { let discussions: [Discussion] }

    /// HTML d'un message Moodle → texte lisible.
    public static func plainText(_ html: String) -> String {
        var s = html
        for (p, r) in [(#"(?i)<br\s*/?>"#, "\n"), (#"(?i)</(p|div|li|h[1-6]|tr)>"#, "\n"), (#"(?i)<li[^>]*>"#, "• "),
                       (#"(?is)<(script|style)[^>]*>.*?</\1>"#, ""), (#"<[^>]+>"#, "")] {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                        "&rsquo;": "’", "&lsquo;": "‘", "&laquo;": "«", "&raquo;": "»", "&eacute;": "é", "&egrave;": "è",
                        "&agrave;": "à", "&ccedil;": "ç", "&hellip;": "…", "&ndash;": "–", "&mdash;": "—"]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        // entités numériques &#233; &#x2019;
        while let r = s.range(of: #"&#(x?[0-9A-Fa-f]+);"#, options: .regularExpression) {
            var code = String(s[r].dropFirst(2).dropLast())
            let hex = code.hasPrefix("x") || code.hasPrefix("X")
            if hex { code.removeFirst() }
            let ch = UInt32(code, radix: hex ? 16 : 10).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            s.replaceSubrange(r, with: ch)
        }
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Moodle.Client {

    static func indexed(_ name: String, _ ids: [Int]) -> [String: String] {
        var p: [String: String] = [:]
        for (i, id) in ids.enumerated() { p["\(name)[\(i)]"] = String(id) }
        return p
    }

    // MARK: Devoirs

    public func assignments(courses: [Int]) throws -> [Moodle.Assignment] {
        guard !courses.isEmpty else { return [] }
        let r: Moodle.AssignCourses = try call("mod_assign_get_assignments", Self.indexed("courseids", courses))
        return r.courses.flatMap { $0.assignments }
    }

    public func submissionStatus(assign: Int) throws -> Moodle.SubmissionStatus {
        try call("mod_assign_get_submission_status", ["assignid": String(assign)])
    }

    /// Envoie des fichiers dans une zone brouillon ; renvoie son numéro (itemid).
    public func uploadDraft(_ files: [URL]) throws -> Int {
        var itemid = 0
        for f in files {
            let boundary = "toolbox-" + UUID().uuidString
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("token", token)
            field("filearea", "draft")
            field("itemid", String(itemid))
            let fname = f.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_1\"; filename=\"\(fname)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(try Data(contentsOf: f))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var req = URLRequest(url: root.appendingPathComponent("webservice/upload.php"))
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let data = try Moodle.fetch(req, timeout: 300)
            struct Up: Decodable { let itemid: Int?; let filename: String? }
            struct UpErr: Decodable { let error: String?; let errorcode: String? }
            if let list = try? JSONDecoder().decode([Up].self, from: data), let id = list.first?.itemid {
                itemid = id
            } else if let e = try? JSONDecoder().decode(UpErr.self, from: data) {
                throw MoodleError(e.error ?? e.errorcode ?? "Envoi refusé par Moodle.")
            } else {
                throw MoodleError("Envoi refusé par Moodle : \(f.lastPathComponent)")
            }
        }
        return itemid
    }

    private func checkWarnings(_ w: [Moodle.Warning]) throws {
        if let first = w.first { throw MoodleError(first.message ?? first.warningcode ?? "Moodle a refusé l'opération.") }
    }

    /// Remplace les fichiers du dépôt par ceux de la zone brouillon `draft` (zone vide = dépôt vidé).
    public func saveSubmission(assign: Int, draft: Int) throws {
        let w: [Moodle.Warning] = try call("mod_assign_save_submission",
                                           ["assignmentid": String(assign), "plugindata[files_filemanager]": String(draft)])
        try checkWarnings(w)
    }

    /// « Envoyer le devoir » : définitif, on ne peut plus modifier ensuite (sauf si le prof rouvre).
    public func submitForGrading(assign: Int) throws {
        let w: [Moodle.Warning] = try call("mod_assign_submit_for_grading",
                                           ["assignmentid": String(assign), "acceptsubmissionstatement": "1"])
        try checkWarnings(w)
    }

    /// Retire le dépôt (brouillon ou rendu modifiable).
    public func removeSubmission(assign: Int, user: Int) throws {
        struct R: Decodable { let status: Moodle.Flag?; let warnings: [Moodle.Warning]? }
        do {
            let r: R = try call("mod_assign_remove_submission", ["userid": String(user), "assignid": String(assign)])
            try checkWarnings(r.warnings ?? [])
            if r.status?.value == false { throw MoodleError("Moodle n'a pas pu retirer le dépôt.") }
        } catch let first {
            if (first as? MoodleError)?.text.contains("expirée") == true { throw first }
            // Moodle sans cette fonction : dépôt remplacé par une zone vide
            struct Draft: Decodable { let itemid: Int }
            do {
                let d: Draft = try call("core_files_get_unused_draft_itemid")
                try saveSubmission(assign: assign, draft: d.itemid)
            } catch {
                throw first
            }
        }
    }

    // MARK: Notes

    public func gradeItems(course: Int, user: Int) throws -> [Moodle.GradeItem] {
        let r: Moodle.GradeReport = try call("gradereport_user_get_grade_items", ["courseid": String(course), "userid": String(user)])
        return r.usergrades.flatMap { $0.gradeitems ?? [] }
    }

    // MARK: Annonces

    public func forums(courses: [Int]) throws -> [Moodle.Forum] {
        guard !courses.isEmpty else { return [] }
        return try call("mod_forum_get_forums_by_courses", Self.indexed("courseids", courses))
    }

    public func discussions(forum: Int, count: Int = 8) throws -> [Moodle.Discussion] {
        do {
            let r: Moodle.Discussions = try call("mod_forum_get_forum_discussions",
                                                 ["forumid": String(forum), "page": "0", "perpage": String(count)])
            return r.discussions
        } catch {
            let r: Moodle.Discussions = try call("mod_forum_get_forum_discussions_paginated",
                                                 ["forumid": String(forum), "sortby": "timemodified", "sortdirection": "DESC",
                                                  "page": "0", "perpage": String(count)])
            return r.discussions
        }
    }
}
