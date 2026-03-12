import Foundation
import Testing
@testable import BackToUSSRCore

func makeNode(name: String, host: String, port: Int, flow: String = "") -> VlessNode {
    VlessNode(
        name: name,
        raw: "vless://\(UUID().uuidString)@\(host):\(port)#\(name)",
        uuid: UUID().uuidString,
        server: host,
        port: port,
        sni: host,
        pbk: "PUBLIC_KEY",
        sid: "SHORTID",
        fp: "chrome",
        flow: flow,
        sourceURL: "https://example.com/subscription"
    )
}

final class PythonHTTPServer {
    private let port: Int
    private let rootDirectory: URL
    private var process: Process?

    init(port: Int, rootDirectory: URL) {
        self.port = port
        self.rootDirectory = rootDirectory
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.currentDirectoryURL = rootDirectory
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
        try waitUntilListening()
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
        }
        self.process = nil
    }

    private func waitUntilListening(timeout: TimeInterval = 5.0) throws {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["-sS", "http://127.0.0.1:\(port)"]
            curl.standardOutput = Pipe()
            curl.standardError = Pipe()
            do {
                try curl.run()
                curl.waitUntilExit()
                if curl.terminationStatus == 0 {
                    return
                }
            } catch {}
            usleep(100_000)
        }
        throw NSError(
            domain: "PythonHTTPServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Python HTTP server on \(port) did not start"]
        )
    }
}
