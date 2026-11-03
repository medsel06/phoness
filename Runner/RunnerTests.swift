import XCTest

// not really a test. it's a long running xctest that serves a small http api
// so the app can see the screen and tap/type anywhere on the phone.
final class RunnerTests: XCTestCase {
    private var phone: Phone!

    override func record(_ issue: XCTIssue) {
        // don't fail the run, just hand the message back to the agent
        Phone.lastIssue = issue.compactDescription
    }

    @MainActor
    func testServe() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["RUNNER_PORT"] ?? "") ?? 8123

        // the app's launcher passes a fresh token. runs from xcode get RUNNER_DEV=1 from the
        // scheme (project.yml) and use "dev". with neither, don't serve at all.
        var token = env["RUNNER_TOKEN"] ?? ""
        if token.isEmpty, env["RUNNER_DEV"] == "1" { token = "dev" }
        guard !token.isEmpty else {
            NSLog("runner: no RUNNER_TOKEN and not a dev run, not serving")
            return
        }

        let phone = Phone()
        self.phone = phone
        let server = try Server(port: port, token: token) { req in
            MainActor.assumeIsolated { phone.handle(req) }
        }
        server.onFail = { msg in
            NSLog("runner: %@", msg)
            DispatchQueue.main.async { phone.stopped = true }
        }
        server.start()
        NSLog("runner listening on 127.0.0.1:%d", port)
        while !phone.stopped {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }
}

@MainActor
final class Phone {
    // xctest can record issues from any thread
    private nonisolated static let issueLock = NSLock()
    private nonisolated(unsafe) static var issue: String?
    nonisolated static var lastIssue: String? {
        get { issueLock.withLock { issue } }
        set { issueLock.withLock { issue = newValue } }
    }

    var stopped = false
    private let statusBridge = StatusBridge()
    private var current: String?
    private var known: [String] = []
    // most recent first, so the slow scan usually hits early
    private var recent: [String] = []
    // reusing these skips xctest's per-instance setup, which is slow
    private var cache: [String: XCUIApplication] = [:]
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    // the whole screen in points, as the last screenshot showed it. springboard's frame stays
    // portrait when the screen turns (ipads in landscape), so look() takes it from the screenshot
    private var screen = CGSize(width: 1, height: 1)

    private func handleFor(_ id: String) -> XCUIApplication {
        if id == "com.apple.springboard" { return springboard }
        if let a = cache[id] { return a }
        let a = XCUIApplication(bundleIdentifier: id)
        cache[id] = a
        return a
    }

    init() {
        Self.skipIdleWaits()
        known = Self.installedApps().map { $0["id"] ?? "" }.filter { !$0.isEmpty }
        // a first guess for an act before any look
        let s = springboard.frame.size
        if s.width > 1, s.height > 1 { screen = s }
    }

    // xctest waits for an app to stop animating before every action. busy apps never do,
    // so one tap can hang for a minute. skip the wait like webdriveragent does
    // and settle with a short fixed delay after each action instead.
    nonisolated(unsafe) static var skipIdle = true

