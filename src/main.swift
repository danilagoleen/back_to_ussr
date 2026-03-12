import AppKit
import Foundation

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
    private let appTitle = "BACK_TO_USSR"
    private let appSlogan = "Universal Secure Server Router"
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var serversMenu: NSMenu!
    private var subsMenu: NSMenu!

    private var isBusy = false
    private var monitorTimer: Timer?
    private var anthemSound: NSSound?
    private let anthemCooldownSeconds: Double = 180
    private let parser = SubscriptionParser()
    private let portManager = PortManager()
    private let probeService = NodeProbeService()
    private let reconnectPolicy = ReconnectPolicy()
    private let adminProxyQueue = DispatchQueue(label: "com.back.to.ussr.proxy-admin", qos: .userInitiated)
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var currentConnectTask: Task<Void, Never>?
    private var connectGeneration: UInt64 = 0
    private var proxyEnabledByApp = false

    private var state = AppState(
        subscriptionURLs: [],
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
    private var activePortsFile: URL { appSupportDir.appendingPathComponent("active-ports.json") }
    private var diagnosticsFile: URL { appSupportDir.appendingPathComponent("port-diagnostics.json") }
    private lazy var runtimeManager = SingBoxRuntimeManager(
        portManager: portManager,
        runtimeConfigFile: runtimeConfigFile,
        activePortsFile: activePortsFile,
        diagnosticsFile: diagnosticsFile
    )

    private var singBoxPath: String? { Bundle.main.path(forResource: "sing-box", ofType: nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareStateDir()
        loadState()

        if let icon = appStarIcon(size: 128) {
            NSApp.applicationIconImage = icon
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = ""
            if #available(macOS 11.0, *) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                let img = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "USSR")?.withSymbolConfiguration(cfg)
                img?.isTemplate = true
                btn.image = img
            } else {
                btn.title = "★"
            }
            btn.toolTip = "BACK_TO_USSR"
        }

        menu = NSMenu()
        buildMenu()
        statusItem.menu = menu

        updateServersMenu()
        updateSubscriptionsMenu()
        writeStartupDiagnostics()
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
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile)
        }
    }

    private func buildMenu() {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: appTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let sloganItem = NSMenuItem(title: appSlogan, action: nil, keyEquivalent: "")
        sloganItem.isEnabled = false
        menu.addItem(sloganItem)

        menu.addItem(NSMenuItem.separator())

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

        menu.item(withTitle: "Connect")?.tag = 1001
        menu.item(withTitle: "Disconnect")?.tag = 1002
        setConnectedCheck(false)
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

    private func setConnectedCheck(_ connected: Bool) {
        menu.item(withTag: 1001)?.state = connected ? .on : .off
        menu.item(withTag: 1002)?.state = connected ? .off : .on
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
        resetReconnectState()
        setConnectedCheck(false)
        autoConnect(reason: "manual", scheduleOnFailure: false)
    }

    @objc private func disconnectTapped() {
        resetReconnectState()
        stopSingBox()
        stopAnthemPlayback()
        requestSystemProxy(enable: false)
        setStatus("Disconnected")
        setIP("-")
        setConnectedCheck(false)
    }

    @objc private func manageSubscriptionTapped() {
        let alert = NSAlert()
        alert.messageText = appTitle
        alert.informativeText = "\(appSlogan)\n\nOne URL per line. You can add unlimited links."
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
                    // If we already have cached nodes, keep app usable and avoid a hard-stop UX.
                    if self.state.nodes.isEmpty {
                        self.showInfo("Refresh failed", error.localizedDescription)
                    } else {
                        self.setStatus("Refresh failed (using cached \(self.state.nodes.count) servers)")
                    }
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
        resetReconnectState()
        stopSingBox()
        stopAnthemPlayback()
        if proxyEnabledByApp {
            _ = runAdminProxy(enable: false)
            proxyEnabledByApp = false
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        resetReconnectState()
        stopSingBox()
        stopAnthemPlayback()
        if proxyEnabledByApp {
            _ = runAdminProxy(enable: false)
            proxyEnabledByApp = false
        }
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
            if let fallback = try? fetchURLViaCurl(urlString), !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fallback
            }
            throw err
        }
        let text = String(data: outData ?? Data(), encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let fallback = try? fetchURLViaCurl(urlString),
           !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return text
    }

    private func fetchURLViaCurl(_ urlString: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-L", "-sS", "--max-time", "25", "-A", "BACK_TO_USSR/1.0", urlString]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus == 0 && !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stdout
        }
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "curl failed"
        throw NSError(domain: "curl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
    }

    private func decodeSubscription(_ text: String) -> [String] {
        parser.decodeSubscription(text)
    }

    private func parseVless(_ uri: String, sourceURL: String) -> VlessNode? {
        parser.parseVless(uri, sourceURL: sourceURL)
    }

    private func autoConnect(reason: String, scheduleOnFailure: Bool) {
        guard !state.nodes.isEmpty else { return }
        isBusy = true
        setStatus("Auto dialing (\(reason))...")

        let candidates = prioritizedCandidates()
        let generation = beginConnectGeneration()
        currentConnectTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let probeResults = await self.probeService.probe(candidates: candidates, timeout: 2.0)
            guard !Task.isCancelled else { return }

            if probeResults.isEmpty {
                await MainActor.run {
                    guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }
                    self.finishConnectFailure(
                        title: "Connection failed",
                        message: "No reachable server responded to TCP probe",
                        scheduleRetry: scheduleOnFailure
                    )
                }
                return
            }

            for probe in probeResults {
                guard !Task.isCancelled else { return }
                let node = probe.node
                await MainActor.run {
                    guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }
                    self.setStatus("Trying \(node.name) \(Int(probe.rttMilliseconds))ms")
                }

                let flowModes: [Bool] = node.flow.isEmpty ? [false] : [true, false]
                for useFlow in flowModes {
                    guard !Task.isCancelled else { return }
                    do {
                        try self.startSingBox(node: node, useFlow: useFlow)
                        guard !Task.isCancelled else {
                            self.stopSingBox()
                            return
                        }
                        let ip = try self.testIP(timeout: 10, cancelIf: { Task.isCancelled })
                        guard !Task.isCancelled else {
                            self.stopSingBox()
                            return
                        }
                        await MainActor.run {
                            guard !Task.isCancelled, self.isCurrentGeneration(generation) else {
                                self.stopSingBox()
                                return
                            }
                            self.handleConnectSuccess(index: probe.index, node: node, ip: ip, generation: generation)
                        }
                        return
                    } catch {
                        self.stopSingBox()
                    }
                }
            }

            await MainActor.run {
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }
                self.finishConnectFailure(
                    title: "Connection failed",
                    message: "No working server reached",
                    scheduleRetry: scheduleOnFailure
                )
            }
        }
        currentConnectTask = task
    }

    private func startSingBox(node: VlessNode, useFlow: Bool) throws {
        guard let bin = singBoxPath else {
            throw NSError(domain: "bin", code: 1, userInfo: [NSLocalizedDescriptionKey: "sing-box not found in app bundle"])
        }
        let ports = try runtimeManager.start(node: node, useFlow: useFlow, binPath: bin)
        for warning in runtimeManager.launchWarnings {
            print("[BACK_TO_USSR] \(warning)")
        }
        print("[BACK_TO_USSR] sing-box listeners socks=\(ports.socks) http=\(ports.http) strategy=never_interfere")
    }

    private func stopSingBox() {
        runtimeManager.stop()
    }

    private func testIP(timeout: Int, cancelIf: @escaping @Sendable () -> Bool = { false }) throws -> String {
        guard let socksPort = runtimeManager.activePorts?.socks else {
            throw NSError(
                domain: "curl",
                code: 98,
                userInfo: [NSLocalizedDescriptionKey: "SOCKS port is not active"]
            )
        }
        let probeURLs = [
            "https://api.ipify.org",
            "https://ipv4.icanhazip.com",
            "https://ifconfig.me/ip",
        ]
        var lastError: Error?

        for url in probeURLs {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--socks5-hostname", "127.0.0.1:\(socksPort)", url, "--max-time", "\(timeout)"]
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let completed = waitForProcessExit(p, cancelIf: cancelIf)
            if !completed {
                throw NSError(domain: "curl", code: 89, userInfo: [NSLocalizedDescriptionKey: "SOCKS test cancelled"])
            }

            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if p.terminationStatus == 0 && !text.isEmpty {
                return text
            }

            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "SOCKS test failed"
            lastError = NSError(domain: "curl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }

        throw lastError ?? NSError(domain: "curl", code: 1, userInfo: [NSLocalizedDescriptionKey: "SOCKS test failed"])
    }

    private func runAdminProxy(enable: Bool) -> Bool {
        guard let service = activeNetworkServiceName() else { return false }
        let quotedService = shellQuoted(service)
        let activePorts = runtimeManager.activePorts
        let shell: String
        if enable {
            guard let activePorts else { return false }
            shell = """
            set -e;
            /usr/sbin/networksetup -setwebproxy \(quotedService) 127.0.0.1 \(activePorts.http);
            /usr/sbin/networksetup -setsecurewebproxy \(quotedService) 127.0.0.1 \(activePorts.http);
            /usr/sbin/networksetup -setsocksfirewallproxy \(quotedService) 127.0.0.1 \(activePorts.socks);
            /usr/sbin/networksetup -setproxybypassdomains \(quotedService) localhost 127.0.0.1 ::1 "*.local";
            /usr/sbin/networksetup -setwebproxystate \(quotedService) on;
            /usr/sbin/networksetup -setsecurewebproxystate \(quotedService) on;
            /usr/sbin/networksetup -setsocksfirewallproxystate \(quotedService) on
            """
        } else {
            shell = """
            set -e;
            /usr/sbin/networksetup -setwebproxystate \(quotedService) off;
            /usr/sbin/networksetup -setsecurewebproxystate \(quotedService) off;
            /usr/sbin/networksetup -setsocksfirewallproxystate \(quotedService) off
            """
        }
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

    private func activeNetworkServiceName() -> String? {
        let services = listNetworkServices()
        guard !services.isEmpty else { return nil }
        guard let iface = defaultRouteInterface() else {
            return fallbackNetworkServiceName(from: services)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listnetworkserviceorder"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            for (i, line) in lines.enumerated() where line.contains("Device: \(iface)") && i > 0 {
                let prev = lines[i - 1]
                if let close = prev.firstIndex(of: ")") {
                    let candidate = prev[prev.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if services.contains(candidate) {
                        return candidate
                    }
                }
            }
        } catch {}
        return fallbackNetworkServiceName(from: services)
    }

    private func defaultRouteInterface() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("interface:") {
                    return line.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
        } catch {}
        return nil
    }

    private func listNetworkServices() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallnetworkservices"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
        } catch {
            return []
        }
    }

    private func fallbackNetworkServiceName(from services: [String]) -> String? {
        let preferred = [
            "Wi-Fi",
            "USB 10/100/1000 LAN",
            "Thunderbolt Ethernet",
            "Ethernet",
        ]
        for candidate in preferred where services.contains(candidate) {
            return candidate
        }
        return services.first
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func beginConnectGeneration() -> UInt64 {
        connectGeneration &+= 1
        return connectGeneration
    }

    private func invalidateConnectGeneration() {
        connectGeneration &+= 1
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == connectGeneration
    }

    private func requestSystemProxy(enable: Bool, completion: ((Bool) -> Void)? = nil) {
        if !enable && !proxyEnabledByApp {
            completion?(true)
            return
        }

        adminProxyQueue.async { [weak self] in
            guard let self else { return }
            let success = self.runAdminProxy(enable: enable)
            DispatchQueue.main.async {
                if enable {
                    self.proxyEnabledByApp = success
                } else {
                    self.proxyEnabledByApp = false
                }
                completion?(success)
            }
        }
    }

    private func waitForProcessExit(_ process: Process, cancelIf: @escaping @Sendable () -> Bool) -> Bool {
        while process.isRunning {
            if cancelIf() {
                process.terminate()
                usleep(100_000)
                if process.isRunning {
                    process.interrupt()
                    usleep(100_000)
                }
                return false
            }
            usleep(50_000)
        }
        return true
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
        guard runtimeManager.isRunning else { return }

        DispatchQueue.global().async {
            do {
                let ip = try self.testIP(timeout: 6)
                DispatchQueue.main.async { self.setIP(ip) }
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Connection lost")
                    self.setConnectedCheck(false)
                }
                self.stopSingBox()
                self.requestSystemProxy(enable: false)
                DispatchQueue.main.async {
                    self.scheduleReconnect(reason: "monitor")
                }
            }
        }
    }

    private func prioritizedCandidates() -> [NodeProbeCandidate] {
        var order: [Int] = []
        if let selected = state.selectedIndex, selected < state.nodes.count {
            order.append(selected)
        }
        if let last = state.lastSuccessIndex, last < state.nodes.count, !order.contains(last) {
            order.append(last)
        }
        for index in state.nodes.indices where !order.contains(index) {
            order.append(index)
        }
        return order.map { NodeProbeCandidate(index: $0, node: state.nodes[$0]) }
    }

    private func handleConnectSuccess(index: Int, node: VlessNode, ip: String, generation: UInt64) {
        currentConnectTask = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        setIP(ip)
        setStatus("Enabling system proxy...")
        setConnectedCheck(false)

        requestSystemProxy(enable: true) { [weak self] success in
            guard let self else { return }

            guard self.isCurrentGeneration(generation) else {
                if success {
                    self.requestSystemProxy(enable: false)
                }
                self.stopSingBox()
                self.stopAnthemPlayback()
                self.isBusy = false
                self.setConnectedCheck(false)
                return
            }

            guard success else {
                self.stopSingBox()
                self.stopAnthemPlayback()
                self.setStatus("Proxy activation failed")
                self.setIP("-")
                self.isBusy = false
                self.setConnectedCheck(false)
                self.showInfo("Admin privileges required", "System proxy could not be enabled. Connection was rolled back to avoid traffic leaks.")
                return
            }

            self.state.lastSuccessIndex = index
            self.state.selectedIndex = index
            self.saveState()
            self.updateServersMenu()

            self.playAnthemIfExists()

            self.setStatus("Connected: \(node.name)")
            self.setIP(ip)
            self.isBusy = false
            self.setConnectedCheck(true)
        }
    }

    private func finishConnectFailure(title: String, message: String, scheduleRetry: Bool) {
        currentConnectTask = nil
        requestSystemProxy(enable: false)
        setStatus("All servers failed")
        setIP("-")
        isBusy = false
        setConnectedCheck(false)

        if scheduleRetry && state.autoReconnect {
            scheduleReconnect(reason: "retry")
        } else {
            showInfo(title, message)
        }
    }

    private func scheduleReconnect(reason: String) {
        guard state.autoReconnect else {
            isBusy = false
            return
        }

        reconnectWorkItem?.cancel()
        reconnectAttempt += 1

        guard reconnectAttempt <= reconnectPolicy.maxAttempts else {
            requestSystemProxy(enable: false)
            stopSingBox()
            stopAnthemPlayback()
            setStatus("No available servers")
            setIP("-")
            setConnectedCheck(false)
            showInfo("Нет доступных серверов", "Все серверы недоступны. Проверьте подписку или сеть.")
            isBusy = false
            return
        }

        let delay = reconnectPolicy.delay(afterFailureAttempt: reconnectAttempt)
        setStatus("Reconnect \(reconnectAttempt)/\(reconnectPolicy.maxAttempts) in \(Int(delay))s")
        isBusy = false

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoConnect(reason: "\(reason)-\(self.reconnectAttempt)", scheduleOnFailure: true)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resetReconnectState() {
        currentConnectTask?.cancel()
        currentConnectTask = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        invalidateConnectGeneration()
    }

    private func writeStartupDiagnostics() {
        do {
            try runtimeManager.writeDiagnostics(phase: "launch", selectedPorts: nil, warnings: [])
            for occupied in portManager.snapshotProtectedPorts() {
                let command = occupied.command ?? "unknown"
                let pid = occupied.pid.map(String.init) ?? "?"
                print("[BACK_TO_USSR] protected port \(occupied.port) occupied by \(command) pid=\(pid)")
            }
        } catch {
            print("[BACK_TO_USSR] failed to write startup diagnostics: \(error.localizedDescription)")
        }
    }

    private func showInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = "\(appTitle) — \(title)"
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
