import AppKit
import Foundation

struct VlessNode: Codable {
    var name: String
    var raw: String
    var uuid: String
    var server: String
    var port: Int
    var sni: String
    var pbk: String
    var sid: String
    var fp: String
    var flow: String
    var sourceURL: String
}

struct AppState: Codable {
    var subscriptionURLs: [String]
    var nodes: [VlessNode]
    var selectedIndex: Int?
    var lastSuccessIndex: Int?
    var autoReconnect: Bool
    var anthemMuted: Bool
    var anthemLastPlayedAt: Double
    var anthemLastTrack: String

    enum CodingKeys: String, CodingKey {
        case subscriptionURLs
        case nodes
        case selectedIndex
        case lastSuccessIndex
        case autoReconnect
        case anthemMuted
        case anthemLastPlayedAt
        case anthemLastTrack
    }

    init(
        subscriptionURLs: [String],
        nodes: [VlessNode],
        selectedIndex: Int?,
        lastSuccessIndex: Int?,
        autoReconnect: Bool,
        anthemMuted: Bool,
        anthemLastPlayedAt: Double,
        anthemLastTrack: String
    ) {
        self.subscriptionURLs = subscriptionURLs
        self.nodes = nodes
        self.selectedIndex = selectedIndex
        self.lastSuccessIndex = lastSuccessIndex
        self.autoReconnect = autoReconnect
        self.anthemMuted = anthemMuted
        self.anthemLastPlayedAt = anthemLastPlayedAt
        self.anthemLastTrack = anthemLastTrack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionURLs = try c.decodeIfPresent([String].self, forKey: .subscriptionURLs) ?? []
        nodes = try c.decodeIfPresent([VlessNode].self, forKey: .nodes) ?? []
        selectedIndex = try c.decodeIfPresent(Int.self, forKey: .selectedIndex)
        lastSuccessIndex = try c.decodeIfPresent(Int.self, forKey: .lastSuccessIndex)
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        anthemMuted = try c.decodeIfPresent(Bool.self, forKey: .anthemMuted) ?? false
        anthemLastPlayedAt = try c.decodeIfPresent(Double.self, forKey: .anthemLastPlayedAt) ?? 0
        anthemLastTrack = try c.decodeIfPresent(String.self, forKey: .anthemLastTrack) ?? ""
    }
}

final class VPNApp: NSObject, NSApplicationDelegate {
    private let socksPort = 12334
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var serversMenu: NSMenu!
    private var subsMenu: NSMenu!

    private var process: Process?
    private var isBusy = false
    private var monitorTimer: Timer?
    private var anthemSound: NSSound?
    private let anthemCooldownSeconds: Double = 180