    static func skipIdleWaits() {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { return }

        // (BOOL animations, BOOL preEvent). only swap it if the encoding is exactly that
        let two = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        if let m = class_getInstanceMethod(cls, two), encoding(m) == "v24@0:8B16B20" {
            typealias F = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { obj, a, b in
                if !Phone.skipIdle { orig(obj, two, a, b) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        // (BOOL animations, BOOL usingActivity, BOOL preEvent)
        let three = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:")
        if let m = class_getInstanceMethod(cls, three), encoding(m) == "v28@0:8B16B20B24" {
            typealias F = @convention(c) (AnyObject, Selector, Bool, Bool, Bool) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, Bool, Bool, Bool) -> Void = { obj, a, b, c in
                if !Phone.skipIdle { orig(obj, three, a, b, c) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    private static func encoding(_ m: Method) -> String {
        method_getTypeEncoding(m).map { String(cString: $0) } ?? ""
    }

    // the method, if it's there with exactly this signature. prints what it found otherwise
    private static func method(_ cls: AnyClass, _ name: String, _ enc: String) -> Method? {
        guard let m = class_getInstanceMethod(cls, NSSelectorFromString(name)) else {
            print("typeDirect: no \(name)")
            return nil
        }
        guard encoding(m) == enc else {
            print("typeDirect: \(name) is \(encoding(m)), wanted \(enc)")
            return nil
        }
        return m
    }

    // app.typeText first asks for the element with keyboard focus, and in some apps that
    // query never comes back (reminders' new-reminder sheet hung the runner for minutes).
    // webdriveragent sidesteps it the same way: build the text event ourselves and hand it
    // straight to xctest's event synthesizer. false means a piece is missing, use typeText.
    static func typeDirect(_ text: String) -> Bool {
        guard let pathCls = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let recCls = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let mInit = method(pathCls, "initForTextInput", "@16@0:8"),
              let mType = method(pathCls, "typeText:atOffset:typingSpeed:shouldRedact:", "v44@0:8@16d24Q32B40"),
              let mRec = method(recCls, "initWithName:interfaceOrientation:", "@32@0:8@16q24"),
              method(recCls, "addPointerEventPath:", "v24@0:8@16") != nil
        else { return false }
        let device = XCUIDevice.shared as NSObject
        guard let mSynth = method(type(of: device), "eventSynthesizer", "@16@0:8") else { return false }
        let synthObj = unsafeBitCast(method_getImplementation(mSynth), to: (@convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?).self)(device, NSSelectorFromString("eventSynthesizer"))?.takeUnretainedValue()
        guard let synth = synthObj as? NSObject,
              let mFire = method(type(of: synth), "synthesizeEvent:completion:", "@32@0:8@16@?24")
        else { return false }

        // alloc hands back +1, init returns the same object, so these balance
        typealias Init = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
        guard let rawPath = pathCls.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() else { return false }
        let path = unsafeBitCast(method_getImplementation(mInit), to: Init.self)(rawPath, NSSelectorFromString("initForTextInput")).takeUnretainedValue()
        typealias TypeText = @convention(c) (AnyObject, Selector, NSString, Double, UInt64, Bool) -> Void
        // 60 characters a second, what webdriveragent uses
        unsafeBitCast(method_getImplementation(mType), to: TypeText.self)(path, NSSelectorFromString("typeText:atOffset:typingSpeed:shouldRedact:"), text as NSString, 0, 60, false)

        typealias InitRec = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
        guard let rawRec = recCls.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() else { return false }
        let orientation = (1...4).contains(XCUIDevice.shared.orientation.rawValue) ? XCUIDevice.shared.orientation.rawValue : 1
        let record = unsafeBitCast(method_getImplementation(mRec), to: InitRec.self)(rawRec, NSSelectorFromString("initWithName:interfaceOrientation:"), "Type" as NSString, orientation).takeUnretainedValue()
        _ = (record as? NSObject)?.perform(NSSelectorFromString("addPointerEventPath:"), with: path)

        // the completion comes back on main, which we're on, so spin the run loop instead of blocking
        var done = false
        var failed: Error?
        let completion: @convention(block) (Bool, NSError?) -> Void = { _, err in
            failed = err
            done = true
        }
        // it hands something back on xcode 27 (the encoding starts with @). not needed here
        typealias Fire = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (Bool, NSError?) -> Void) -> Unmanaged<AnyObject>?
        _ = unsafeBitCast(method_getImplementation(mFire), to: Fire.self)(synth, NSSelectorFromString("synthesizeEvent:completion:"), record, completion)
        let deadline = Date().addingTimeInterval(5 + Double(text.count) / 30)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let failed { print("typeDirect: synthesize failed: \(failed)") }
        if !done { print("typeDirect: no completion in time") }
        // it went out either way. falling back now could type it twice, the next look will tell
        return true
    }

    func handle(_ req: Server.Request) -> Server.Response {
        Phone.lastIssue = nil
        switch (req.method, req.path) {
        case ("GET", "/look"):
            return look()
        case ("POST", "/act"):
            // the model's coords come from the last look, so that's the size to check them against
            return act(req.json)
        case ("GET", "/apps"):
            return .json(Self.installedApps())
        case ("POST", "/known"):
            if let ids = req.json["apps"] as? [String] { known = ids }
            return .json(["ok": true])
        case ("GET", "/bridge/status"):
            return .json(["state": statusBridge.state])
        case ("POST", "/bridge/start"):
            let config = req.json
            guard let address = config["address"] as? String, let key = config["key"] as? String,
                  statusBridge.start(address: address, key: key) else {
                return .json(["error": "invalid bridge configuration"], status: 400)
            }
            return .json(["state": statusBridge.state])
        case ("POST", "/bridge/stop"):
            statusBridge.stop()
            return .json(["state": statusBridge.state])
        case ("POST", "/stop"):
            statusBridge.stop()
            stopped = true
            return .json(["ok": true])
        default:
            return .json(["error": "no such endpoint"], status: 404)
        }
    }

    // MARK: look

    private func look() -> Server.Response {
        let (app, id) = foreground()

        // shrink to points so image pixels == tap coordinates
        let shot = XCUIScreen.main.screenshot().image
        if shot.size.width > 1, shot.size.height > 1 { screen = shot.size }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: screen, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: screen))
        }
        let jpeg = img.jpegData(compressionQuality: 0.6) ?? Data()

        var elements: String
        do {
            elements = describe(try app.snapshot(), in: app)
        } catch {
            elements = "(couldn't read elements: \(error.localizedDescription))"
        }
        // permission prompts and other system alerts belong to springboard, not the app in front
        if app != springboard {
            let alert = springboard.alerts.firstMatch
            if alert.exists, let snap = try? alert.snapshot() {
                elements += "\nsystem alert on top:\n" + describe(snap, in: springboard)
            }
        }
        return .json([
            "app": id,
            "width": screen.width,
            "height": screen.height,
            "image": jpeg.base64EncodedString(),
            "elements": elements,
        ])
    }

    // which app is in front. asks xctest's accessibility client first (private, checked at every
    // step), then falls back to asking each known app for its state, most recent first.
    private func foreground() -> (XCUIApplication, String) {
        if let id = frontBundleID() {
            remember(id)
            return (handleFor(id), id)
        }
        var seen: Set<String> = ["com.apple.springboard"]
        for id in [current].compactMap({ $0 }) + recent + known {
            guard seen.insert(id).inserted else { continue }
            let app = handleFor(id)
            if app.state == .runningForeground {
                remember(id)
                return (app, id)
            }
        }
        current = nil
        return (springboard, "com.apple.springboard")
    }

    private func remember(_ id: String) {
        current = id == "com.apple.springboard" ? nil : id
        guard id != "com.apple.springboard" else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 12 { recent.removeLast() }
    }

    private func frontBundleID() -> String? {
        let dev = XCUIDevice.shared as NSObject
        func get(_ obj: NSObject, _ name: String) -> NSObject? {
            let sel = NSSelectorFromString(name)
            guard obj.responds(to: sel) else { return nil }
            return obj.perform(sel)?.takeUnretainedValue() as? NSObject
        }
        guard let ax = get(dev, "accessibilityInterface"),
              let apps = get(ax, "activeApplications") as? [NSObject],
              let front = apps.first,
              front.responds(to: NSSelectorFromString("processIdentifier")),
              let pid = (front.value(forKey: "processIdentifier") as? NSNumber)?.int32Value, pid > 0,
              let monitor = get(dev, "applicationMonitor")
        else { return nil }

        let byPID = NSSelectorFromString("applicationProcessWithPID:")
        guard let m = class_getInstanceMethod(type(of: monitor), byPID),
              Self.encoding(m).hasSuffix("i16") else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, Int32) -> Unmanaged<AnyObject>?
        let f = unsafeBitCast(method_getImplementation(m), to: F.self)
        guard let proc = f(monitor, byPID, pid)?.takeUnretainedValue() as? NSObject,
              proc.responds(to: NSSelectorFromString("bundleID")),
              let id = proc.value(forKey: "bundleID") as? String, !id.isEmpty
        else { return nil }
        return id
    }

    private func describe(_ root: XCUIElementSnapshot, in app: XCUIApplication) -> String {
        let bounds = CGRect(origin: .zero, size: screen)
        var lines: [String] = []
        var keyboard = false

        func walk(_ e: XCUIElementSnapshot, parentLabel: String, shift: CGPoint) {
            if lines.count >= 300 { return }
            let t = e.elementType
            if t == .keyboard {
                keyboard = true
                return
            }

            // one element per line, so newlines in text become spaces
            let flat = { (s: String) in s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            let label = String(flat(e.label).prefix(80))
            let value = String(flat(e.value as? String ?? "").prefix(80))
            let hint = flat(e.placeholderValue ?? "")
            let f = e.frame.offsetBy(dx: shift.x, dy: shift.y).intersection(bounds)

            let named = !label.isEmpty || !value.isEmpty || !hint.isEmpty
            // unnamed cells and containers are just noise, their children carry the text
            let skip = [.application, .window].contains(t)
                || ([.other, .cell, .table, .collectionView, .scrollView].contains(t) && label.isEmpty)
                || label.contains("scroll bar,")
            // a text inside a button with the same label says nothing new
            let repeat_ = !label.isEmpty && label == parentLabel && value.isEmpty && !Self.tappable.contains(t)
            if !f.isNull, f.width > 1, f.height > 1, named || Self.tappable.contains(t), !skip, !repeat_ {
                var line = Self.name(t)
                if !label.isEmpty { line += " \"\(label)\"" }
                if !value.isEmpty, value != label { line += " value=\"\(value)\"" }
                if !hint.isEmpty, value.isEmpty { line += " placeholder=\"\(hint)\"" }
                if e.isSelected { line += " selected" }
                if !e.isEnabled { line += " disabled" }
                line += " @ \(Int(f.midX)),\(Int(f.midY))"
                if lines.last != line { lines.append(line) }
            }
            for c in e.children { walk(c, parentLabel: label.isEmpty ? parentLabel : label, shift: shift) }
        }
        // on an ipad an app can sit in a window away from 0,0, and the snapshot puts each window
        // at 0,0 anyway. the live window query knows where it really is on screen
        var w = 0
        for c in root.children {
            var shift = CGPoint.zero
            if c.elementType == .window {
                let live = app.windows.element(boundBy: w).frame
                w += 1
                if c.frame.origin == .zero, live.width > 1 { shift = live.origin }
            }
            walk(c, parentLabel: "", shift: shift)
        }

        if keyboard { lines.append("(keyboard is open)") }
        return lines.isEmpty ? "(no readable elements, use the screenshot)" : lines.joined(separator: "\n")
    }

    static let tappable: [XCUIElement.ElementType] = [
        .button, .textField, .secureTextField, .searchField, .textView, .switch, .toggle,
        .slider, .link, .cell, .tab, .segmentedControl, .stepper, .picker, .pickerWheel, .menuItem,
    ]

    static func name(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .button: "button"
        case .staticText: "text"
        case .textField: "field"
        case .secureTextField: "password field"
        case .searchField: "search field"
        case .textView: "text area"
        case .image, .icon: "image"
        case .cell: "cell"
        case .link: "link"
        case .switch, .toggle: "switch"
        case .slider: "slider"
        case .tab: "tab"
        case .segmentedControl: "segments"
        case .navigationBar: "nav bar"
        case .alert: "alert"
        case .sheet: "sheet"
        case .webView: "web view"
        case .picker, .pickerWheel: "picker"
        case .menuItem: "menu item"
        case .table, .collectionView, .scrollView: "list"
        default: "element"
        }
    }

    // MARK: act

    private func act(_ a: [String: Any]) -> Server.Response {
        let action = a["action"] as? String ?? ""
        let (app, _) = foreground()
        // springboard covers the whole screen. the app in front doesn't on an ipad, where it can
        // sit in a window away from 0,0, and coords from the screenshot are whole-screen
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        // model input, so everything gets clamped before it touches xctest
        func num(_ k: String) -> Double? {
            guard let d = (a[k] as? NSNumber)?.doubleValue, d.isFinite else { return nil }
            return d
        }
        func seconds(_ fallback: Double) -> Double { min(max(num("seconds") ?? fallback, 0.1), 10) }
        func point(_ kx: String, _ ky: String) -> XCUICoordinate? {
            guard let x = num(kx), let y = num(ky),
                  (0...screen.width).contains(x), (0...screen.height).contains(y) else { return nil }
            return origin.withOffset(CGVector(dx: x, dy: y))
        }
        let text = a["text"] as? String ?? ""

        switch action {
        case "tap", "double_tap", "long_press":
            guard let p = point("x", "y") else {
                return bad("\(action) needs x and y on screen (0-\(Int(screen.width)), 0-\(Int(screen.height)))")
            }
            if action == "tap" { p.tap() }
            if action == "double_tap" { p.doubleTap() }
            if action == "long_press" { p.press(forDuration: seconds(1)) }
        case "swipe":
            guard let from = point("x", "y"), let to = point("to_x", "to_y") else {
                return bad("swipe needs x, y, to_x, to_y, all on screen")
            }
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        case "type":
            guard !text.isEmpty else { return bad("type needs text") }
            guard text.count <= 2000 else { return bad("type takes up to 2000 characters at a time") }
            if !Self.typeDirect(text) { app.typeText(text) }
        case "key":
            let keys: [String: String] = [
                "return": XCUIKeyboardKey.return.rawValue, "enter": XCUIKeyboardKey.return.rawValue,
                "delete": XCUIKeyboardKey.delete.rawValue, "backspace": XCUIKeyboardKey.delete.rawValue,
                "tab": XCUIKeyboardKey.tab.rawValue, "space": " ",
            ]
            guard let k = keys[text.lowercased()] else { return bad("unknown key \(text)") }
            let times = Int(min(max(num("count") ?? 1, 1), 50))
            let keys2 = String(repeating: k, count: times)
            if !Self.typeDirect(keys2) { app.typeText(keys2) }
        case "home":
            XCUIDevice.shared.press(.home)
            current = nil
        case "open_app":
            guard let id = a["bundle_id"] as? String, !id.isEmpty else { return bad("open_app needs bundle_id") }
            handleFor(id).activate()
            remember(id)
            // no idle wait anymore, give the launch a moment
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        case "open_url":
            guard let url = URL(string: a["url"] as? String ?? ""), url.scheme != nil else {
                return bad("open_url needs a full url")
            }
            XCUIDevice.shared.system.open(url)
            current = nil
        case "wait":
            RunLoop.current.run(until: Date().addingTimeInterval(seconds(1)))
        default:
            return bad("unknown action \(action)")
        }

        if let issue = Phone.lastIssue { return .json(["error": issue]) }
        // let animations settle before the next look
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return .json(["ok": true])
    }

    private func bad(_ msg: String) -> Server.Response { .json(["error": msg], status: 400) }

    // MARK: apps

    // private api, but this runs as a test runner so nobody's reviewing it
    static func installedApps() -> [[String: String]] {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return [] }
        let sel = NSSelectorFromString("allApplications")
        guard ws.responds(to: sel),
              let apps = ws.perform(sel)?.takeUnretainedValue() as? [NSObject]
        else { return [] }

        return apps.compactMap { p in
            let get = { (k: String) in p.responds(to: NSSelectorFromString(k)) ? p.value(forKey: k) as? String : nil }
            guard let id = get("applicationIdentifier"), let type = get("applicationType"),
                  type == "User" || type == "System",
                  let name = get("localizedName"), !name.isEmpty
            else { return nil }
            if p.responds(to: NSSelectorFromString("appTags")),
               let tags = p.value(forKey: "appTags") as? [String], tags.contains("hidden") { return nil }
            return ["id": id, "name": name]
        }
        .sorted { $0["name"]! < $1["name"]! }
    }
}
