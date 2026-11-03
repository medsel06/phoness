import Foundation
import SwiftUI

struct BridgeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = UserDefaults.standard.string(forKey: BridgeKeeper.addressKey) ?? ""
    @State private var secret = ""
    @State private var state = "stopped"
    @State private var wanted = BridgeKeeper.wanted
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    private var message: String {
        if let error { return error }
        if busy { return "Bekleyin… (iPhone şifre sorarsa girin)" }
        switch state {
        case "connected": return "Köprü bağlı · arka planda da açık kalır"
        case "connecting": return "Bağlanıyor…"
        case "retrying": return "VPS bağlantısı kurulamadı. Yeniden deneniyor…"
        case "unauthorized": return "VPS cihaz kodunu kabul etmedi."
        default: return wanted ? (note.isEmpty ? "Köprü yeniden kuruluyor…" : note) : "Kapalı"
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
                        .disabled(wanted || busy)
                    SecureField("Cihaz erişim kodu", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(wanted || busy)
                    Button(wanted ? "Köprüyü durdur" : "Köprüyü başlat") {
                        Task {
                            if wanted { await stop() } else { await start() }
                        }
                    }
                    .disabled(busy)
                    Text(message)
                }
                Text("Köprü siz durdurana kadar açık kalır. Arka planda sessiz ses çalarak uyanık durur; koparsa kendini yeniden kurar.")
            }
            .navigationTitle("iPhone köprüsü")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                // köprü açık olmalıysa sesi ve bekçiyi (yeniden) başlatır, bekleyen denemeyi öne alır
                BridgeKeeper.shared.keep()
                while !Task.isCancelled {
                    if !busy {
                        let current = try? await Runner.call("/bridge/status", timeout: 1.5)
                        if !Task.isCancelled && !busy {
                            state = current?["state"] as? String ?? "stopped"
                            wanted = BridgeKeeper.wanted
                            note = BridgeKeeper.shared.note
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
        let savedAddress = UserDefaults.standard.string(forKey: BridgeKeeper.addressKey)
        let key = secret.isEmpty && savedAddress == base.absoluteString
            ? Keychain.get(BridgeKeeper.secretName) ?? "" : secret
        guard key.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else {
            error = "Geçerli cihaz erişim kodu girin."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try Keychain.set(BridgeKeeper.secretName, key)
            UserDefaults.standard.set(base.absoluteString, forKey: BridgeKeeper.addressKey)
            secret = ""
        } catch {
            self.error = "Cihaz kodu Anahtar Zinciri içinde saklanamadı."
            return
        }
        // çalıştırıcı kapalı ya da donmuşsa önce onu aç
        if !(await Runner.alive()) {
            guard await Control.shared.restart() else {
                let why = Control.shared.message
                self.error = "Çalıştırıcı başlatılamadı\(why.isEmpty ? "" : ": \(why)")"
                return
            }
        }
        BridgeKeeper.wanted = true
        wanted = true
        note = await BridgeKeeper.shared.startBridge() ?? ""
        BridgeKeeper.shared.keep()
    }

    private func stop() async {
        error = nil
        busy = true
        defer { busy = false }
        await BridgeKeeper.shared.end()
        wanted = false
        note = ""
        state = "stopped"
    }
}
