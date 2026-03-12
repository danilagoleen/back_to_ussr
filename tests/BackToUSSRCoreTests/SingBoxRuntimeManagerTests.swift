import Foundation
import Testing
@testable import BackToUSSRCore

struct SingBoxRuntimeManagerTests {
    @Test
    func runtimeConfigContainsSeparateSocksAndHTTPInbounds() throws {
        let builder = SingBoxConfigBuilder()
        let data = try builder.buildRuntimeConfig(
            node: makeNode(name: "demo", host: "demo.example", port: 443, flow: "xtls-rprx-vision"),
            useFlow: true,
            ports: SingBoxPorts(socks: 1080, http: 1087)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbounds = try #require(json["inbounds"] as? [[String: Any]])
        #expect(inbounds.count == 2)

        let inboundTypes = Set(inbounds.compactMap { $0["type"] as? String })
        #expect(inboundTypes == ["socks", "http"])

        let ports = Set(inbounds.compactMap { $0["listen_port"] as? Int })
        #expect(ports == [1080, 1087])
    }

    @Test
    func runtimeConfigBypassesLoopbackAndPrivateNetworks() throws {
        let builder = SingBoxConfigBuilder()
        let data = try builder.buildRuntimeConfig(
            node: makeNode(name: "demo", host: "demo.example", port: 443, flow: ""),
            useFlow: false,
            ports: SingBoxPorts(socks: 56001, http: 56002)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try #require(json["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])

        let ipRule = try #require(rules.first { $0["ip_cidr"] != nil })
        let cidrs = try #require(ipRule["ip_cidr"] as? [String])
        #expect(cidrs.contains("127.0.0.0/8"))
        #expect(cidrs.contains("192.168.0.0/16"))
        #expect(cidrs.contains("::1/128"))

        let domainRule = try #require(rules.first { $0["domain_suffix"] != nil })
        let suffixes = try #require(domainRule["domain_suffix"] as? [String])
        #expect(suffixes.contains("localhost"))
        #expect(suffixes.contains("local"))
    }

    @Test
    func httpProxyForwardsLocalRequestViaSingBox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payloadFile = root.appendingPathComponent("index.html")
        try "proxy-ok".write(to: payloadFile, atomically: true, encoding: .utf8)

        let originPort = 18080
        let httpProxyPort = 19087
        let socksProxyPort = 19080

        let server = PythonHTTPServer(port: originPort, rootDirectory: root)
        try server.start()
        defer { server.stop() }

        let singBoxBinary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/BACK_TO_USSR.app/Contents/Resources/sing-box")
            .path
        guard FileManager.default.isExecutableFile(atPath: singBoxBinary) else {
            throw NSError(
                domain: "SingBoxRuntimeManagerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled sing-box binary is missing at \(singBoxBinary)"]
            )
        }

        let runtimeConfigFile = root.appendingPathComponent("runtime-sing-box.json")
        let activePortsFile = root.appendingPathComponent("active-ports.json")
        let diagnosticsFile = root.appendingPathComponent("port-diagnostics.json")
        let manager = SingBoxRuntimeManager(
            runtimeConfigFile: runtimeConfigFile,
            activePortsFile: activePortsFile,
            diagnosticsFile: diagnosticsFile,
            startupDelay: 0.8
        )

        let ports = try manager.startDirect(
            binPath: singBoxBinary,
            ports: SingBoxPorts(socks: socksProxyPort, http: httpProxyPort)
        )
        defer { manager.stop() }

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "-sS",
            "-x", "http://127.0.0.1:\(ports.http)",
            "http://127.0.0.1:\(originPort)/index.html",
            "--max-time", "8",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        curl.standardOutput = stdout
        curl.standardError = stderr
        try curl.run()
        curl.waitUntilExit()

        let body = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(curl.terminationStatus == 0, Comment(rawValue: err))
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "proxy-ok")

        let activePortsData = try Data(contentsOf: activePortsFile)
        let record = try JSONDecoder().decode(ActivePortsRecord.self, from: activePortsData)
        #expect(record.socks == socksProxyPort)
        #expect(record.http == httpProxyPort)
        #expect(record.startedAt.isEmpty == false)
        #expect(record.strategy == "never_interfere")
        #expect(record.diagnosticsPath == diagnosticsFile.path)
        #expect(record.protectedPorts?.contains(5001) == true)
        #expect(record.pid != nil)

        let diagnosticsData = try Data(contentsOf: diagnosticsFile)
        let diagnostics = try JSONDecoder().decode(PortDiagnosticsRecord.self, from: diagnosticsData)
        #expect(diagnostics.phase == "started")
        #expect(diagnostics.strategy == "never_interfere")
        #expect(diagnostics.selectedPorts == SingBoxPorts(socks: socksProxyPort, http: httpProxyPort))
    }
}
