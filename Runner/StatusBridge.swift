import Foundation

// VPS köprüsü, Runner'ın içinde. Kullanıcı durdurana kadar çalışır (süre sınırı yok).
// VPS'ten iş alır (uzun bekleme), işi Runner'ın kendi uç noktalarıyla (look/act/apps) yapar,
// cevabı olduğu gibi geri yollar. Telefona dışarıdan bağlantı açılmaz.
@MainActor
final class StatusBridge {
    private(set) var state = "stopped"
    private var task: Task<Void, Never>?
    private unowned let phone: Phone

    init(phone: Phone) {
        self.phone = phone
    }

    private static let session = URLSession(
        configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil
    )

    func start(address: String, key: String) -> Bool {
        guard let url = URLComponents(string: address),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let base = url.url,
              key.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else {
            return false
        }
        guard task == nil else { return true }
        state = "connecting"
        task = Task {
            // ilk istek beklemeden döner, "bağlı" hemen görünsün. sonrakiler iş gelene kadar bekler
            var wait = false
            while !Task.isCancelled {
                do {
                    try await poll(base: base, key: key, wait: wait)
                    try Task.checkCancellation()
                    state = "connected"
                    wait = true
                } catch BridgeError.unauthorized {
                    guard !Task.isCancelled else { return }
                    state = "unauthorized"
                    task = nil
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    state = "retrying"
                    wait = false
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        return true
    }

    func stop() {
        task?.cancel()
        task = nil
        state = "stopped"
    }

    private enum BridgeError: Error {
        case unauthorized, invalidResponse
    }

    private func poll(base: URL, key: String, wait: Bool) async throws {
        let device = base.appending(path: "cihaz")
        var take = device.appending(path: "al")
        if wait { take.append(queryItems: [URLQueryItem(name: "bekle", value: "1")]) }
        // sunucu en fazla 15 sn bekletir
        let (data, status) = try await request(take, key: key, timeout: wait ? 30 : 10)
        if status == 204 { return }
        guard status == 200, data.count <= 16 * 1024,
              let job = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = job["id"] as? String,
              id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
              let komut = job["komut"] as? String else {
            throw BridgeError.invalidResponse
        }
        try Task.checkCancellation()
        let res = run(komut, job["veri"] as? [String: Any] ?? [:])
        let status3 = (100...599).contains(res.status) ? res.status : 500
        let answer = device.appending(path: "cevap").appending(path: id).appending(path: String(status3))
        let (_, answerStatus) = try await request(answer, key: key, method: "POST", body: res.body, timeout: 30)
        guard answerStatus == 204 || answerStatus == 409 else { throw BridgeError.invalidResponse }
    }

    // VPS'in komutunu Runner'ın yerel uç noktasına çevirir. yalnız bu beş komut var
    private func run(_ komut: String, _ veri: [String: Any]) -> Server.Response {
        var req = Server.Request()
        switch komut {
        case "durum":
            return .json(["ok": true])
        case "bak":
            req.method = "GET"
            req.path = "/look"
        case "islem":
            req.method = "POST"
            req.path = "/act"
            req.body = (try? JSONSerialization.data(withJSONObject: veri)) ?? Data("{}".utf8)
        case "uygulamalar":
            req.method = "GET"
            req.path = "/apps"
        case "sistem_ara":
            req.method = "POST"
            req.path = "/sistem"
            req.body = (try? JSONSerialization.data(withJSONObject: veri)) ?? Data("{}".utf8)
        default:
            return .json(["error": "unknown bridge command \(komut)"], status: 400)
        }
        return phone.handle(req)
    }

    private func request(
        _ url: URL, key: String, method: String = "GET", body: Data? = nil, timeout: Double
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw BridgeError.invalidResponse
        }
        if status == 401 { throw BridgeError.unauthorized }
        return (data, status)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
