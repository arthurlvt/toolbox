import Foundation

public struct GitHubRepo: Identifiable, Hashable {
    public var id: String { fullName }
    public let name: String
    public let fullName: String
    public let url: URL
    public let description: String
    public let isPrivate: Bool
    public let language: String
    public let stars: Int
    public let pushed: Date?
    public let cloneURL: String
}

/// Dépôts GitHub de l'utilisateur : via la commande `gh` (dépôts privés compris) si elle est
/// installée et connectée, sinon via l'API publique avec un nom d'utilisateur.
public enum GitHub {
    public static var ghPath: String? { Shell.which("gh") }
    public static var gitPath: String? { Shell.which("git") }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Identifiant du compte connecté à `gh`, ou nil.
    public static func ghLogin() -> String? {
        guard let gh = ghPath, let out = try? Shell.run(gh, ["api", "user", "--jq", ".login"]),
              out.status == 0 else { return nil }
        let login = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty || login.contains(" ") ? nil : login
    }

    public static func repos(user: String?, limit: Int = 12) throws -> (repos: [GitHubRepo], via: String) {
        if let gh = ghPath, ghLogin() != nil {
            let out = try Shell.run(gh, ["repo", "list", "--limit", "\(max(limit, 30))", "--json",
                                         "name,nameWithOwner,url,description,isPrivate,primaryLanguage,stargazerCount,pushedAt"])
            if out.status == 0, let data = jsonPart(out.text).data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let repos = list.compactMap { d -> GitHubRepo? in
                    guard let name = d["name"] as? String, let full = d["nameWithOwner"] as? String,
                          let s = d["url"] as? String, let url = URL(string: s) else { return nil }
                    let lang = (d["primaryLanguage"] as? [String: Any])?["name"] as? String ?? ""
                    return GitHubRepo(name: name, fullName: full, url: url, description: d["description"] as? String ?? "",
                                      isPrivate: d["isPrivate"] as? Bool ?? false, language: lang,
                                      stars: d["stargazerCount"] as? Int ?? 0,
                                      pushed: (d["pushedAt"] as? String).flatMap { iso.date(from: $0) },
                                      cloneURL: s + ".git")
                }
                return (Array(sorted(repos).prefix(limit)), "gh")
            }
        }
        guard let user = user?.trimmingCharacters(in: .whitespaces), !user.isEmpty else {
            throw PDFToolError.commandFailed("indique ton nom d'utilisateur GitHub (ou installe gh : brew install gh, puis gh auth login)")
        }
        guard let url = URL(string: "https://api.github.com/users/\(user)/repos?sort=pushed&per_page=\(limit)") else {
            throw PDFToolError.commandFailed("nom d'utilisateur invalide")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, status) = try fetch(request)
        guard status == 200 else {
            throw PDFToolError.commandFailed(status == 404 ? "utilisateur GitHub « \(user) » introuvable"
                                             : "GitHub a répondu \(status) (limite de requêtes atteinte ?)")
        }
        let list = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        let repos = list.compactMap { d -> GitHubRepo? in
            guard let name = d["name"] as? String, let full = d["full_name"] as? String,
                  let s = d["html_url"] as? String, let url = URL(string: s) else { return nil }
            return GitHubRepo(name: name, fullName: full, url: url, description: d["description"] as? String ?? "",
                              isPrivate: d["private"] as? Bool ?? false, language: d["language"] as? String ?? "",
                              stars: d["stargazers_count"] as? Int ?? 0,
                              pushed: (d["pushed_at"] as? String).flatMap { iso.date(from: $0) },
                              cloneURL: d["clone_url"] as? String ?? s + ".git")
        }
        return (sorted(repos), "api")
    }

    static func sorted(_ repos: [GitHubRepo]) -> [GitHubRepo] {
        repos.sorted { ($0.pushed ?? .distantPast) > ($1.pushed ?? .distantPast) }
    }

    /// `gh` peut afficher un avertissement avant le JSON : on garde à partir du premier « [ ».
    static func jsonPart(_ s: String) -> String {
        guard let i = s.firstIndex(of: "[") else { return s }
        return String(s[i...])
    }

    static func fetch(_ request: URLRequest) throws -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { failure = error }
            result = (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)
            sem.signal()
        }.resume()
        sem.wait()
        if let e = failure { throw PDFToolError.commandFailed("GitHub injoignable : \(e.localizedDescription)") }
        return result ?? (Data(), 0)
    }

    /// Clone le dépôt dans `folder/<nom>` (avec gh si possible, pour les dépôts privés).
    public static func clone(_ repo: GitHubRepo, into folder: URL) throws -> URL {
        let dest = folder.appendingPathComponent(repo.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out: Shell.Output
        if let gh = ghPath {
            out = try Shell.run(gh, ["repo", "clone", repo.fullName, dest.path])
        } else if let git = gitPath {
            out = try Shell.run(git, ["clone", repo.cloneURL, dest.path])
        } else {
            throw PDFToolError.toolMissing("git (xcode-select --install)")
        }
        guard out.status == 0 else {
            throw PDFToolError.commandFailed("clonage impossible : " + String(out.text.suffix(300)))
        }
        return dest
    }
}
