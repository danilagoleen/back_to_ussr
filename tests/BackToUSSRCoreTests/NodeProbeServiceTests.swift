import Foundation
import Testing
@testable import BackToUSSRCore

actor MockNodeDialer: NodeDialing {
    private let delays: [String: TimeInterval]
    private let successes: Set<String>

    init(delays: [String: TimeInterval], successes: Set<String>) {
        self.delays = delays
        self.successes = successes
    }

    func dial(host: String, port: Int, timeout: TimeInterval) async -> NodeDialOutcome {
        let key = "\(host):\(port)"
        let delay = delays[key] ?? timeout
        let nanoseconds = UInt64(delay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        return successes.contains(key) ? .success(delay * 1_000) : .failure
    }
}

struct NodeProbeServiceTests {
    @Test
    func parallelProbeChoosesFastestSuccessfulNodeUnderThreeSeconds() async throws {
        let candidates = [
            NodeProbeCandidate(index: 0, node: makeNode(name: "timeout-1", host: "t1.example", port: 443)),
            NodeProbeCandidate(index: 1, node: makeNode(name: "fast", host: "fast.example", port: 443)),
            NodeProbeCandidate(index: 2, node: makeNode(name: "timeout-2", host: "t2.example", port: 443)),
            NodeProbeCandidate(index: 3, node: makeNode(name: "slow", host: "slow.example", port: 443)),
            NodeProbeCandidate(index: 4, node: makeNode(name: "timeout-3", host: "t3.example", port: 443)),
        ]
        let dialer = MockNodeDialer(
            delays: [
                "t1.example:443": 2.0,
                "fast.example:443": 0.05,
                "t2.example:443": 2.0,
                "slow.example:443": 0.2,
                "t3.example:443": 2.0,
            ],
            successes: ["fast.example:443", "slow.example:443"]
        )

        let service = NodeProbeService(dialer: dialer)
        let started = Date()
        let results = await service.probe(candidates: candidates, timeout: 2.0)
        let elapsed = Date().timeIntervalSince(started)

        #expect(results.map(\.node.name) == ["fast", "slow"])
        #expect(results[0].rttMilliseconds < results[1].rttMilliseconds)
        #expect(elapsed < 3.0)
    }
}
