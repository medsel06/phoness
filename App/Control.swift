import Foundation
import Network
import NetworkExtension
import Observation
import Launcher

// app ids as installed. sideloading with a free apple account (Sideloadly, AltStore...) usually appends the
// team id to every bundle id: com.medsel06.agent -> com.medsel06.agent.NX5562CYLD and
// com.medsel06.agent.runner.xctrunner -> com.medsel06.agent.runner.xctrunner.NX5562CYLD.
// ids derived from Bundle.main.bundleIdentifier have to put that suffix back at the end.
enum AppID {
    static let full = Bundle.main.bundleIdentifier ?? "com.jxherc.agent"
    // ".TEAMID" when the last component looks like a team id (10 chars, A-Z and 0-9), else ""
    static let suffix: String = {
        guard let last = full.split(separator: ".").last, last.count == 10,
              last.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return "" }
        return "." + last
    }()
    static let base = suffix.isEmpty ? full : String(full.dropLast(suffix.count))
    // BGTaskSchedulerPermittedIdentifiers is written at build time ($(PRODUCT_BUNDLE_IDENTIFIER).run.*),
    // so take the prefix from Info.plist instead of the (possibly re-signed) bundle id
    static let bgPrefix: String = {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        if let p = permitted?.first(where: { $0.hasSuffix(".run.*") }) { return String(p.dropLast()) }
        return base + ".run."
    }()
}

// the runner is the ui test bundle (Runner target). it serves http on the phone's loopback.
enum Runner {
    static let port: UInt16 = 8123
    // project.yml names the runner <app id>.runner, xcode adds .xctrunner
    static let bundle = AppID.base + ".runner.xctrunner" + AppID.suffix

    struct Failure: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    // "dev" matches a runner started from xcode (RUNNER_DEV in the scheme).
    // the launcher swaps in a fresh one each time it starts the runner.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = "dev"
    static var token: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    // ephemeral: nothing from the runner (screenshots, screen text) goes to the disk cache
    private static let session = URLSession(configuration: .ephemeral)

    static func call(_ path: String, body: [String: Any]? = nil, timeout: Double = 60) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.timeoutInterval = timeout
        req.setValue(token, forHTTPHeaderField: "x-runner-token")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status) else {
            let msg = (obj as? [String: Any])?["error"] as? String ?? "runner answered http \(status)"
            throw Failure(status: status, message: msg)
        }
        if let dict = obj as? [String: Any] { return dict }
        if let arr = obj as? [Any] { return ["list": arr] }
        return [:]
    }

    static func alive() async -> Bool {
        (try? await call("/status", timeout: 1.5))?["ok"] as? Bool == true
    }
}

@Observable @MainActor
final class Control {
    enum Phase { case off, starting, on, failed }

    var phase: Phase = .off
    var message = ""
    var hasPairing = false
    var apps: [[String: String]] = []

    static let shared = Control()

    private var job: Task<Void, Never>?
    private var jobID: UUID?

    init() {
        Self.securePairing()
        hasPairing = Self.pairingURL != nil
    }

    // scripts/setup.sh copies it here, or it comes in through Import Pairing File.
    // it's a full paired-host credential for this phone, never bundled with the app.
    static var pairingFile: URL {
        URL.applicationSupportDirectory.appending(path: "pairing.plist")
    }

    static var pairingURL: URL? {
        FileManager.default.fileExists(atPath: pairingFile.path) ? pairingFile : nil
    }

    static var ddiDir: URL? {
        Bundle.main.url(forResource: "DDI", withExtension: nil, subdirectory: "Device")
    }

