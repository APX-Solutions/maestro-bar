import Foundation

struct Client {
    let id: String
    let name: String
}

final class API {
    private var base: String
    private var tokenService: String

    init(base: String, tokenService: String) {
        self.base = base
        self.tokenService = tokenService
    }

    func update(base: String, tokenService: String) {
        self.base = base
        self.tokenService = tokenService
    }

    private func request(_ path: String, method: String, body: Data?) -> URLRequest? {
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        if let t = Keychain.read(service: tokenService) {
            r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        }
        if let b = body {
            r.httpBody = b
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest, _ done: @escaping (Any?, Int) -> Void) {
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var json: Any? = nil
            if let d = data { json = try? JSONSerialization.jsonObject(with: d) }
            DispatchQueue.main.async { done(json, code) }
        }.resume()
    }

    func get(_ path: String, _ done: @escaping (Any?, Int) -> Void) {
        guard let r = request(path, method: "GET", body: nil) else { done(nil, 0); return }
        send(r, done)
    }

    /// Any verb. PATCH is what moves a card through its lifecycle, so the
    /// panel cannot get by with GET and POST alone.
    func call(_ method: String, _ path: String, body: [String: String]?,
              _ done: @escaping (Any?, Int) -> Void) {
        let verb = method.uppercased()
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let payload: Data? = (verb == "GET") ? nil : (data ?? Data("{}".utf8))
        guard let r = request(path, method: verb, body: payload) else { done(nil, 0); return }
        send(r, done)
    }

    func post(_ path: String, body: [String: String]?, _ done: @escaping (Any?, Int) -> Void) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        guard let r = request(path, method: "POST", body: data ?? Data("{}".utf8)) else { done(nil, 0); return }
        send(r, done)
    }

    /// Reads one integer out of a response, tolerating a flat object or {data:{...}}.
    static func int(_ json: Any?, field: String) -> Int? {
        func dig(_ o: Any?) -> Int? {
            guard let d = o as? [String: Any] else { return nil }
            if let n = d[field] as? Int { return n }
            if let n = d[field] as? Double { return Int(n) }
            if let n = d[field] as? String { return Int(n) }
            for key in ["data", "counts", "result"] {
                if let sub = dig(d[key]) { return sub }
            }
            return nil
        }
        return dig(json)
    }

    /// A list endpoint may answer with a bare array or wrap it. Read both.
    static func rows(_ json: Any?) -> [[String: Any]] {
        if let a = json as? [[String: Any]] { return a }
        if let d = json as? [String: Any] {
            for key in ["items", "data", "results", "rows", "actions", "tasks", "proposals", "cards"] {
                if let a = d[key] as? [[String: Any]] { return a }
            }
        }
        return []
    }

    /// Clients come back in more than one shape across endpoints, so read leniently.
    static func clients(_ json: Any?) -> [Client] {
        var rows: [[String: Any]] = []
        if let a = json as? [[String: Any]] { rows = a }
        else if let d = json as? [String: Any] {
            for key in ["clients", "data", "items", "results"] {
                if let a = d[key] as? [[String: Any]] { rows = a; break }
            }
        }
        return rows.compactMap { row in
            let name = ["name", "company", "client_name", "title", "label"]
                .compactMap { row[$0] as? String }
                .first { !$0.isEmpty }
            guard let n = name else { return nil }
            let id = (row["id"] as? String)
                ?? (row["id"] as? Int).map { String($0) }
                ?? n
            return Client(id: id, name: n)
        }
    }
}
