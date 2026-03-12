import Foundation
import Testing
@testable import BackToUSSRCore

struct PortManagerTests {
    @Test
    func occupiedHTTPPortFallsBackOutsideProtectedList() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let server = PythonHTTPServer(port: 1087, rootDirectory: temporaryDirectory)
        try server.start()
        defer { server.stop() }

        let manager = PortManager()
        let resolution = try manager.resolvePorts(
            preferred: SingBoxPorts(socks: 56080, http: 1087),
            ownedProcessIDs: []
        )

        #expect(resolution.ports.socks == 56080)
        #expect(resolution.ports.http != 1087)
        #expect(manager.protectedPorts.contains(resolution.ports.http) == false)
        #expect(resolution.warnings.isEmpty == false)
        #expect(resolution.ports.socks != resolution.ports.http)
        #expect(manager.protectedPorts.contains(resolution.ports.socks) == false)
    }
}
