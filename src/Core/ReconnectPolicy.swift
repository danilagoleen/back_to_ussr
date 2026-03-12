import Foundation

struct ReconnectPolicy: Sendable {
    var maxAttempts: Int = 20

    func delay(afterFailureAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case 1...3:
            return 2
        case 4...6:
            return 10
        default:
            return 30
        }
    }
}

protocol SleepControlling: Sendable {
    func sleep(seconds: TimeInterval) async
}

struct SystemSleeper: SleepControlling {
    func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct ReconnectCoordinator {
    var policy: ReconnectPolicy
    var sleeper: any SleepControlling

    init(policy: ReconnectPolicy = ReconnectPolicy(), sleeper: any SleepControlling = SystemSleeper()) {
        self.policy = policy
        self.sleeper = sleeper
    }

    func run(operation: @escaping @Sendable (Int) async -> Bool) async -> Bool {
        guard policy.maxAttempts > 0 else { return false }
        for attempt in 1...policy.maxAttempts {
            if await operation(attempt) {
                return true
            }
            guard attempt < policy.maxAttempts else { break }
            await sleeper.sleep(seconds: policy.delay(afterFailureAttempt: attempt))
        }
        return false
    }
}
