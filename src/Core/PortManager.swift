import Darwin
import Foundation

protocol PortInspecting: Sendable {
    func listeningProcess(on port: Int) -> ListeningProcessInfo?
}

protocol ProcessTerminating: Sendable {
    func terminate(pid: Int32) -> Bool
}

struct LsofPortInspector: PortInspecting {
    func listeningProcess(on port: Int) -> ListeningProcessInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var pid: Int32?
        var command: String?
        for line in output.split(separator: "\n") {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                pid = Int32(value)
            case "c":
                command = value
            default:
                continue
            }
        }

        if let pid, let command {
            return ListeningProcessInfo(pid: pid, command: command)
        }
        return nil
    }
}

struct SignalProcessTerminator: ProcessTerminating {
    func terminate(pid: Int32) -> Bool {
        kill(pid, SIGTERM) == 0
    }
}

struct PortManager {
    var inspector: any PortInspecting
    var terminator: any ProcessTerminating
    var protectedPorts: Set<Int>
    var appPreferredRange: ClosedRange<Int>
    var fallbackRange: ClosedRange<Int>

    init(
        inspector: any PortInspecting = LsofPortInspector(),
        terminator: any ProcessTerminating = SignalProcessTerminator(),
        protectedPorts: Set<Int> = [
            1080, 1087,
            3000, 4000, 5000, 5001, 5003,
            5173, 5174,
            8000, 8080, 8081, 8082, 8787,
        ],
        appPreferredRange: ClosedRange<Int> = 56000...56999,
        fallbackRange: ClosedRange<Int> = 49152...65535
    ) {
        self.inspector = inspector
        self.terminator = terminator
        self.protectedPorts = protectedPorts
        self.appPreferredRange = appPreferredRange
        self.fallbackRange = fallbackRange
    }

    func resolvePorts(
        preferred: SingBoxPorts? = nil,
        ownedProcessIDs: Set<Int32>
    ) throws -> PortResolution {
        var warnings: [String] = []
        var excluded = protectedPorts
        let socks = try resolvePort(
            preferredPort: preferred?.socks,
            label: "SOCKS",
            ownedProcessIDs: ownedProcessIDs,
            excluded: &excluded,
            warnings: &warnings
        )
        excluded.insert(socks)
        let http = try resolvePort(
            preferredPort: preferred?.http,
            label: "HTTP",
            ownedProcessIDs: ownedProcessIDs,
            excluded: &excluded,
            warnings: &warnings
        )

        return PortResolution(
            ports: SingBoxPorts(socks: socks, http: http),
            warnings: warnings
        )
    }

    private func resolvePort(
        preferredPort: Int?,
        label: String,
        ownedProcessIDs: Set<Int32>,
        excluded: inout Set<Int>,
        warnings: inout [String]
    ) throws -> Int {
        if let preferredPort, !protectedPorts.contains(preferredPort) {
            if let occupant = inspector.listeningProcess(on: preferredPort) {
                if ownedProcessIDs.contains(occupant.pid) {
                    _ = terminator.terminate(pid: occupant.pid)
                    waitForPortRelease(preferredPort)
                }
            }

            if let occupant = inspector.listeningProcess(on: preferredPort) {
                let fallback = try findAvailablePort(excluding: excluded)
                warnings.append(
                    "Warning: \(label) port \(preferredPort) is occupied by \(occupant.command) (pid \(occupant.pid)); using \(fallback)"
                )
                return fallback
            }

            if !excluded.contains(preferredPort), canBind(port: preferredPort) {
                return preferredPort
            }
        }

        let selected = try findAvailablePort(excluding: excluded)
        warnings.append("Info: \(label) selected dynamic port \(selected) (never_interfere strategy)")
        return selected
    }

    private func waitForPortRelease(_ port: Int) {
        for _ in 0..<10 {
            if inspector.listeningProcess(on: port) == nil {
                return
            }
            usleep(100_000)
        }
    }

    private func findAvailablePort(excluding: Set<Int>) throws -> Int {
        for port in appPreferredRange where !excluding.contains(port) {
            if canBind(port: port) {
                return port
            }
        }
        for port in fallbackRange where !excludedOrAppPreferredContains(excluding, port) {
            if canBind(port: port) {
                return port
            }
        }
        throw VPNCoreError.noAvailablePort
    }

    func snapshotProtectedPorts() -> [PortOccupancyRecord] {
        protectedPorts
            .sorted()
            .compactMap { port in
                guard let occupant = inspector.listeningProcess(on: port) else { return nil }
                return PortOccupancyRecord(port: port, pid: occupant.pid, command: occupant.command)
            }
    }

    func appRangeBounds() -> [Int] {
        [appPreferredRange.lowerBound, appPreferredRange.upperBound]
    }

    func strategyName() -> String {
        "never_interfere"
    }

    func makeDiagnosticsRecord(
        phase: String,
        selectedPorts: SingBoxPorts?,
        warnings: [String]
    ) -> PortDiagnosticsRecord {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PortDiagnosticsRecord(
            checkedAt: formatter.string(from: Date()),
            phase: phase,
            strategy: strategyName(),
            appRange: appRangeBounds(),
            protectedPorts: protectedPorts.sorted(),
            occupiedProtectedPorts: snapshotProtectedPorts(),
            selectedPorts: selectedPorts,
            warnings: warnings
        )
    }

    private func excludedOrAppPreferredContains(_ excluded: Set<Int>, _ port: Int) -> Bool {
        excluded.contains(port) || appPreferredRange.contains(port)
    }

    private func canBind(port: Int) -> Bool {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }

        var reuseAddress: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
