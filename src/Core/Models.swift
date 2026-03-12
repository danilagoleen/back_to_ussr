import Foundation

struct VlessNode: Codable, Hashable, Sendable {
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

struct SingBoxPorts: Codable, Equatable, Sendable {
    var socks: Int
    var http: Int
}

struct ActivePortsRecord: Codable, Equatable, Sendable {
    var socks: Int
    var http: Int
    var startedAt: String
    var strategy: String?
    var diagnosticsPath: String?
    var protectedPorts: [Int]?
    var pid: Int32?

    enum CodingKeys: String, CodingKey {
        case socks
        case http
        case startedAt = "started_at"
        case strategy
        case diagnosticsPath = "diagnostics_path"
        case protectedPorts = "protected_ports"
        case pid
    }
}

struct PortOccupancyRecord: Codable, Equatable, Sendable {
    var port: Int
    var pid: Int32?
    var command: String?
}

struct PortDiagnosticsRecord: Codable, Equatable, Sendable {
    var checkedAt: String
    var phase: String
    var strategy: String
    var appRange: [Int]
    var protectedPorts: [Int]
    var occupiedProtectedPorts: [PortOccupancyRecord]
    var selectedPorts: SingBoxPorts?
    var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case phase
        case strategy
        case appRange = "app_range"
        case protectedPorts = "protected_ports"
        case occupiedProtectedPorts = "occupied_protected_ports"
        case selectedPorts = "selected_ports"
        case warnings
    }
}

struct ListeningProcessInfo: Equatable, Sendable {
    var pid: Int32
    var command: String
}

struct PortResolution: Equatable, Sendable {
    var ports: SingBoxPorts
    var warnings: [String]
}

struct NodeProbeCandidate: Sendable {
    var index: Int
    var node: VlessNode
}

struct NodeProbeResult: Equatable, Sendable {
    var index: Int
    var node: VlessNode
    var rttMilliseconds: Double
}

enum VPNCoreError: LocalizedError {
    case invalidURL(String)
    case invalidVlessURI
    case noAvailablePort
    case missingSingBoxBinary
    case processLaunchFailed(String)
    case proxyCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidVlessURI:
            return "Invalid VLESS URI"
        case .noAvailablePort:
            return "No available port outside protected list"
        case .missingSingBoxBinary:
            return "sing-box not found in app bundle"
        case .processLaunchFailed(let message):
            return "Failed to launch sing-box: \(message)"
        case .proxyCheckFailed(let message):
            return message
        }
    }
}
