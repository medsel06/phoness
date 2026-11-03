import Foundation
import MachO
import ObjectiveC

// Salt okunur tersine mühendislik: telefondaki iOS'ta bir adın (ör. "ModelContextProtocol") izini arar.
// 1) /System/Library/{Frameworks,PrivateFrameworks} altında adı eşleşen çerçeveler
// 2) ilgili çerçeveleri yükleyip Objective-C/Swift sınıf adlarında arama
// 3) yüklü kütüphanelerin __TEXT,__cstring bölümlerinde yazı arama (örnek satırlarla)
// Hiçbir şeyi değiştirmez; yalnız okur.
enum SistemAra {
    static let yuklenecek = ["mcp", "modelcontext", "appintent", "intelligence", "siri", "foundationmodel", "agent"]

    static func calistir(_ veri: [String: Any]) -> [String: Any] {
        let desenler = ((veri["desenler"] as? [String]) ?? ["ModelContextProtocol", "MCPServer", "MCPTool", "MCPClient"])
            .filter { !$0.isEmpty }.prefix(10).map { $0 }
        let fm = FileManager.default

        // 1) çerçeve adları
        var cerceveler: [String] = []
        var yukle: [String] = []
        for dir in ["/System/Library/Frameworks", "/System/Library/PrivateFrameworks"] {
            for ad in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let k = ad.lowercased()
                if desenler.contains(where: { k.contains($0.lowercased()) }) { cerceveler.append("\(dir)/\(ad)") }
                if yuklenecek.contains(where: { k.contains($0) }) { yukle.append("\(dir)/\(ad)") }
            }
        }

        // 2) ilgili çerçeveleri yükle (en çok 80), sınıf adlarında ara
        var yuklenen = 0
        for yol in yukle.prefix(80) {
            let ad = ((yol as NSString).lastPathComponent as NSString).deletingPathExtension
            if dlopen("\(yol)/\(ad)", RTLD_LAZY) != nil { yuklenen += 1 }
        }
        var siniflar: [String] = []
        let beklenen = objc_getClassList(nil, 0)
        if beklenen > 0 {
            let tampon = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(beklenen))
            defer { tampon.deallocate() }
            let gelen = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(tampon), beklenen)
            for i in 0..<Int(min(beklenen, gelen)) {
                let ad = NSStringFromClass(tampon[i])
                let k = ad.lowercased()
                if desenler.contains(where: { k.contains($0.lowercased()) }) { siniflar.append(ad) }
            }
        }

        // 3) yüklü kütüphanelerin yazılarında ara
        var yazilar: [[String: Any]] = []
        let aranan = desenler.map { Array($0.utf8) }
        for i in 0..<_dyld_image_count() {
            guard let baslik = _dyld_get_image_header(i), let adC = _dyld_get_image_name(i) else { continue }
            let kutuphane = String(cString: adC)
            // hız için yalnız ilgili kütüphaneler (Debug derlemede bayt bayt tarama yavaş)
            let kk = kutuphane.lowercased()
            guard (yuklenecek + desenler.map { $0.lowercased() }).contains(where: { kk.contains($0) }) else { continue }
            var ornekler: [String] = []
            var sayi = 0
            baslik.withMemoryRebound(to: mach_header_64.self, capacity: 1) { h in
                for bolum in ["__cstring", "__oslogstring"] {
                    var boy: UInt = 0
                    guard let p = getsectiondata(h, "__TEXT", bolum, &boy), boy > 0 else { continue }
                    let tampon = UnsafeBufferPointer(start: p, count: Int(boy))
                    var bas = 0
                    for j in 0..<tampon.count where tampon[j] == 0 {
                        if j > bas {
                            let parca = tampon[bas..<j]
                            if aranan.contains(where: { d in parca.count >= d.count && parca.firstRange(of: d) != nil }) {
                                sayi += 1
                                if ornekler.count < 6 {
                                    ornekler.append(String(decoding: parca.prefix(160), as: UTF8.self))
                                }
                            }
                        }
                        bas = j + 1
                    }
                }
            }
            if sayi > 0 { yazilar.append(["kutuphane": kutuphane, "sayi": sayi, "ornekler": ornekler]) }
        }

        return [
            "ios": ProcessInfo.processInfo.operatingSystemVersionString,
            "desenler": desenler,
            "cerceveler": cerceveler,
            "yuklenen_cerceve": yuklenen,
            "siniflar": Array(siniflar.sorted().prefix(300)),
            "sinif_sayisi": siniflar.count,
            "yazilar": Array(yazilar.prefix(60)),
        ]
    }
}