    // keep it out of backups and unreadable while the phone is locked
    static func securePairing() {
        guard var url = pairingURL else { return }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func importPairing(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            // a remote pairing file (setup.sh, stikpair). the old lockdown kind has HostPrivateKey
            guard plist?["private_key"] != nil, plist?["identifier"] != nil else {
                message = "That isn't a remote pairing file."
                return
            }
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: Self.pairingFile, options: [.atomic, .completeFileProtection])
            Self.securePairing()
            hasPairing = true
            message = ""
        } catch {
            message = "Couldn't import: \(error.localizedDescription)"
        }
    }

    // safe to call a lot. returns once the runner answers, start failed, or the caller got cancelled.
    func ensureOn() async -> Bool {
        if await Runner.alive() {
            if phase != .on || apps.isEmpty { await up() }
            return true
        }
        // the agent got stopped while we checked, don't go popping passcode prompts
        if Task.isCancelled { return false }
        if job == nil { start() }
        while job != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return phase == .on
    }

    func start() {
        guard job == nil else { return }
        let id = UUID()
        jobID = id
        job = Task {
            await run()
            // a stop + start while this one was finishing owns job now
            if jobID == id {
                job = nil
                jobID = nil
            }
        }
    }

    private func run() async {
        phase = .starting
        message = ""
        if await Runner.alive() { return await up() }

        #if targetEnvironment(simulator)
        fail("In the simulator, start the runner from Xcode with Product > Test.")
        #else
        guard let pairing = Self.pairingURL else {
            return fail("No pairing file yet. Run scripts/setup.sh, or import one below.")
        }
        guard let ddi = Self.ddiDir else {
            return fail("The developer disk image is missing. Run scripts/setup.sh again.")
        }

        // the built-in vpn needs a paid apple team. a free team builds without it (setup.sh
        // FREE_ACCOUNT=1) and uses LocalDevVPN from the app store, which routes the same address
        message = "Turning on the VPN"
        var vpnError: Error?
        do { try await Tunnel.on() } catch { vpnError = error }
        if Task.isCancelled { return }
        guard await Tunnel.reachable() else {
            if Task.isCancelled { return }
            let why = vpnError.map { " (\($0.localizedDescription))" } ?? ""
            return fail("No loopback VPN is on\(why). On a free Apple account, install LocalDevVPN from the App Store, turn it on, then try again.")
        }
        guard let rpPort = await Self.remotePairingPort() else {
            if Task.isCancelled { return }
            return fail("Can't reach this \(Device.name)'s remote pairing service. It needs Wi-Fi on. Turn it on and try again.")
        }

        Runner.token = UUID().uuidString
        launcher_start(pairing.path, ddi.path, Runner.bundle, rpPort, Runner.port, Runner.token)

        // the passcode prompt can take a while, give it 2 minutes
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            let msg = Self.take(launcher_message())
            if !msg.isEmpty { message = msg.prefix(1).uppercased() + msg.dropFirst() }
            if launcher_phase() == 3 { return fail(message) }
            if await Runner.alive() { return await up() }
        }
        launcher_stop()
        fail("The runner didn't start in 2 minutes. Try Turn On again.")
        #endif
    }

    private func up() async {
        phase = .on
        message = ""
        await loadApps()
        // give the runner the app list so it can tell which app is in front
        _ = try? await Runner.call("/known", body: ["apps": apps.compactMap { $0["id"] }])
    }

    private func fail(_ msg: String) {
        phase = .failed
        message = msg
    }

    func stop() {
        job?.cancel()
        job = nil
        jobID = nil
        Task { _ = try? await Runner.call("/stop", body: [:], timeout: 2) }
        #if !targetEnvironment(simulator)
        launcher_stop()
        Task { await Tunnel.off() }
        #endif
        phase = .off
        message = ""
    }

    func loadApps() async {
        var list: [[String: String]] = []
        #if !targetEnvironment(simulator)
        // the launcher grabs the list while it starts the runner. empty when xcode started it
        let json = Self.take(launcher_apps())
        if let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: String]] {
            list = arr.filter { $0["type"] == "User" || $0["type"] == "System" }
        }
        #endif
        if list.isEmpty, let res = try? await Runner.call("/apps"), let arr = res["list"] as? [[String: String]] {
            list = arr
        }
        apps = list.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
    }

    // the phone's own remotepairingd, reached through the loopback vpn. it's nearly always
    // on 49152. if not, bonjour knows (that asks for local network access the first time)
    static func remotePairingPort() async -> UInt16? {
        if await Tunnel.reachable(port: 49152) { return 49152 }
        for port in await Bonjour.ports(of: "_remotepairing._tcp.", timeout: 3) where port != 49152 {
            if await Tunnel.reachable(port: port) { return port }
        }
        return nil
    }

    nonisolated static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { launcher_free(p) }
        return String(cString: p)
    }
}

// the loopback vpn lives in the Tunnel extension
enum Tunnel {
    static let bundle = (Bundle.main.bundleIdentifier ?? "com.jxherc.agent") + ".tunnel"

    struct Failure: LocalizedError {
        var errorDescription: String? { "The VPN didn't connect." }
    }

    static func manager() async throws -> NETunnelProviderManager {
        let m = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = bundle
        proto.serverAddress = "10.7.0.1"
        m.protocolConfiguration = proto
        m.localizedDescription = "Agent loopback"
        m.isEnabled = true
        // first time this shows the "add vpn configuration" prompt
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        return m
    }

    static func on() async throws {
        let m = try await manager()
        if m.connection.status == .connected { return }
        try m.connection.startVPNTunnel()
        for _ in 0..<40 {
            if m.connection.status == .connected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure()
    }

    // true when some loopback vpn (ours or LocalDevVPN) gets us to the phone itself.
    // lockdownd still finishes the tcp handshake before it drops vpn clients, so 62078 works as a check
    static func reachable(host: String = "10.7.0.1", port: UInt16 = 62078, timeout: Double = 2) async -> Bool {
        await withCheckedContinuation { cont in
            Probe(host: host, port: port, cont: cont).start(timeout: timeout)
        }
    }

    // one tcp connect attempt. everything runs on its own serial queue, so it answers once
    private final class Probe: @unchecked Sendable {
        let q = DispatchQueue(label: "reach")
        let conn: NWConnection
        var cont: CheckedContinuation<Bool, Never>?

        init(host: String, port: UInt16, cont: CheckedContinuation<Bool, Never>) {
            conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
            self.cont = cont
        }

        func start(timeout: Double) {
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: self.finish(true)
                case .failed, .waiting: self.finish(false)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { self.finish(false) }
        }

        func finish(_ ok: Bool) {
            guard let c = cont else { return }
            cont = nil
            conn.cancel()
            c.resume(returning: ok)
        }
    }

    static func off() async {
        (try? await NETunnelProviderManager.loadAllFromPreferences())?.first?.connection.stopVPNTunnel()
    }
}

// the ports a bonjour service type shows up on. lists other devices on the wifi too,
// so callers check which one answers at 10.7.0.1
@MainActor
final class Bonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var found: [NetService] = []
    private var ports: Set<UInt16> = []

    static func ports(of type: String, timeout: Double) async -> [UInt16] {
        let b = Bonjour()
        b.browser.delegate = b
        b.browser.searchForServices(ofType: type, inDomain: "local.")
        try? await Task.sleep(for: .seconds(timeout))
        b.browser.stop()
        b.found.forEach { $0.stop() }
        return Array(b.ports)
    }

    // both get called on the main run loop, where the browser was made
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            found.append(service)
            service.delegate = self
            service.resolve(withTimeout: 2)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            if sender.port > 0 { ports.insert(UInt16(sender.port)) }
        }
    }
}
