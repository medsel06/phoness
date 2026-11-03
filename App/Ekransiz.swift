import Contacts
import CoreTelephony
import EventKit
import Foundation
import Network
import Photos
import UIKit
import UserNotifications

// Ekransız kanal: VPS'ten (kanal=agent) iş alır; Anımsatıcılar, Takvim, Kişiler ve Fotoğraflar işini Apple'ın
// kendi altyapısıyla, hiçbir uygulamayı açmadan yapar. Agent arka planda uyanık kaldığı sürece çalışır
// (BridgeKeeper sessiz ses çalıyor). İzin soruları yalnız uygulama öndeyken gösterilebilir: "İzinleri ver".
@MainActor
final class Ekransiz {
    static let shared = Ekransiz()

    private(set) var state = "stopped"
    private var task: Task<Void, Never>?

    private static let session = URLSession(configuration: .ephemeral)

    func start() {
        guard task == nil,
              let address = UserDefaults.standard.string(forKey: BridgeKeeper.addressKey),
              let base = URL(string: address), base.scheme == "https",
              let key = Keychain.get(BridgeKeeper.secretName), !key.isEmpty else { return }
        state = "connecting"
        task = Task {
            var wait = false
            while !Task.isCancelled {
                do {
                    try await poll(base: base, key: key, wait: wait)
                    if Task.isCancelled { return }
                    state = "connected"
                    wait = true
                } catch Hata.yetkisiz {
                    state = "unauthorized"
                    task = nil
                    return
                } catch {
                    if Task.isCancelled { return }
                    state = "retrying"
                    wait = false
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = "stopped"
    }

    private enum Hata: Error {
        case yetkisiz, gecersiz
    }

    private func poll(base: URL, key: String, wait: Bool) async throws {
        let device = base.appending(path: "cihaz")
        var take = device.appending(path: "al")
        var items = [URLQueryItem(name: "kanal", value: "agent")]
        if wait { items.append(URLQueryItem(name: "bekle", value: "1")) }
        take.append(queryItems: items)
        // sunucu en fazla 15 sn bekletir
        let (data, status) = try await request(take, key: key, timeout: wait ? 30 : 10)
        if status == 204 { return }
        guard status == 200, data.count <= 64 * 1024,
              let job = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = job["id"] as? String,
              id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
              let komut = job["komut"] as? String else {
            throw Hata.gecersiz
        }
        let (kod, govde) = await EkransizIs.calistir(komut, job["veri"] as? [String: Any] ?? [:])
        let body = (try? JSONSerialization.data(withJSONObject: govde)) ?? Data("{}".utf8)
        let answer = device.appending(path: "cevap").appending(path: id).appending(path: String(kod))
        let (_, answerStatus) = try await request(answer, key: key, method: "POST", body: body, timeout: 30)
        guard answerStatus == 204 || answerStatus == 409 else { throw Hata.gecersiz }
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
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Hata.gecersiz }
        if status == 401 { throw Hata.yetkisiz }
        return (data, status)
    }
}

// İşin kendisi. Aktöre bağlı değil: EventKit/Contacts/Photos çağrıları ana iş parçacığını tutmasın.
enum EkransizIs {
    static let store = EKEventStore()
    static let kisiler = CNContactStore()

    struct Sorun: Error {
        var kod = 400
        var mesaj: String
    }

    static func calistir(_ komut: String, _ v: [String: Any]) async -> (Int, [String: Any]) {
        do {
            switch komut {
            case "izin_durum": return (200, izinDurumu())
            case "animsatici_liste": return (200, ["list": try await animsaticilar(v)])
            case "animsatici_ekle": return (200, try animsaticiEkle(v))
            case "animsatici_tamamla": return (200, try animsaticiTamamla(v))
            case "takvim_liste": return (200, ["list": try takvim(v)])
            case "takvim_ekle": return (200, try takvimEkle(v))
            case "kisi_ara": return (200, ["list": try kisiAra(v)])
            case "foto_liste": return (200, ["list": try fotograflar(v)])
            case "foto_getir": return (200, try await fotografGetir(v))
            case "bildirim_kur": return (200, try await bildirimKur(v))
            case "bildirim_liste": return (200, ["list": await bildirimler()])
            case "bildirim_iptal": return (200, bildirimIptal(v))
            case "cihaz_durum": return (200, await cihazDurumu())
            case "alarm_kur": return (200, ["kimlik": try await Alarmlar.alarmKur(tarihZorunlu(v), v["baslik"] as? String ?? "Alarm")])
            case "sayac_kur": return (200, ["kimlik": try await Alarmlar.sayacKur(saniyeZorunlu(v), v["baslik"] as? String ?? "Sayaç")])
            case "alarm_iptal": try Alarmlar.iptal(v["kimlik"] as? String ?? ""); return (200, ["ok": true])
            default: return (400, ["error": "bilinmeyen ekransız komut \(komut)"])
            }
        } catch let sorun as Sorun {
            return (sorun.kod, ["error": sorun.mesaj])
        } catch {
            return (500, ["error": error.localizedDescription])
        }
    }

    // MARK: izinler

    // bildirim izni async okunur; son bilinen değeri burada tutup izinDurumu'nu senkron bırakıyoruz
    nonisolated(unsafe) static var bildirimDurumu = "sorulmadı"

    static func izinDurumu() -> [String: Any] {
        [
            "animsatici": ek(EKEventStore.authorizationStatus(for: .reminder)),
            "takvim": ek(EKEventStore.authorizationStatus(for: .event)),
            "kisiler": kisiIzni(CNContactStore.authorizationStatus(for: .contacts)),
            "fotograf": fotoIzni(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
            "bildirim": bildirimDurumu,
            "alarm": Alarmlar.durum(),
        ]
    }

    static func izinOzeti() -> String {
        let d = izinDurumu()
        return "Anımsatıcılar: \(d["animsatici"] ?? "")\nTakvim: \(d["takvim"] ?? "")\n"
            + "Kişiler: \(d["kisiler"] ?? "")\nFotoğraflar: \(d["fotograf"] ?? "")\n"
            + "Bildirim: \(d["bildirim"] ?? "")\nAlarm: \(d["alarm"] ?? "")"
    }

    // iOS izin sorusunu yalnız uygulama öndeyken gösterir
    static func izinleriIste() async {
        _ = try? await store.requestFullAccessToReminders()
        _ = try? await store.requestFullAccessToEvents()
        _ = try? await kisiler.requestAccess(for: .contacts)
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await bildirimIzniTazele()
        await Alarmlar.yetkiIste()
        store.reset()
    }

    static func bildirimIzniTazele() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: bildirimDurumu = "tam"
        case .denied: bildirimDurumu = "reddedildi"
        case .notDetermined: bildirimDurumu = "sorulmadı"
        @unknown default: bildirimDurumu = "bilinmiyor"
        }
    }

    private static func ek(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess: return "tam"
        case .writeOnly: return "yalnız yazma"
        case .denied, .restricted: return "reddedildi"
        case .notDetermined: return "sorulmadı"
        @unknown default: return "bilinmiyor"
        }
    }

