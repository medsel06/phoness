import AlarmKit
import Foundation
import SwiftUI

// AlarmKit (iOS 26+): gerçek, sessizde de çalan alarm/sayaç. Uygulama açılmadan, ekransız kurulur.
// Boş metadata (AlarmMetadata: Codable & Hashable & Sendable — boş yapı kendiliğinden uyar).
struct KopruAlarmMeta: AlarmMetadata {}

enum Alarmlar {
    private static var m: AlarmManager { AlarmManager.shared }

    static func durum() -> String {
        switch m.authorizationState {
        case .authorized: return "tam"
        case .denied: return "reddedildi"
        case .notDetermined: return "sorulmadı"
        @unknown default: return "bilinmiyor"
        }
    }

    @discardableResult
    static func yetkiIste() async -> Bool {
        if case .authorized = m.authorizationState { return true }
        return ((try? await m.requestAuthorization()) == .authorized)
    }

    private static func ozellikler(_ baslik: String) -> AlarmAttributes<KopruAlarmMeta> {
        let durdur = AlarmButton(text: "Durdur", textColor: .white, systemImageName: "stop.fill")
        let uyari = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: baslik), stopButton: durdur)
        return AlarmAttributes(presentation: AlarmPresentation(alert: uyari), metadata: KopruAlarmMeta(), tintColor: .orange)
    }

    private static func gerekYetki() async throws {
        guard await yetkiIste() else {
            throw EkransizIs.Sorun(kod: 403, mesaj: "Alarm izni yok. iPhone'da Agent'ı açıp 'İzinleri ver'e basın.")
        }
    }

    static func alarmKur(_ tarih: Date, _ baslik: String) async throws -> String {
        try await gerekYetki()
        let id = UUID()
        let config = AlarmManager.AlarmConfiguration.alarm(schedule: .fixed(tarih), attributes: ozellikler(baslik))
        _ = try await m.schedule(id: id, configuration: config)
        return id.uuidString
    }

    static func sayacKur(_ saniye: TimeInterval, _ baslik: String) async throws -> String {
        try await gerekYetki()
        let id = UUID()
        let config = AlarmManager.AlarmConfiguration.timer(duration: saniye, attributes: ozellikler(baslik))
        _ = try await m.schedule(id: id, configuration: config)
        return id.uuidString
    }

    static func iptal(_ id: String) throws {
        guard let u = UUID(uuidString: id) else {
            throw EkransizIs.Sorun(kod: 400, mesaj: "geçersiz alarm kimliği")
        }
        try m.cancel(id: u)
    }
}
