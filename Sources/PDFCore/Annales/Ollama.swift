import Foundation

public struct OllamaModel: Identifiable, Hashable {
    public let name: String
    public let size: Int64
    public var id: String { name }
    public var sizeLabel: String { FileUtils.formatBytes(size) }
}

public struct OllamaMessage {
    public var role: String          // system, user, assistant
    public var content: String
    public var images: [String] = [] // JPEG en base64

    public init(role: String, content: String, images: [String] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    var json: [String: Any] {
        var d: [String: Any] = ["role": role, "content": content]
        if !images.isEmpty { d["images"] = images }
        return d
    }
}

/// Client minimal de l'API locale d'Ollama (http://localhost:11434).
public final class OllamaClient {
    public var baseURL: URL

    /// 127.0.0.1 plutôt que « localhost » : localhost peut se résoudre en IPv6 (::1)
    /// alors qu'Ollama n'écoute qu'en IPv4 par défaut.
    public static let defaultHost = "http://127.0.0.1:11434"

    public init(baseURL: URL = URL(string: OllamaClient.defaultHost)!) {
        self.baseURL = baseURL
    }

    /// « 127.0.0.1:11434 », « localhost:11434 », « http://… » → URL complète.
    public convenience init(host: String) {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { h = OllamaClient.defaultHost }
        if !h.hasPrefix("http://") && !h.hasPrefix("https://") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        self.init(baseURL: URL(string: h) ?? URL(string: OllamaClient.defaultHost)!)
    }

    func unreachable(_ error: Error) -> String {
        "Ollama ne répond pas à \(baseURL.absoluteString) (\(error.localizedDescription)). "
            + "Vérifie que « ollama serve » tourne, et l'adresse dans les réglages."
    }

    private func request(_ path: String, body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.timeoutInterval = timeout
        if let body = body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            throw PDFToolError.commandFailed(unreachable(error))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw PDFToolError.commandFailed("Ollama : " + ((json["error"] as? String) ?? "erreur \(http.statusCode)"))
        }
        return json
    }

    /// Modèles installés (ollama pull …).
    public func models() async throws -> [OllamaModel] {
        let json = try await send(try request("api/tags", body: nil, timeout: 5))
        let list = json["models"] as? [[String: Any]] ?? []
        return list.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let size = (m["size"] as? NSNumber)?.int64Value ?? 0
            return OllamaModel(name: name, size: size)
        }.sorted { $0.name < $1.name }
    }

    /// Modèles actuellement chargés en mémoire (nom, octets occupés).
    public func loaded() async -> [(name: String, size: Int64)] {
        guard let r = try? request("api/ps", body: nil, timeout: 5), let json = try? await send(r) else { return [] }
        return (json["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            return (name, (m["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Décharge un modèle de la mémoire tout de suite.
    public func unload(_ model: String) async {
        guard let r = try? request("api/generate", body: ["model": model, "keep_alive": 0], timeout: 15) else { return }
        _ = try? await send(r)
    }

    /// Capacités d'un modèle (« vision » s'il sait lire les images).
    public func capabilities(_ model: String) async -> Set<String> {
        guard let r = try? request("api/show", body: ["model": model], timeout: 10),
              let json = try? await send(r) else { return [] }
        if let caps = json["capabilities"] as? [String] { return Set(caps) }
        // Anciennes versions d'Ollama : on devine d'après la présence d'un projecteur d'images.
        if json["projector_info"] != nil { return ["completion", "vision"] }
        return ["completion"]
    }

    /// Conversation ; la réponse arrive au fil de l'eau dans `onToken`.
    /// `keepAlive` : combien de temps le modèle reste en mémoire après la réponse (« 0 » = libéré tout de suite).
    public func chat(model: String, messages: [OllamaMessage], options: [String: Any] = [:],
                     format: String? = nil, keepAlive: String = "2m",
                     onToken: ((String) -> Void)? = nil) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { $0.json },
            "stream": true,
            "keep_alive": keepAlive,
        ]
        if !options.isEmpty { body["options"] = options }
        if let format = format { body["format"] = format }
        let r = try request("api/chat", body: body, timeout: 900)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: r)
        } catch {
            throw PDFToolError.commandFailed(unreachable(error))
        }
        var full = ""
        var errorText: String?
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let e = json["error"] as? String { errorText = e; break }
            if let message = json["message"] as? [String: Any], let piece = message["content"] as? String {
                full += piece
                onToken?(piece)
            }
            if json["done"] as? Bool == true { break }
        }
        if let e = errorText { throw PDFToolError.commandFailed("Ollama : \(e)") }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400, full.isEmpty {
            throw PDFToolError.commandFailed("Ollama : erreur \(http.statusCode) (modèle « \(model) » installé ?)")
        }
        return full
    }
}
