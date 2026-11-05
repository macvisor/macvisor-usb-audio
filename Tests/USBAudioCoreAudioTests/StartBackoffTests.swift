import Foundation
import Testing
@testable import USBAudioCoreAudio

@Suite struct StartBackoffTests {
    @Test func aFailedStartWaitsLongerEachTimeAndASuccessResetsIt() {
        var backoff = StartBackoff()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(backoff.mayTry(at: t0))
        #expect(backoff.failed(at: t0) == 1)
        #expect(!backoff.mayTry(at: t0.addingTimeInterval(0.4)))
        #expect(backoff.mayTry(at: t0.addingTimeInterval(0.5)))
        #expect(backoff.failed(at: t0.addingTimeInterval(0.5)) == 2)
        #expect(!backoff.mayTry(at: t0.addingTimeInterval(1.4)))
        #expect(backoff.mayTry(at: t0.addingTimeInterval(1.5)))
        for _ in 0 ..< 20 { _ = backoff.failed(at: t0) }
        #expect(!backoff.mayTry(at: t0.addingTimeInterval(29.9))) // capped at 30 s
        #expect(backoff.mayTry(at: t0.addingTimeInterval(30)))
        #expect(backoff.succeeded(at: t0) == 22)
        #expect(backoff.mayTry(at: t0))
    }

    @Test func aDeviceChangeWaitsASecondAfterTheLastStartAndKeepsAFailuresPause() {
        var backoff = StartBackoff()
        let t0 = Date(timeIntervalSinceReferenceDate: 2000)
        _ = backoff.succeeded(at: t0)
        // A headset flipping profiles: changes right after a start wait out the second.
        let at = backoff.holdOffAfterStart(seconds: 1)
        #expect(at == t0.addingTimeInterval(1))
        #expect(!backoff.mayTry(at: t0.addingTimeInterval(0.5)))
        #expect(backoff.mayTry(at: t0.addingTimeInterval(1)))
        // A failure's longer pause isn't cut short by a device change.
        _ = backoff.failed(at: t0.addingTimeInterval(1))
        for _ in 0 ..< 5 { _ = backoff.failed(at: t0.addingTimeInterval(1)) } // 16 s pause
        _ = backoff.holdOffAfterStart(seconds: 1)
        #expect(!backoff.mayTry(at: t0.addingTimeInterval(10)))
    }
}
