import Dispatch
import Foundation
import Testing
@testable import USBAudioDevice

@Suite struct PacerTests {
    @Test func completesInSubmissionOrderWhenDueTimesCoincide() {
        let clock = ManualClock()
        // A lead longer than the queued audio makes every URB due at once: order must still hold.
        let pacer = EndpointPacer(lead: 1, clock: clock)
        let order = Locked<[UInt32]>([])
        for id in UInt32(1) ... 20 { pacer.enqueue(id: id, frameCount: 480) { order.mutate { $0.append(id) } } }
        clock.advance(milliseconds: 0)
        #expect(order.value == Array(1 ... 20))
    }

    @Test func runsEachURBWhenItsAudioIsDue() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, clock: clock)
        let done = Locked<[UInt32]>([])
        for id in UInt32(1) ... 3 { pacer.enqueue(id: id, frameCount: 480) { done.mutate { $0.append(id) } } }
        clock.advance(milliseconds: 9.9)
        #expect(done.value.isEmpty)
        clock.advance(milliseconds: 0.1)
        #expect(done.value == [1])
        clock.advance(milliseconds: 20)
        #expect(done.value == [1, 2, 3])
    }

    @Test func playbackLeadCompletesEarly() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0.04, clock: clock)
        let done = Locked<[UInt32]>([])
        for id in UInt32(1) ... 6 { pacer.enqueue(id: id, frameCount: 480) { done.mutate { $0.append(id) } } }
        clock.advance(milliseconds: 0)
        #expect(done.value == [1, 2, 3, 4]) // due at 10, 20, 30, 40 ms minus 40 ms
        clock.advance(milliseconds: 10)
        #expect(done.value == [1, 2, 3, 4, 5])
    }

    @Test func aLateURBCompletesAtOnceAndKeepsTheTimeline() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, clock: clock)
        let done = Locked<Int>(0)
        pacer.enqueue(id: 1, frameCount: 480) { done.mutate { $0 += 1 } }
        clock.advance(milliseconds: 40) // URB 2 should have arrived 30 ms ago
        pacer.enqueue(id: 2, frameCount: 480) { done.mutate { $0 += 1 } }
        pacer.enqueue(id: 3, frameCount: 480) { done.mutate { $0 += 1 } }
        clock.advance(milliseconds: 0)
        #expect(done.value == 3) // both were due on the original timeline: 20 and 30 ms
        #expect(pacer.statistics.lateURBs == 2) // URBs 2 and 3 both arrived after their audio's start
        #expect(pacer.statistics.timelineRestarts == 0)
    }

    @Test func anIdleGapStartsANewTimeline() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, idleReset: 0.2, clock: clock)
        let done = Locked<Int>(0)
        pacer.enqueue(id: 1, frameCount: 480) { done.mutate { $0 += 1 } }
        clock.advance(milliseconds: 500)
        pacer.enqueue(id: 2, frameCount: 480) { done.mutate { $0 += 1 } }
        clock.advance(milliseconds: 5)
        #expect(done.value == 1) // the new timeline puts URB 2 10 ms from now
        clock.advance(milliseconds: 5)
        #expect(done.value == 2)
        #expect(pacer.statistics.timelineRestarts == 1)
    }

    @Test func cancelledURBsNeverRun() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, clock: clock)
        let done = Locked<[UInt32]>([])
        for id in UInt32(1) ... 4 { pacer.enqueue(id: id, frameCount: 480) { done.mutate { $0.append(id) } } }
        #expect(pacer.cancel(id: 1)) // the head, with its timer armed
        #expect(pacer.cancel(id: 3))
        clock.advance(milliseconds: 10)
        #expect(done.value.isEmpty) // URB 2 is still due at 20 ms
        clock.advance(milliseconds: 40)
        #expect(done.value == [2, 4])
        #expect(!pacer.cancel(id: 2)) // already completed
        pacer.enqueue(id: 5, frameCount: 480) { done.mutate { $0.append(5) } }
        pacer.cancelAll()
        clock.advance(milliseconds: 100)
        #expect(done.value == [2, 4])
    }

    @Test func rateAdjustmentSteersTheTimeline() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, clock: clock)
        pacer.setRateAdjustment(ppm: 10_000) // 1% fast
        let last = Locked<UInt64>(0)
        for id in UInt32(1) ... 100 { pacer.enqueue(id: id, frameCount: 480) { last.mutate { $0 = clock.now() } } }
        let start = clock.now()
        clock.advance(milliseconds: 1000)
        let elapsed = Double(last.value - start) / 1e6
        #expect(abs(elapsed - 1000 / 1.01) < 0.5)
    }

    /// The long-run rate holds whatever the jitter, with the guest keeping two URBs in flight and
    /// resubmitting each 0–15 ms after a completion (a re-anchoring pacer ran 20% slow here).
    @Test func longRunRateIsExactUnderJitter() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0.04, clock: clock)
        let rng = Locked(SplitMix64(seed: 7))
        let completions = Locked<[UInt64]>([])
        let resubmitAt = Locked<[UInt64]>([])
        var next: UInt32 = 1
        let total = 1000
        func submit() {
            let id = next
            next += 1
            pacer.enqueue(id: id, frameCount: 480) {
                completions.mutate { $0.append(clock.now()) }
                var jitter: UInt64 = 0
                rng.mutate { jitter = $0.next() % 15_000 }
                resubmitAt.mutate { $0.append(clock.now() + jitter * 1000) }
            }
        }
        let start = clock.now()
        submit()
        submit()
        while completions.value.count < total {
            clock.advance(milliseconds: 0.5)
            let now = clock.now()
            let due = resubmitAt.value.filter { $0 <= now }.count
            resubmitAt.mutate { $0.removeAll { $0 <= now } }
            for _ in 0 ..< due where Int(next) <= total { submit() }
        }
        let elapsed = Double(completions.value[total - 1] - start) / 1e6
        #expect(abs(elapsed - (10_000 - 40)) < 16) // the last URB is due 40 ms before its audio ends
        #expect(pacer.statistics.timelineRestarts == 0)
    }
}

/// A small deterministic random generator.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
