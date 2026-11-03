import Foundation
import SwiftUI

struct BridgeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = UserDefaults.standard.string(forKey: "bridge.address") ?? ""
    @State private var secret = ""
    @State private var state = "stopped"
    @State private var busy = false
    @State private var error: String?

    private static let secretName = "bridge.device"

    private var running: Bool { ["connecting", "connected", "retrying"].contains(state) }

    private var message: String {
        if let error { return error }
        switch state {
        case "connecting": return "Bağlanıyor…"
        case "connected": return "Runner köprüsü bağlı · durum sorgusu bekleniyor"
        case "retrying": return "VPS bağlantısı kurulamadı. Yeniden deneniyor…"
        case "unauthorized": return "VPS cihaz kodunu kabul etmedi."
        case "expired": return "15 dakikalık oturum sona erdi."
        default: return "Kapalı"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                NavigationLink("Çalıştırıcı ayarları") { ControlView() }
                Section("VPS bağlantısı") {
                    TextField("https://sunucu.example", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(running || busy)
                    SecureField("Cihaz erişim kodu", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(running || busy)
                    Button(running ? "Köprüyü durdur" : "Köprüyü başlat") {
                        Task {
                            if running { await stop() } else { await start() }
                        }
                    }
                    .disabled(busy)
                    Text(message)
                }
                Text("Runner üzerinden yalnızca durum sorgusu. Deneme oturumu 15 dakika sürer.")
            }
            .navigationTitle("iPhone köprüsü")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if !busy {
                        let current = try? await Runner.call("/bridge/status", timeout: 1.5)
                        if !Task.isCancelled && !busy {
                            state = current?["state"] as? String ?? "stopped"
                        }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func start() async {
        error = nil
        guard let url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let base = url.url else {
            error = "HTTPS sunucu adresini yol eklemeden yazın."
            return
        }
        let savedAddress = UserDefaults.standard.string(forKey: "bridge.address")
        let key = secret.isEmpty && savedAddress == base.absoluteString
            ? Keychain.get(Self.secretName) ?? "" : secret
        guard key.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else {
            error = "Geçerli cihaz erişim kodu girin."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try Keychain.set(Self.secretName, key)
            UserDefaults.standard.set(base.absoluteString, forKey: "bridge.address")
            secret = ""
        } catch {
            self.error = "Cihaz kodu Anahtar Zinciri içinde saklanamadı."
            return
        }
        do {
            let reply = try await Runner.call(
                "/bridge/start", body: ["address": base.absoluteString, "key": key], timeout: 3
            )
            state = reply["state"] as? String ?? "connecting"
        } catch let failure as Runner.Failure where failure.status == 404 {
            self.error = "Bu çalıştırıcı köprüyü desteklemiyor. Yeni Runner paketini kurun."
        } catch {
            self.error = "Çalıştırıcıya erişilemedi. Çalıştırıcı ayarlarından Turn On seçin."
        }
    }

    private func stop() async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            _ = try await Runner.call("/bridge/stop", body: [:], timeout: 3)
            state = "stopped"
        } catch {
            self.error = "Köprü durdurulamadı. Çalıştırıcı ayarlarından Turn Off seçin."
        }
    }
}
