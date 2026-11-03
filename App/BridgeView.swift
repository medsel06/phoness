import Foundation
import SwiftUI

struct BridgeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = UserDefaults.standard.string(forKey: "bridge.address") ?? ""
    @State private var secret = ""
    @State private var bridge: Task<Void, Never>?
    @State private var message = "Kapalı"

    private static let secretName = "bridge.device"
    private static let session = URLSession(
        configuration: .ephemeral,
        delegate: BridgeNoRedirect(),
        delegateQueue: nil
    )

    var body: some View {
        NavigationStack {
            Form {
                NavigationLink("Çalıştırıcı ayarları") { ControlView() }
                Section("VPS bağlantısı") {
                    TextField("https://sunucu.example", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(bridge != nil)
                    SecureField("Cihaz erişim kodu", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(bridge != nil)
                    Button(bridge == nil ? "Köprüyü başlat" : "Köprüyü durdur") {
                        if bridge == nil { start() } else { stop() }
                    }
                    Text(message)
                }
                Text("İlk sürüm çalıştırıcı durumunu sorgular. Agent ön planda kalmalıdır.")
            }
            .navigationTitle("iPhone köprüsü")
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { stop() }
            }
        }
    }

    private func start() {
        guard let url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let base = url.url else {
            message = "HTTPS sunucu adresini yol eklemeden yazın."
            return
        }
        let savedAddress = UserDefaults.standard.string(forKey: "bridge.address")
        let key = secret.isEmpty && savedAddress == base.absoluteString
            ? Keychain.get(Self.secretName) ?? "" : secret
        guard key.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else {
            message = "Geçerli cihaz erişim kodu girin."
            return
        }
        do {
            try Keychain.set(Self.secretName, key)
        } catch {
            message = "Cihaz kodu Anahtar Zinciri içinde saklanamadı."
            return
        }
        UserDefaults.standard.set(base.absoluteString, forKey: "bridge.address")
        secret = ""
        message = "Bağlanıyor…"
        bridge = Task {
            while !Task.isCancelled {
                do {
                    try await poll(base, key: key)
                    try Task.checkCancellation()
                    message = "Bağlı · durum sorgusu bekleniyor"
                } catch BridgeError.unauthorized {
                    if !Task.isCancelled {
                        bridge = nil
                        message = "VPS cihaz kodunu kabul etmedi."
                    }
                    return
                } catch {
                    if Task.isCancelled { return }
                    message = "VPS bağlantısı kurulamadı. Yeniden deneniyor…"
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stop() {
        bridge?.cancel()
        bridge = nil
        message = "Kapalı"
    }

    private struct Job: Decodable {
        let id: String
        let komut: String
    }

    private enum BridgeError: Error {
        case unauthorized, invalidResponse
    }

    private func poll(_ base: URL, key: String) async throws {
        let (data, status) = try await request(base.appending(path: "cihaz").appending(path: "al"), key: key)
        if status == 204 { return }
        guard status == 200, data.count <= 1024 else { throw BridgeError.invalidResponse }
        let job = try JSONDecoder().decode(Job.self, from: data)
        guard job.komut == "durum",
              job.id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
            throw BridgeError.invalidResponse
        }
        try Task.checkCancellation()
        let alive = await Runner.alive()
        try Task.checkCancellation()
        let resultURL = base.appending(path: "cihaz").appending(path: "sonuc")
            .appending(path: job.id).appending(path: alive ? "acik" : "kapali")
        let (_, resultStatus) = try await request(resultURL, key: key, method: "POST")
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

private final class BridgeNoRedirect: NSObject, URLSessionTaskDelegate {
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
