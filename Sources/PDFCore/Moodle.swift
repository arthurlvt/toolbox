import Foundation

// MARK: - Moodle (accès « application mobile »)
//
// Ce que fait l'appli Moodle officielle, en plus petit : configuration publique du site (sans connexion),
// jeton obtenu par la page de connexion de l'ENT, puis l'API REST (liste des cours, contenu, fichiers).
// Le jeton remplace le mot de passe : Toolbox ne voit jamais ce dernier.

public struct MoodleError: LocalizedError {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var errorDescription: String? { text }
}

public enum Moodle {

    // MARK: Site

    public struct Site: Decodable {
        public let wwwroot: String
        public let sitename: String?
        public let enablewebservices: Int?
        public let enablemobilewebservice: Int?
        public let typeoflogin: Int?
        public let launchurl: String?
    }

    struct AjaxResponse<T: Decodable>: Decodable {
        let error: Bool
        let data: T?
        let exception: AjaxException?
    }
    struct AjaxException: Decodable { let message: String? }

    /// Configuration publique (sans connexion) : vraie adresse du site de l'année, type de connexion…
    public static func publicConfig(_ base: URL) throws -> Site {
        var c = URLComponents(url: base.appendingPathComponent("lib/ajax/service-nologin.php"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "info", value: "tool_mobile_get_public_config")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = #"[{"index":0,"methodname":"tool_mobile_get_public_config","args":{}}]"#.data(using: .utf8)
        let data = try fetch(req)
        guard let list = try? JSONDecoder().decode([AjaxResponse<Site>].self, from: data), let first = list.first else {
            throw MoodleError("Réponse inattendue du site : est-ce bien un Moodle ?")
        }
        guard !first.error, let site = first.data else {
            throw MoodleError(first.exception?.message ?? "Le site refuse la configuration publique.")
        }
        guard site.enablewebservices == 1, site.enablemobilewebservice == 1 else {
            throw MoodleError("Ce Moodle n'autorise pas l'accès « application mobile » : la synchronisation est impossible.")
        }
        return site
    }

    /// Page de connexion (ENT) qui renverra le jeton vers moodlemobile://token=…
    public static func launchURL(site: Site, passport: String) -> URL? {
        let root = site.launchurl ?? (site.wwwroot + "/admin/tool/mobile/launch.php")
        var c = URLComponents(string: root)
        c?.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"),
                         URLQueryItem(name: "passport", value: passport),
                         URLQueryItem(name: "urlscheme", value: "moodlemobile")]
        return c?.url
    }

    /// « moodlemobile://token=BASE64 » → jeton. Le contenu décodé est « signature:::jeton[:::jeton privé] ».
    public static func token(fromRedirect url: URL) -> String? {
        let s = url.absoluteString
        guard let r = s.range(of: "token=") else { return nil }
        var b64 = String(s[r.upperBound...])
        if let amp = b64.firstIndex(of: "&") { b64 = String(b64[..<amp]) }
        b64 = b64.removingPercentEncoding ?? b64
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), let decoded = String(data: d, encoding: .utf8) else { return nil }
        let parts = decoded.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    // MARK: API

    public struct SiteInfo: Decodable {
        public let userid: Int
        public let fullname: String
        public let sitename: String
    }

    public struct Course: Decodable, Identifiable, Hashable {
        public let id: Int
        public let fullname: String
        public let shortname: String
        public let visible: Int?
        public let enddate: Int?
    }

    public struct Section: Decodable {
        public let id: Int
        public let name: String
        public let modules: [Module]
    }

    public struct Module: Decodable {
        public let id: Int
        public let name: String
        public let modname: String
        public let contents: [Content]?
    }

    public struct Content: Decodable {
        public let type: String
        public let filename: String
        public let filepath: String?
        public let filesize: Int?
        public let fileurl: String?
        public let timemodified: Int?
        public let mimetype: String?
    }

    struct APIError: Decodable {
        let exception: String?
        let errorcode: String?
        let message: String?
    }

    public struct Client {
        public let root: URL            // wwwroot (e-uapv2026…)
        public let token: String

        public init(root: URL, token: String) { self.root = root; self.token = token }

