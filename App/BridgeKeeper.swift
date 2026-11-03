import AVFoundation
import Foundation

// Köprü açıkken (kullanıcı "Köprüyü durdur"a basana kadar) Agent'ı arka planda uyanık tutar ve
// köprüyü ayakta tutar. iPhone arka plandaki uygulamayı ~30 sn sonra donduruyor; Agent donunca
// Runner da duruyor. Sessiz ses çalan uygulama (UIBackgroundModes: audio) dondurulmaz.
// Bekçi 5 sn'de bir Runner'a bakar: cevap yoksa Runner'ı yeniden başlatır, köprü kapalıysa açar.
@MainActor
final class BridgeKeeper {
    static let shared = BridgeKeeper()

    static let addressKey = "bridge.address"
    static let secretName = "bridge.device"
    private static let wantedKey = "bridge.wanted"

    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: wantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: wantedKey) }
    }

    private(set) var note = ""
    private var task: Task<Void, Never>?
    private var nudged = false

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var audioOn = false

    private init() {
        connectAudio()
        let center = NotificationCenter.default
        // arama ya da başka bir uygulamanın sesi kesti: kesinti bitince yeniden çal
        _ = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated { BridgeKeeper.shared.playSilence() }
        }
        _ = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BridgeKeeper.shared.resetAudio() }
        }
        _ = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BridgeKeeper.shared.playSilence() }
        }
    }

    // köprü açık olmalıysa sesi ve bekçiyi başlatır. uygulama her öne geldiğinde de çağrılır
    func keep() {
        guard Self.wanted else { return }
        audioOn = true
        playSilence()
        nudged = true
        guard task == nil else { return }
        task = Task { await loop() }
    }

    // yalnız kullanıcı durdurunca
    func end() async {
        Self.wanted = false
        task?.cancel()
        task = nil
        note = ""
        stopSilence()
        _ = try? await Runner.call("/bridge/stop", body: [:], timeout: 3)
    }

    // Runner'daki köprüyü kayıtlı adres ve cihaz koduyla açar. sorun varsa mesajını döner
    func startBridge() async -> String? {
        guard let address = UserDefaults.standard.string(forKey: Self.addressKey),
              let key = Keychain.get(Self.secretName), !key.isEmpty else {
            return "Kayıtlı sunucu adresi ya da cihaz kodu yok."
        }
        do {
            _ = try await Runner.call("/bridge/start", body: ["address": address, "key": key], timeout: 3)
            return nil
        } catch let failure as Runner.Failure where failure.status == 404 {
            return "Bu çalıştırıcı köprüyü desteklemiyor. Yeni Runner paketini kurun."
        } catch {
            return "Çalıştırıcıya erişilemedi."
        }
    }

    private func loop() async {
        var misses = 0
        var failures = 0
        var nextRestart = Date.distantPast
        while !Task.isCancelled, Self.wanted {
            if nudged {
                // kullanıcı uygulamayı açtı: beklemeyi bırak, hemen dene
                nudged = false
                failures = 0
                nextRestart = .distantPast
            }
            if await Runner.alive() {
                misses = 0
                failures = 0
                let reply = try? await Runner.call("/bridge/status", timeout: 3)
                let state = reply?["state"] as? String
                if Task.isCancelled { return }
                if reply != nil, state == "stopped" || state == "expired" {
                    // Runner yeniden başlamış, köprüsü kapalı
                    note = await startBridge() ?? ""
                } else if state == "unauthorized" {
                    note = "VPS cihaz kodunu kabul etmedi."
                } else {
                    note = ""
                }
            } else {
                misses += 1
                // ~10 sn cevap yok: Runner kapanmış ya da donmuş
                if misses >= 2, Date() >= nextRestart {
                    misses = 0
                    note = "Çalıştırıcı yeniden başlatılıyor…"
                    let ok = await Control.shared.restart()
                    if Task.isCancelled { return }
                    if ok {
                        failures = 0
                        note = await startBridge() ?? ""
                    } else {
                        failures += 1
                        // şifre istemi ya da Wi-Fi yoksa üst üste denemesin: 1, 2, 4, 8 dk … en çok 10 dk
                        nextRestart = Date().addingTimeInterval(min(60 * pow(2, Double(failures - 1)), 600))
                        let why = Control.shared.message
                        note = "Çalıştırıcı başlatılamadı\(why.isEmpty ? "" : ": \(why)"). Agent'ı açınca yeniden denenir."
                    }
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: sessiz ses

    private func connectAudio() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func resetAudio() {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        connectAudio()
        playSilence()
    }

    func playSilence() {
        guard audioOn else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // başka uygulamaların sesini kesmez, onlarla karışır
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning {
                player.stop()
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
                buffer.frameLength = buffer.frameCapacity
                if let channels = buffer.floatChannelData {
                    channels[0].update(repeating: 0, count: Int(buffer.frameLength))
                }
                player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                player.play()
            }
        } catch {
            NSLog("bridge keepalive: %@", "\(error)")
        }
    }

    private func stopSilence() {
        audioOn = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
