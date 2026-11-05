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
        #expect(backoff.succeeded() == 22)
        #expect(backoff.mayTry(at: t0))
    }
}
