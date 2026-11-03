import Foundation

@MainActor
final class StatusBridge {
    private(set) var state = "stopped"
    private var task: Task<Void, Never>?

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
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(900)
        task = Task {
            while !Task.isCancelled && clock.now < deadline {
                do {
                    try await poll(base: base, key: key)
                    try Task.checkCancellation()
                    state = "connected"
                } catch BridgeError.unauthorized {
                    guard !Task.isCancelled else { return }
                    state = "unauthorized"
                    task = nil
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    state = "retrying"
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            state = "expired"
            task = nil
        }
        return true
    }

    func stop() {
        task?.cancel()
        task = nil
        state = "stopped"
    }

    private struct Job: Decodable {
        let id: String
        let komut: String
    }

    private enum BridgeError: Error {
        case unauthorized, invalidResponse
    }

    private func poll(base: URL, key: String) async throws {
        let device = base.appending(path: "cihaz")
        let (data, status) = try await request(device.appending(path: "al"), key: key)
        if status == 204 { return }
        guard status == 200, data.count <= 1024 else { throw BridgeError.invalidResponse }
        let job = try JSONDecoder().decode(Job.self, from: data)
        guard job.komut == "durum",
              job.id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
            throw BridgeError.invalidResponse
        }
        try Task.checkCancellation()
        let result = device.appending(path: "sonuc").appending(path: job.id).appending(path: "acik")
        let (_, resultStatus) = try await request(result, key: key, method: "POST")
        guard resultStatus == 204 || resultStatus == 409 else { throw BridgeError.invalidResponse }
    }

    private func request(_ url: URL, key: String, method: String = "GET") async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