    private var state = AppState(
        subscriptionURLs: ["https://proxyliberty.ru/connection/test_proxies_subs/48bb9885-5a2a-4129-9347-3e946e7ca5b9"],
        nodes: [],
        selectedIndex: nil,
        lastSuccessIndex: nil,
        autoReconnect: true,
        anthemMuted: false,
        anthemLastPlayedAt: 0,
        anthemLastTrack: ""
    )

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BACK_TO_USSR", isDirectory: true)
    }

    private var stateFile: URL { appSupportDir.appendingPathComponent("state.json") }
    private var runtimeConfigFile: URL { appSupportDir.appendingPathComponent("runtime-sing-box.json") }

    private var singBoxPath: String? { Bundle.main.path(forResource: "sing-box", ofType: nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareStateDir()
        loadState()

        if let icon = appStarIcon(size: 128) {
            NSApp.applicationIconImage = icon
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "★ USSR"

        menu = NSMenu()
        buildMenu()
        statusItem.menu = menu

        updateServersMenu()
        updateSubscriptionsMenu()
        setStatus("Ready")
        startMonitor()
    }

    private func prepareStateDir() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        if let loaded = try? JSONDecoder().decode(AppState.self, from: data) {
            state = loaded
            state.subscriptionURLs = state.subscriptionURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if state.subscriptionURLs.isEmpty {
                state.subscriptionURLs = ["https://proxyliberty.ru/connection/test_proxies_subs/48bb9885-5a2a-4129-9347-3e946e7ca5b9"]
            }
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile)
        }
    }

    private func buildMenu() {
        menu.removeAllItems()

        menu.addItem(makeActionItem("Connect", #selector(connectTapped)))
        menu.addItem(makeActionItem("Disconnect", #selector(disconnectTapped)))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeActionItem("Manage Subscription URLs", #selector(manageSubscriptionTapped)))
        menu.addItem(makeActionItem("Refresh Servers", #selector(refreshTapped)))

        let subsRoot = NSMenuItem(title: "Subscription URLs", action: nil, keyEquivalent: "")
        subsMenu = NSMenu()
        subsRoot.submenu = subsMenu
        menu.addItem(subsRoot)

        let serversRoot = NSMenuItem(title: "Servers", action: nil, keyEquivalent: "")
        serversMenu = NSMenu()
        serversRoot.submenu = serversMenu
        menu.addItem(serversRoot)

        menu.addItem(NSMenuItem.separator())

        let autoItem = NSMenuItem(title: "Auto Reconnect", action: #selector(toggleAutoReconnect), keyEquivalent: "")
        autoItem.target = self
        autoItem.tag = 9101
        autoItem.state = state.autoReconnect ? .on : .off
        menu.addItem(autoItem)

        let muteItem = NSMenuItem(title: "Mute Anthem", action: #selector(toggleAnthemMute), keyEquivalent: "")
        muteItem.target = self
        muteItem.tag = 9201
        muteItem.state = state.anthemMuted ? .on : .off
        menu.addItem(muteItem)

        let statusLine = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        statusLine.tag = 9001
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let ipLine = NSMenuItem(title: "Current IP: -", action: nil, keyEquivalent: "")
        ipLine.tag = 9002
        ipLine.isEnabled = false
        menu.addItem(ipLine)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeActionItem("Quit", #selector(quitTapped), key: "q"))
    }

    private func makeActionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateSubscriptionsMenu() {
        subsMenu.removeAllItems()
        if state.subscriptionURLs.isEmpty {
            let item = NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            subsMenu.addItem(item)
            return
        }

        for url in state.subscriptionURLs {
            let item = NSMenuItem(title: url, action: nil, keyEquivalent: "")
            item.isEnabled = false
            subsMenu.addItem(item)
        }
    }

    private func updateServersMenu() {
        serversMenu.removeAllItems()
        if state.nodes.isEmpty {
            let item = NSMenuItem(title: "(no servers)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            serversMenu.addItem(item)
            return
        }

        for (idx, node) in state.nodes.enumerated() {
            let item = NSMenuItem(title: node.name, action: #selector(selectServer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            item.state = (state.selectedIndex == idx) ? .on : .off
            serversMenu.addItem(item)
        }
    }

    private func setStatus(_ text: String) {
        menu.item(withTag: 9001)?.title = "Status: \(text)"
    }

    private func setIP(_ text: String) {
        menu.item(withTag: 9002)?.title = "Current IP: \(text)"
    }

    @objc private func toggleAutoReconnect() {
        state.autoReconnect.toggle()
        menu.item(withTag: 9101)?.state = state.autoReconnect ? .on : .off
        saveState()
    }

    @objc private func toggleAnthemMute() {
        state.anthemMuted.toggle()
        menu.item(withTag: 9201)?.state = state.anthemMuted ? .on : .off
        if state.anthemMuted {
            stopAnthemPlayback()
        }
        saveState()
    }

    @objc private func connectTapped() {
        guard !isBusy else { return }
        guard !state.nodes.isEmpty else {
            showInfo("No servers", "Refresh servers first.")
            return
        }
        autoConnect(reason: "manual")
    }

    @objc private func disconnectTapped() {
        stopSingBox()
        stopAnthemPlayback()
        _ = runAdminProxy(enable: false)
        setStatus("Disconnected")
        setIP("-")
    }

    @objc private func manageSubscriptionTapped() {
        let alert = NSAlert()
        alert.messageText = "Subscription URLs"
        alert.informativeText = "One URL per line. You can add unlimited links."
        if let heroPath = Bundle.main.path(forResource: "subscription_hero", ofType: "png"),
           let hero = NSImage(contentsOfFile: heroPath),
           let scaled = resizedImage(hero, to: NSSize(width: 96, height: 96)) {
            alert.icon = scaled
        } else if let icon = appStarIcon(size: 72) {
            alert.icon = icon
        }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        textView.string = state.subscriptionURLs.joined(separator: "\n")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let urls = textView.string
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            state.subscriptionURLs = Array(Set(urls)).sorted()
            saveState()
            updateSubscriptionsMenu()
            setStatus("Saved \(state.subscriptionURLs.count) URL(s)")
        }
    }

    @objc private func refreshTapped() {
        guard !isBusy else { return }
        guard !state.subscriptionURLs.isEmpty else {
            showInfo("No URL", "Add at least one subscription URL.")
            return
        }

        isBusy = true
        setStatus("Refreshing all URLs...")

        DispatchQueue.global().async {
            do {
                let nodes = try self.fetchNodesFromAllSubscriptions()
                DispatchQueue.main.async {
                    self.state.nodes = nodes
                    if let selected = self.state.selectedIndex, selected >= nodes.count {
                        self.state.selectedIndex = nil
                    }
                    self.saveState()
                    self.updateServersMenu()
                    self.setStatus("Loaded \(nodes.count) servers")
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Refresh failed")
                    self.showInfo("Refresh failed", error.localizedDescription)
                    self.isBusy = false
                }
            }
        }
    }

    @objc private func selectServer(_ sender: NSMenuItem) {
        guard sender.tag < state.nodes.count else { return }
        state.selectedIndex = sender.tag
        saveState()
        updateServersMenu()
        setStatus("Selected: \(state.nodes[sender.tag].name)")
    }

    @objc private func quitTapped() {
        stopSingBox()
        stopAnthemPlayback()
        NSApp.terminate(nil)
    }

    private func fetchNodesFromAllSubscriptions() throws -> [VlessNode] {
        var all: [VlessNode] = []
        var errors: [String] = []

        for url in state.subscriptionURLs {
            do {
                let payload = try fetchURL(url)
                let uris = decodeSubscription(payload)
                let parsed = uris.compactMap { parseVless($0, sourceURL: url) }
                if parsed.isEmpty {
                    errors.append("\(url) -> no valid VLESS")
                } else {
                    all.append(contentsOf: parsed)
                }
            } catch {
                errors.append("\(url) -> \(error.localizedDescription)")
            }
        }

        // Deduplicate by raw URI
        var seen = Set<String>()
        let dedup = all.filter {
            if seen.contains($0.raw) { return false }
            seen.insert($0.raw)
            return true
        }

        if dedup.isEmpty {
            let details = errors.prefix(3).joined(separator: "\n")
            throw NSError(domain: "refresh", code: 2, userInfo: [NSLocalizedDescriptionKey: "No valid VLESS nodes\n\(details)"])
        }
        return dedup
    }

    private func fetchURL(_ urlString: String) throws -> String {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "url", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("BACK_TO_USSR/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")

        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var outErr: Error?

        URLSession.shared.dataTask(with: req) { data, _, err in
            outData = data
            outErr = err
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)

        if let err = outErr {
            throw err
        }
        let text = String(data: outData ?? Data(), encoding: .utf8) ?? ""
        return text
    }

    private func decodeSubscription(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Some providers return plain vless lines directly.
        if trimmed.contains("vless://") {
            return trimmed
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("vless://") }
        }

        let compact = trimmed.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        var candidates: [String] = []
        let normal = compact
        let urlsafeToStd = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")

        for base in [normal, urlsafeToStd] {
            candidates.append(base)
            candidates.append(base + "=")
            candidates.append(base + "==")
            candidates.append(base + "===")
        }

        for cand in candidates {
            if let data = Data(base64Encoded: cand, options: [.ignoreUnknownCharacters]),
               let decoded = String(data: data, encoding: .utf8) {
                let lines = decoded
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .map(String.init)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("vless://") }
                if !lines.isEmpty { return lines }
            }
        }
        return []
    }

    private func parseVless(_ uri: String, sourceURL: String) -> VlessNode? {
        // Manual parsing is more tolerant than URLComponents for exotic fragments.
        guard uri.lowercased().hasPrefix("vless://") else { return nil }
        let body = String(uri.dropFirst("vless://".count))
        guard let at = body.firstIndex(of: "@") else { return nil }

        let user = String(body[..<at])
        let hostAndRest = String(body[body.index(after: at)...])

        let fragmentSplit = hostAndRest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let noFragment = String(fragmentSplit[0])
        let name: String
        if fragmentSplit.count > 1 {
            name = String(fragmentSplit[1]).removingPercentEncoding ?? String(fragmentSplit[1])
        } else {
            name = ""
        }

        let querySplit = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPort = String(querySplit[0])
        let query = querySplit.count > 1 ? String(querySplit[1]) : ""

        guard let colon = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colon])
        guard let port = Int(String(hostPort[hostPort.index(after: colon)...])) else { return nil }

        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            params[k] = v
        }

        let nodeName = name.isEmpty ? "\(host):\(port)" : name
        return VlessNode(
            name: nodeName,
            raw: uri,
            uuid: user,
            server: host,
            port: port,
            sni: params["sni"] ?? "",
            pbk: params["pbk"] ?? "",
            sid: params["sid"] ?? "",
            fp: params["fp"] ?? "chrome",
            flow: params["flow"] ?? "",
            sourceURL: sourceURL
        )
    }

    private func autoConnect(reason: String) {
        guard !state.nodes.isEmpty else { return }
        isBusy = true
        setStatus("Auto dialing (\(reason))...")

        DispatchQueue.global().async {
            var order: [Int] = []
            if let selected = self.state.selectedIndex, selected < self.state.nodes.count {
                order.append(selected)
            }
            if let last = self.state.lastSuccessIndex, last < self.state.nodes.count, !order.contains(last) {
                order.append(last)
            }
            for i in self.state.nodes.indices where !order.contains(i) { order.append(i) }

            for idx in order {
                let node = self.state.nodes[idx]
                DispatchQueue.main.async { self.setStatus("Trying \(node.name)") }

                let flowModes: [Bool] = node.flow.isEmpty ? [false] : [true, false]
                for useFlow in flowModes {
                    do {
                        try self.startSingBox(node: node, useFlow: useFlow)
                        let ip = try self.testIP(timeout: 10)

                        DispatchQueue.main.async {
                            self.state.lastSuccessIndex = idx
                            self.state.selectedIndex = idx
                            self.saveState()
                            self.updateServersMenu()

                            _ = self.runAdminProxy(enable: true)
                            self.playAnthemIfExists()

                            self.setStatus("Connected: \(node.name)")
                            self.setIP(ip)
                            self.isBusy = false
                        }
                        return
                    } catch {
                        self.stopSingBox()
                    }
                }
            }

            DispatchQueue.main.async {
                self.setStatus("All servers failed")
                self.setIP("-")
                self.showInfo("Connection failed", "No working server reached")
                self.isBusy = false
            }
        }
    }

    private func startSingBox(node: VlessNode, useFlow: Bool) throws {
        guard let bin = singBoxPath else {
            throw NSError(domain: "bin", code: 1, userInfo: [NSLocalizedDescriptionKey: "sing-box not found in app bundle"])
        }

        stopSingBox()

        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": node.server,
            "server_port": node.port,
            "uuid": node.uuid,
            "tls": [
                "enabled": true,
                "server_name": node.sni.isEmpty ? node.server : node.sni,
                "utls": ["enabled": true, "fingerprint": node.fp.isEmpty ? "chrome" : node.fp],
                "reality": ["enabled": true, "public_key": node.pbk, "short_id": node.sid]
            ]
        ]
        if useFlow && !node.flow.isEmpty {
            outbound["flow"] = node.flow
        }

        let cfg: [String: Any] = [
            "log": ["level": "error"],
            "dns": [
                "strategy": "prefer_ipv4",
                "servers": [
                    ["address": "https://1.1.1.1/dns-query", "detour": "proxy"],
                    ["address": "local"]
                ]
            ],
            "inbounds": [["type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": socksPort]],
            "outbounds": [outbound, ["type": "direct", "tag": "direct"], ["type": "dns", "tag": "dns-out"]],
            "route": ["auto_detect_interface": true, "final": "proxy", "rules": [["protocol": "dns", "outbound": "dns-out"]]]
        ]

        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted])
        try data.write(to: runtimeConfigFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["run", "-c", runtimeConfigFile.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        process = p

        Thread.sleep(forTimeInterval: 1.5)
    }

    private func stopSingBox() {
        if let p = process, p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.3)
        }
        process = nil
    }

    private func testIP(timeout: Int) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["--socks5-hostname", "127.0.0.1:\(socksPort)", "https://api.ipify.org", "--max-time", "\(timeout)"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()

        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus == 0 && !text.isEmpty {
            return text
        }
        throw NSError(domain: "curl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "SOCKS test failed"])
    }

    private func runAdminProxy(enable: Bool) -> Bool {
        let stateArg = enable ? "on" : "off"
        let shell = "/usr/sbin/networksetup -setsocksfirewallproxy \"Wi-Fi\" 127.0.0.1 \(socksPort) ; /usr/sbin/networksetup -setsocksfirewallproxystate \"Wi-Fi\" \(stateArg)"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]

        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func playAnthemIfExists() {
        if state.anthemMuted {
            return
        }

        let now = Date().timeIntervalSince1970
        if now - state.anthemLastPlayedAt < anthemCooldownSeconds {
            return
        }

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: Bundle.main.resourceURL ?? URL(fileURLWithPath: "/"),
            includingPropertiesForKeys: nil
        ))?
        .filter { $0.pathExtension.lowercased() == "mp3" } ?? []

        guard !candidates.isEmpty else {
            return
        }
        let pool: [URL]
        if candidates.count > 1 && !state.anthemLastTrack.isEmpty {
            let filtered = candidates.filter { $0.lastPathComponent != state.anthemLastTrack }
            pool = filtered.isEmpty ? candidates : filtered
        } else {
            pool = candidates
        }
        guard let selected = pool.randomElement() else { return }

        stopAnthemPlayback()
        guard let sound = NSSound(contentsOf: selected, byReference: true) else {
            return
        }

        anthemSound = sound
        state.anthemLastPlayedAt = now
        state.anthemLastTrack = selected.lastPathComponent
        saveState()
        sound.play()
    }

    private func stopAnthemPlayback() {
        anthemSound?.stop()
        anthemSound = nil
    }

    private func startMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.monitorTick()
        }
    }

    private func monitorTick() {
        guard state.autoReconnect else { return }
        guard !isBusy else { return }
        guard process != nil else { return }

        DispatchQueue.global().async {
            do {
                let ip = try self.testIP(timeout: 6)
                DispatchQueue.main.async { self.setIP(ip) }
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Connection lost -> reconnecting")
                }
                self.stopSingBox()
                self.autoConnect(reason: "monitor")
            }
        }
    }

    private func showInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let icon = appStarIcon(size: 72) {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func appStarIcon(size: CGFloat) -> NSImage? {
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            let img = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "BACK_TO_USSR")
            return img?.withSymbolConfiguration(cfg)
        }
        return nil
    }

    private func resizedImage(_ image: NSImage, to size: NSSize) -> NSImage? {
        let dst = NSImage(size: size)
        dst.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        dst.unlockFocus()
        return dst
    }
}

let app = NSApplication.shared
let delegate = VPNApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