        func call<T: Decodable>(_ function: String, _ params: [String: String] = [:]) throws -> T {
            var req = URLRequest(url: root.appendingPathComponent("webservice/rest/server.php"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var all = params
            all["wstoken"] = token
            all["wsfunction"] = function
            all["moodlewsrestformat"] = "json"
            req.httpBody = all.map { k, v in
                k + "=" + (v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)
            }.joined(separator: "&").data(using: .utf8)
            let data = try fetch(req)
            if let e = try? JSONDecoder().decode(APIError.self, from: data), e.exception != nil || e.errorcode != nil {
                if e.errorcode == "invalidtoken" { throw MoodleError("Connexion expirée : reconnecte-toi à l'ENT.") }
                throw MoodleError(e.message ?? e.errorcode ?? "Erreur Moodle.")
            }
            do { return try JSONDecoder().decode(T.self, from: data) } catch {
                throw MoodleError("Réponse Moodle illisible (\(function)).")
            }
        }

        public func siteInfo() throws -> SiteInfo { try call("core_webservice_get_site_info") }

        public func courses(user: Int) throws -> [Course] {
            try call("core_enrol_get_users_courses", ["userid": String(user)])
        }

        public func contents(course: Int) throws -> [Section] {
            try call("core_course_get_contents", ["courseid": String(course)])
        }

        /// Télécharge un fichier (adresse pluginfile + jeton) vers `dest`.
        public func download(_ fileurl: String, to dest: URL) throws {
            guard var c = URLComponents(string: fileurl) else { throw MoodleError("Adresse de fichier invalide.") }
            var items = c.queryItems ?? []
            items.removeAll { $0.name == "token" }
            items.append(URLQueryItem(name: "token", value: token))
            c.queryItems = items
            guard let u = c.url else { throw MoodleError("Adresse de fichier invalide.") }
            let data = try fetch(URLRequest(url: u), timeout: 300)
            // une page HTML d'erreur à la place d'un fichier
            if data.prefix(200).range(of: Data("\"errorcode\"".utf8)) != nil {
                throw MoodleError("Fichier refusé par Moodle : \(dest.lastPathComponent)")
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        }
    }

    // MARK: Fichiers d'un cours

    /// Un fichier à récupérer, avec son chemin « logique » dans le cours (section / dossier / sous-dossiers / nom).
    public struct RemoteFile: Hashable {
        public let course: Int
        public let components: [String]
        public let fileurl: String
        public let timemodified: Int
        public let size: Int
        /// Clé stable pour savoir s'il a déjà été récupéré.
        public var key: String { "\(course)|" + components.joined(separator: "/") }
    }

    /// Fichiers d'un cours : ressources (un fichier) et dossiers (plusieurs, avec sous-dossiers).
    /// Les liens, pages, devoirs, quiz… sont ignorés ; les fichiers de plus de `maxSize` octets aussi (vidéos).
    public static func files(of sections: [Section], course: Int, maxSize: Int = 150_000_000) -> (files: [RemoteFile], skippedLarge: Int) {
        var out: [RemoteFile] = []
        var large = 0
        for s in sections {
            let section = clean(s.name)
            for m in s.modules where m.modname == "resource" || m.modname == "folder" {
                for c in m.contents ?? [] where c.type == "file" {
                    guard let url = c.fileurl, !c.filename.isEmpty else { continue }
                    if let size = c.filesize, size > maxSize { large += 1; continue }
                    var comps: [String] = []
                    if !section.isEmpty { comps.append(section) }
                    if m.modname == "folder" {
                        comps.append(clean(m.name))
                        comps += (c.filepath ?? "/").split(separator: "/").map { clean(String($0)) }.filter { !$0.isEmpty }
                    }
                    comps.append(c.filename.replacingOccurrences(of: "/", with: "-"))
                    out.append(RemoteFile(course: course, components: comps, fileurl: url, timemodified: c.timemodified ?? 0,
                                          size: c.filesize ?? 0))
                }
            }
        }
        return (out, large)
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// « [2026] L1 INFO - ANALYSE 1 (S-E02-6502) » → « Analyse 1 »
    public static func subjectName(_ fullname: String) -> String {
        var s = fullname
        for p in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\b[A-Z]-[A-Z0-9]{2,4}-[0-9]{3,5}\b"#, #"\b(L[123]|M[12])\b\s*[A-Z]*\s*-\s*"#] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–·:"))
        if s.isEmpty { s = fullname }
        // tout en majuscules → « Analyse 1 »
        if s == s.uppercased(), s.count > 3 { s = s.lowercased().prefix(1).uppercased() + s.lowercased().dropFirst() }
        return s
    }

    // MARK: Réseau (synchrone, à appeler hors du fil principal)

    static func fetch(_ req: URLRequest, timeout: TimeInterval = 40) throws -> Data {
        var r = req
        r.timeoutInterval = timeout
        r.setValue("Toolbox (Moodle sync)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(MoodleError("Pas de réponse."))
        URLSession.shared.dataTask(with: r) { data, resp, err in
            if let err = err {
                result = .failure(MoodleError("Connexion impossible : \(err.localizedDescription)"))
            } else if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                result = .failure(MoodleError("Le site a répondu \(h.statusCode)."))
            } else {
                result = .success(data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }
}
