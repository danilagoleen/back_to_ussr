import Foundation

final class SingBoxRuntimeManager {
    private let stateLock = NSLock()
    private let portManager: PortManager
    private let configBuilder: SingBoxConfigBuilder
    private let runtimeConfigFile: URL
    private let activePortsFile: URL
    private let diagnosticsFile: URL
    private let startupDelay: TimeInterval

    private var processStorage: Process?
    private var activePortsStorage: SingBoxPorts?
    private var launchWarningsStorage: [String] = []

    init(
        portManager: PortManager = PortManager(),
        configBuilder: SingBoxConfigBuilder = SingBoxConfigBuilder(),
        runtimeConfigFile: URL,
        activePortsFile: URL,
        diagnosticsFile: URL,
        startupDelay: TimeInterval = 1.2
    ) {
        self.portManager = portManager
        self.configBuilder = configBuilder
        self.runtimeConfigFile = runtimeConfigFile
        self.activePortsFile = activePortsFile
        self.diagnosticsFile = diagnosticsFile
        self.startupDelay = startupDelay
    }

    var process: Process? { withStateLock { processStorage } }
    var activePorts: SingBoxPorts? { withStateLock { activePortsStorage } }
    var launchWarnings: [String] { withStateLock { launchWarningsStorage } }
    var isRunning: Bool { withStateLock { processStorage?.isRunning == true } }

    func start(node: VlessNode, useFlow: Bool, binPath: String) throws -> SingBoxPorts {
        try start(
            binPath: binPath,
            preferredPorts: nil
        ) { ports in
            try configBuilder.buildRuntimeConfig(node: node, useFlow: useFlow, ports: ports)
        }
    }

    func startDirect(binPath: String, ports: SingBoxPorts) throws -> SingBoxPorts {
        try start(binPath: binPath, preferredPorts: ports) { resolvedPorts in
            try configBuilder.buildDirectConfig(ports: resolvedPorts)
        }
    }

    func start(
        binPath: String,
        preferredPorts: SingBoxPorts? = nil,
        configDataBuilder: (SingBoxPorts) throws -> Data
    ) throws -> SingBoxPorts {
        try withStateLock {
            guard FileManager.default.isExecutableFile(atPath: binPath) else {
                throw VPNCoreError.missingSingBoxBinary
            }

            let ownedProcessIDs = processStorage.map { Set([$0.processIdentifier]) } ?? []
            stopLocked()

            let resolution = try portManager.resolvePorts(
                preferred: preferredPorts,
                ownedProcessIDs: ownedProcessIDs
            )
            let configData = try configDataBuilder(resolution.ports)
            try configBuilder.writeConfig(configData, to: runtimeConfigFile)

            let launchProcess = Process()
            launchProcess.executableURL = URL(fileURLWithPath: binPath)
            launchProcess.arguments = ["run", "-c", runtimeConfigFile.path]
            launchProcess.standardOutput = Pipe()
            launchProcess.standardError = Pipe()

            do {
                try launchProcess.run()
            } catch {
                throw VPNCoreError.processLaunchFailed(error.localizedDescription)
            }

            processStorage = launchProcess
            activePortsStorage = resolution.ports
            launchWarningsStorage = resolution.warnings
            try writeActivePortsFileUnlocked(ports: resolution.ports, startedAt: Date())
            try writeDiagnosticsUnlocked(phase: "started", selectedPorts: resolution.ports, warnings: resolution.warnings)

            Thread.sleep(forTimeInterval: startupDelay)
            return resolution.ports
        }
    }

    func stop() {
        withStateLock {
            stopLocked()
        }
    }

    func writeActivePortsFile(ports: SingBoxPorts, startedAt: Date) throws {
        try withStateLock {
            try writeActivePortsFileUnlocked(ports: ports, startedAt: startedAt)
        }
    }

    func writeDiagnostics(phase: String, selectedPorts: SingBoxPorts?, warnings: [String]) throws {
        try withStateLock {
            try writeDiagnosticsUnlocked(phase: phase, selectedPorts: selectedPorts, warnings: warnings)
        }
    }

    private func stopLocked() {
        if let runningProcess = processStorage, runningProcess.isRunning {
            runningProcess.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if runningProcess.isRunning {
                runningProcess.interrupt()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        processStorage = nil
        activePortsStorage = nil
        launchWarningsStorage = []
        try? FileManager.default.removeItem(at: activePortsFile)
        try? writeDiagnosticsUnlocked(phase: "stopped", selectedPorts: nil, warnings: [])
    }

    private func writeActivePortsFileUnlocked(ports: SingBoxPorts, startedAt: Date) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = ActivePortsRecord(
            socks: ports.socks,
            http: ports.http,
            startedAt: formatter.string(from: startedAt),
            strategy: portManager.strategyName(),
            diagnosticsPath: diagnosticsFile.path,
            protectedPorts: portManager.protectedPorts.sorted(),
            pid: processStorage?.processIdentifier
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: activePortsFile, options: .atomic)
    }

    private func writeDiagnosticsUnlocked(phase: String, selectedPorts: SingBoxPorts?, warnings: [String]) throws {
        let record = portManager.makeDiagnosticsRecord(
            phase: phase,
            selectedPorts: selectedPorts,
            warnings: warnings
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: diagnosticsFile, options: .atomic)
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}
