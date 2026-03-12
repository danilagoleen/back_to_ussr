import Foundation
import Network

enum NodeDialOutcome: Sendable {
    case success(Double)
    case failure
}

protocol NodeDialing: Sendable {
    func dial(host: String, port: Int, timeout: TimeInterval) async -> NodeDialOutcome
}

private final class ProbeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func resume(
        _ continuation: CheckedContinuation<NodeDialOutcome, Never>,
        with outcome: NodeDialOutcome
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: outcome)
    }
}

private final class ProbeTimeoutBox: @unchecked Sendable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }

    func schedule(on queue: DispatchQueue, after timeout: TimeInterval) {
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }
}

struct TCPNodeDialer: NodeDialing {
    func dial(host: String, port: Int, timeout: TimeInterval) async -> NodeDialOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failure
        }

        return await withCheckedContinuation { continuation in
            let box = ProbeContinuationBox()
            let queue = DispatchQueue(label: "back_to_ussr.node_probe.\(host).\(port)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let startedAt = DispatchTime.now().uptimeNanoseconds

            let timeoutBox = ProbeTimeoutBox(item: DispatchWorkItem {
                connection.cancel()
                box.resume(continuation, with: .failure)
            })

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutBox.cancel()
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000.0
                    connection.cancel()
                    box.resume(continuation, with: .success(elapsed))
                case .failed, .cancelled:
                    timeoutBox.cancel()
                    box.resume(continuation, with: .failure)
                default:
                    break
                }
            }

            timeoutBox.schedule(on: queue, after: timeout)
            connection.start(queue: queue)
        }
    }
}

struct NodeProbeService {
    var dialer: any NodeDialing

    init(dialer: any NodeDialing = TCPNodeDialer()) {
        self.dialer = dialer
    }

    func probe(candidates: [NodeProbeCandidate], timeout: TimeInterval = 2.0) async -> [NodeProbeResult] {
        await withTaskGroup(of: NodeProbeResult?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let outcome = await dialer.dial(
                        host: candidate.node.server,
                        port: candidate.node.port,
                        timeout: timeout
                    )
                    switch outcome {
                    case .success(let rttMilliseconds):
                        return NodeProbeResult(
                            index: candidate.index,
                            node: candidate.node,
                            rttMilliseconds: rttMilliseconds
                        )
                    case .failure:
                        return nil
                    }
                }
            }

            var results: [NodeProbeResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results.sorted {
                if abs($0.rttMilliseconds - $1.rttMilliseconds) < 0.001 {
                    return $0.index < $1.index
                }
                return $0.rttMilliseconds < $1.rttMilliseconds
            }
        }
    }
}