    private static func kisiIzni(_ s: CNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "tam"
        case .limited: return "sınırlı"
        case .denied, .restricted: return "reddedildi"
        case .notDetermined: return "sorulmadı"
        @unknown default: return "bilinmiyor"
        }
    }

    private static func fotoIzni(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "tam"
        case .limited: return "sınırlı"
        case .denied, .restricted: return "reddedildi"
        case .notDetermined: return "sorulmadı"
        @unknown default: return "bilinmiyor"
        }
    }

    private static func gerek(_ izinVar: Bool, _ ne: String) throws {
        if !izinVar {
            throw Sorun(kod: 403, mesaj: "\(ne) izni yok. iPhone'da Agent'ı açıp 'İzinleri ver'e basın.")
        }
    }

    // MARK: yardımcılar

    static func sade(_ s: String) -> String {
        s.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func isoOku(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }

    private static func dolu(_ x: Any?) -> String? {
        guard let s = x as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func takvimBul(_ ad: String, tur: EKEntityType) throws -> EKCalendar {
        let ad = ad.trimmingCharacters(in: .whitespacesAndNewlines)
        if ad.isEmpty {
            let varsayilan = tur == .reminder ? store.defaultCalendarForNewReminders() : store.defaultCalendarForNewEvents
            guard let varsayilan else { throw Sorun(kod: 404, mesaj: "Varsayılan liste/takvim yok.") }
            return varsayilan
        }
        let hepsi = store.calendars(for: tur)
        guard let c = hepsi.first(where: { $0.allowsContentModifications && sade($0.title) == sade(ad) }) else {
            let adlar = hepsi.filter(\.allowsContentModifications).map(\.title).joined(separator: ", ")
            throw Sorun(kod: 404, mesaj: "'\(ad)' adında yazılabilir liste/takvim yok. Var olanlar: \(adlar)")
        }
        return c
    }

    // MARK: Anımsatıcılar

    static func animsaticilar(_ v: [String: Any]) async throws -> [[String: Any]] {
        try gerek(EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, "Anımsatıcılar")
        var listeler = store.calendars(for: .reminder)
        if let liste = dolu(v["liste"]) {
            listeler = listeler.filter { sade($0.title) == sade(liste) }
            if listeler.isEmpty { throw Sorun(kod: 404, mesaj: "'\(liste)' adında anımsatıcı listesi yok.") }
        }
        let hepsi = v["tamamlananlar"] as? Bool ?? false
        let kosul = hepsi
            ? store.predicateForReminders(in: listeler)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: listeler)
        let satirlar: [[String: Any]] = await withCheckedContinuation { devam in
            _ = store.fetchReminders(matching: kosul) { bulunan in
                let s = (bulunan ?? []).map { r -> [String: Any] in
                    var d: [String: Any] = [
                        "baslik": r.title ?? "", "liste": r.calendar?.title ?? "",
                        "kimlik": r.calendarItemIdentifier, "tamam": r.isCompleted,
                    ]
                    if let c = r.dueDateComponents, let t = Calendar.current.date(from: c) { d["zaman"] = iso(t) }
                    return d
                }
                devam.resume(returning: s)
            }
        }
        let ara = sade(v["ara"] as? String ?? "")
        let adet = v["adet"] as? Int ?? 50
        return Array(
            satirlar
                .filter { ara.isEmpty || sade($0["baslik"] as? String ?? "").contains(ara) }
                .sorted { ($0["zaman"] as? String ?? "~") < ($1["zaman"] as? String ?? "~") }
                .prefix(adet)
        )
    }

    static func animsaticiEkle(_ v: [String: Any]) throws -> [String: Any] {
        try gerek(EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, "Anımsatıcılar")
        let r = EKReminder(eventStore: store)
        r.title = v["baslik"] as? String ?? ""
        r.notes = dolu(v["notlar"])
        r.calendar = try takvimBul(v["liste"] as? String ?? "", tur: .reminder)
        var zaman: String?
        if let z = dolu(v["zaman"]), let t = isoOku(z) {
            let saatli = v["saatli"] as? Bool ?? true
            let parcalar: Set<Calendar.Component> = saatli ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            r.dueDateComponents = Calendar.current.dateComponents(parcalar, from: t)
            if saatli { r.addAlarm(EKAlarm(absoluteDate: t)) }
            zaman = iso(t)
        }
        try store.save(r, commit: true)
        var d: [String: Any] = ["baslik": r.title ?? "", "liste": r.calendar?.title ?? "", "kimlik": r.calendarItemIdentifier]
        if let zaman { d["zaman"] = zaman }
        return d
    }

    static func animsaticiTamamla(_ v: [String: Any]) throws -> [String: Any] {
        try gerek(EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, "Anımsatıcılar")
        guard let id = dolu(v["kimlik"]), let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw Sorun(kod: 404, mesaj: "hatırlatma bulunamadı")
        }
        r.isCompleted = true
        try store.save(r, commit: true)
        return ["baslik": r.title ?? ""]
    }

    // MARK: Takvim

    static func takvim(_ v: [String: Any]) throws -> [[String: Any]] {
        try gerek(EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Takvim")
        guard let b = isoOku(v["baslangic"] as? String ?? ""), let e = isoOku(v["bitis"] as? String ?? ""), e > b else {
            throw Sorun(mesaj: "tarih aralığı geçersiz")
        }
        let ara = sade(v["ara"] as? String ?? "")
        let olaylar = store.events(matching: store.predicateForEvents(withStart: b, end: e, calendars: nil))
            .filter { ara.isEmpty || sade($0.title ?? "").contains(ara) }
            .sorted { $0.startDate < $1.startDate }
        return olaylar.prefix(200).map { o -> [String: Any] in
            [
                "baslik": o.title ?? "", "baslangic": iso(o.startDate), "bitis": iso(o.endDate),
                "tum_gun": o.isAllDay, "konum": o.location ?? "", "takvim": o.calendar?.title ?? "",
            ]
        }
    }

    static func takvimEkle(_ v: [String: Any]) throws -> [String: Any] {
        try gerek(EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Takvim")
        guard let b = isoOku(v["baslangic"] as? String ?? ""), let e = isoOku(v["bitis"] as? String ?? ""), e > b else {
            throw Sorun(mesaj: "tarih aralığı geçersiz")
        }
        let tumGun = v["tum_gun"] as? Bool ?? false
        let o = EKEvent(eventStore: store)
        o.title = v["baslik"] as? String ?? ""
        o.isAllDay = tumGun
        o.startDate = b
        // tüm gün etkinlikte bitiş ertesi günün başı gelir; bir saniye geri al ki tek gün görünsün
        o.endDate = tumGun ? e.addingTimeInterval(-1) : e
        o.location = dolu(v["konum"])
        o.notes = dolu(v["notlar"])
        o.calendar = try takvimBul(v["takvim"] as? String ?? "", tur: .event)
        if let dk = v["hatirlat_dk"] as? Int, dk >= 0 {
            o.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * dk)))
        }
        try store.save(o, span: .thisEvent, commit: true)
        return ["baslik": o.title ?? "", "baslangic": iso(b), "takvim": o.calendar?.title ?? ""]
    }

    // MARK: Kişiler (yalnız okuma)

    static func kisiAra(_ v: [String: Any]) throws -> [[String: Any]] {
        let izin = CNContactStore.authorizationStatus(for: .contacts)
        try gerek(izin == .authorized || izin == .limited, "Kişiler")
        let ara = (v["ara"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let anahtarlar = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        let rakam = ara.filter(\.isNumber)
        let kosul: NSPredicate = rakam.count >= 4 && rakam.count * 2 >= ara.count
            ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: ara))
            : CNContact.predicateForContacts(matchingName: ara)
        let bulunan = try kisiler.unifiedContacts(matching: kosul, keysToFetch: anahtarlar)
        return bulunan.prefix(20).map { c -> [String: Any] in
            let telefonlar = c.phoneNumbers.map { lv -> String in
                let etiket = lv.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? ""
                return etiket.isEmpty ? lv.value.stringValue : "\(lv.value.stringValue) (\(etiket))"
            }
            return [
                "ad": [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " "),
                "firma": c.organizationName,
                "telefonlar": telefonlar,
                "epostalar": c.emailAddresses.map { $0.value as String },
            ]
        }
    }

    // MARK: Fotoğraflar (yalnız okuma)

    private static func fotoIzniVar() throws {
        let izin = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try gerek(izin == .authorized || izin == .limited, "Fotoğraflar")
    }

    static func fotograflar(_ v: [String: Any]) throws -> [[String: Any]] {
        try fotoIzniVar()
        let adet = min(max(v["adet"] as? Int ?? 10, 1), 50)
        let ekranHaric = v["ekran_haric"] as? Bool ?? false
        let secenek = PHFetchOptions()
        secenek.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        secenek.fetchLimit = ekranHaric ? adet * 4 : adet
        if let gun = v["gun"] as? Int, gun > 0 {
            secenek.predicate = NSPredicate(format: "creationDate >= %@", Date().addingTimeInterval(-86_400 * Double(gun)) as NSDate)
        }
        let sonuc = PHAsset.fetchAssets(with: .image, options: secenek)
        var out: [[String: Any]] = []
        for i in 0..<sonuc.count {
            let a = sonuc.object(at: i)
            let ekran = a.mediaSubtypes.contains(.photoScreenshot)
            if ekranHaric && ekran { continue }
            out.append([
                "kimlik": a.localIdentifier, "tarih": a.creationDate.map { iso($0) } ?? "",
                "genislik": a.pixelWidth, "yukseklik": a.pixelHeight, "ekran": ekran,
            ])
            if out.count >= adet { break }
        }
        return out
    }

    static func fotografGetir(_ v: [String: Any]) async throws -> [String: Any] {
        try fotoIzniVar()
        guard let id = dolu(v["kimlik"]),
              let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw Sorun(kod: 404, mesaj: "fotoğraf bulunamadı")
        }
        let genislik = CGFloat(min(max(v["genislik"] as? Int ?? 1200, 300), 2000))
        let oran = a.pixelWidth > 0 ? CGFloat(a.pixelHeight) / CGFloat(a.pixelWidth) : 1
        let hedef = CGSize(width: genislik, height: (genislik * oran).rounded())
        let secenek = PHImageRequestOptions()
        secenek.deliveryMode = .highQualityFormat
        secenek.isNetworkAccessAllowed = true
        secenek.resizeMode = .exact
        let jpeg: Data? = await withCheckedContinuation { devam in
            var bitti = false
            _ = PHImageManager.default().requestImage(for: a, targetSize: hedef, contentMode: .aspectFit, options: secenek) { img, _ in
                guard !bitti else { return }
                bitti = true
                devam.resume(returning: img?.jpegData(compressionQuality: 0.75))
            }
        }
        guard let jpeg else { throw Sorun(kod: 500, mesaj: "fotoğraf okunamadı (iCloud'dan inmemiş olabilir)") }
        return [
            "image": jpeg.base64EncodedString(), "tarih": a.creationDate.map { iso($0) } ?? "",
            "genislik": Int(hedef.width), "yukseklik": Int(hedef.height),
        ]
    }

    // MARK: alarm/sayaç girdi yardımcıları

    static func tarihZorunlu(_ v: [String: Any]) throws -> Date {
        guard let d = isoOku(v["zaman"] as? String ?? "") else { throw Sorun(mesaj: "geçerli zaman ver (ISO)") }
        guard d > Date().addingTimeInterval(5) else { throw Sorun(mesaj: "zaman gelecekte olmalı") }
        return d
    }

    static func saniyeZorunlu(_ v: [String: Any]) throws -> TimeInterval {
        let sn = (v["saniye"] as? NSNumber)?.doubleValue ?? 0
        guard sn >= 1, sn <= 86_400 else { throw Sorun(mesaj: "saniye 1-86400 arası olmalı") }
        return sn
    }

    // MARK: Bildirim (Claude'dan uyarı — ekransız)

    static func bildirimKur(_ v: [String: Any]) async throws -> [String: Any] {
        await bildirimIzniTazele()
        guard bildirimDurumu == "tam" else {
            throw Sorun(kod: 403, mesaj: "Bildirim izni yok. iPhone'da Agent'ı açıp 'İzinleri ver'e basın.")
        }
        guard let baslik = dolu(v["baslik"]) ?? dolu(v["govde"]) else { throw Sorun(mesaj: "başlık ya da gövde ver") }
        let govde = dolu(v["govde"]) ?? ""
        let icerik = UNMutableNotificationContent()
        icerik.title = baslik
        if !govde.isEmpty { icerik.body = govde }
        icerik.sound = .default

        let trigger: UNNotificationTrigger
        var nezaman = ""
        if let z = dolu(v["zaman"]), let t = isoOku(z) {
            let aralik = t.timeIntervalSinceNow
            guard aralik > 1 else { throw Sorun(mesaj: "zaman gelecekte olmalı") }
            let parcalar = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
            trigger = UNCalendarNotificationTrigger(dateMatching: parcalar, repeats: false)
            nezaman = iso(t)
        } else {
            let sn = (v["saniye"] as? NSNumber)?.doubleValue ?? 0
            guard sn >= 1 else { throw Sorun(mesaj: "zaman ya da saniye ver") }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: sn, repeats: false)
            nezaman = iso(Date().addingTimeInterval(sn))
        }
        let id = UUID().uuidString
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: icerik, trigger: trigger)
        )
        return ["kimlik": id, "baslik": baslik, "zaman": nezaman]
    }

    static func bildirimler() async -> [[String: Any]] {
        let bekleyen = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return bekleyen.compactMap { r in
            var zaman = ""
            if let t = r.trigger as? UNCalendarNotificationTrigger, let d = t.nextTriggerDate() {
                zaman = iso(d)
            } else if let t = r.trigger as? UNTimeIntervalNotificationTrigger, let d = t.nextTriggerDate() {
                zaman = iso(d)
            }
            return ["kimlik": r.identifier, "baslik": r.content.title, "govde": r.content.body, "zaman": zaman]
        }
    }

    static func bildirimIptal(_ v: [String: Any]) -> [String: Any] {
        guard let id = dolu(v["kimlik"]) else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return ["ok": true, "hepsi": true]
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        return ["ok": true]
    }

    // MARK: Telefon durumu (okuma)

    static func cihazDurumu() async -> [String: Any] {
        let (seviye, pilDurum): (Float, String) = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let d: String
            switch UIDevice.current.batteryState {
            case .charging: d = "şarj oluyor"
            case .full: d = "dolu"
            case .unplugged: d = "prizde değil"
            default: d = "bilinmiyor"
            }
            return (UIDevice.current.batteryLevel, d)
        }
        var sonuc: [String: Any] = [
            "pil_yuzde": seviye < 0 ? -1 : Int((seviye * 100).rounded()),
            "pil_durum": pilDurum,
            "dusuk_guc": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "sicaklik": sicaklik(ProcessInfo.processInfo.thermalState),
        ]
        // depolama
        if let vals = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            if let bos = vals.volumeAvailableCapacityForImportantUsage { sonuc["bos_depolama_gb"] = gb(bos) }
            if let toplam = vals.volumeTotalCapacity { sonuc["toplam_depolama_gb"] = gb(Int64(toplam)) }
        }
        // ağ
        let ag = await aginDurumu()
        sonuc["ag"] = ag.0
        sonuc["wifi"] = ag.1
        // hücresel / uçak modu çıkarımı
        let tasiyici = CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology?.values.first
        sonuc["hucresel_teknoloji"] = tasiyici.map { $0.replacingOccurrences(of: "CTRadioAccessTechnology", with: "") } ?? "yok"
        if ag.0 == "yok" {
            sonuc["ucak_modu"] = "muhtemelen açık (ağ yok; iOS uçak modunu doğrudan bildirmez)"
        }
        return sonuc
    }

    private static func gb(_ bayt: Int64) -> Double {
        (Double(bayt) / 1_000_000_000 * 10).rounded() / 10
    }

    private static func sicaklik(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "normal"
        case .fair: return "ılık"
        case .serious: return "sıcak"
        case .critical: return "kritik"
        @unknown default: return "bilinmiyor"
        }
    }

    private static func aginDurumu() async -> (String, Bool) {
        await withCheckedContinuation { devam in
            let monitor = NWPathMonitor()
            let kuyruk = DispatchQueue(label: "ag-durum")
            let bitti = NSLock()
            var verildi = false
            func tamamla(_ sonuc: (String, Bool)) {
                bitti.lock(); defer { bitti.unlock() }
                guard !verildi else { return }
                verildi = true
                monitor.cancel()
                devam.resume(returning: sonuc)
            }
            monitor.pathUpdateHandler = { path in
                let tur: String
                if path.status != .satisfied {
                    tur = "yok"
                } else if path.usesInterfaceType(.wifi) {
                    tur = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    tur = "hücresel"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    tur = "kablolu"
                } else {
                    tur = "bağlı"
                }
                tamamla((tur, path.usesInterfaceType(.wifi)))
            }
            monitor.start(queue: kuyruk)
            kuyruk.asyncAfter(deadline: .now() + 2) { tamamla(("yok", false)) }
        }
    }
}
