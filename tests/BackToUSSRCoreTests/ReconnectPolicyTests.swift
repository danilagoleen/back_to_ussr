import Foundation
import Testing
@testable import BackToUSSRCore

actor RecordingSleeper: SleepControlling {
    private(set) var values: [TimeInterval] = []

    func sleep(seconds: TimeInterval) async {
        values.append(seconds)
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    func recordedValues() -> [TimeInterval] {
        values
    }
}

struct ReconnectPolicyTests {
    @Test
    func delayScheduleMatchesPrompt() {
        let policy = ReconnectPolicy(maxAttempts: 20)
        #expect(policy.delay(afterFailureAttempt: 1) == 2)
        #expect(policy.delay(afterFailureAttempt: 3) == 2)
        #expect(policy.delay(afterFailureAttempt: 4) == 10)
        #expect(policy.delay(afterFailureAttempt: 6) == 10)
        #expect(policy.delay(afterFailureAttempt: 7) == 30)
        #expect(policy.delay(afterFailureAttempt: 20) == 30)
    }

    @Test
    func firstThreeFailuresConsumeAboutSixSecondsThenSlowDown() async {
        let sleeper = RecordingSleeper()
        let coordinator = ReconnectCoordinator(
            policy: ReconnectPolicy(maxAttempts: 4),
            sleeper: sleeper
        )

        let started = Date()
        let succeeded = await coordinator.run { _ in
            false
        }
        let elapsed = Date().timeIntervalSince(started)
        let sleeps = await sleeper.recordedValues()

        #expect(succeeded == false)
        #expect(sleeps == [2, 2, 2])
        #expect(elapsed >= 6.0)
        #expect(elapsed < 8.5)
    }
}
