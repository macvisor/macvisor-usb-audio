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

    @Test func refusesURBsPastItsQueueBound() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, maxQueuedURBs: 4, clock: clock)
        for id in UInt32(1) ... 4 { #expect(pacer.enqueue(id: id, frameCount: 480) {}) }
        #expect(!pacer.enqueue(id: 5, frameCount: 480) {})
        #expect(pacer.statistics.refusedURBs == 1)
        clock.advance(milliseconds: 10) // one completes: there's room again
        #expect(pacer.enqueue(id: 6, frameCount: 480) {})
    }

    @Test func refusesAudioReachingTooFarAhead() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, maxQueuedURBs: 1000, maxAhead: 0.5, clock: clock)
        for id in UInt32(1) ... 50 { #expect(pacer.enqueue(id: id, frameCount: 480) {}) } // up to 500 ms
        #expect(!pacer.enqueue(id: 51, frameCount: 480) {})
        // Any frame count, however large, is refused, not trapped on.
        #expect(!pacer.enqueue(id: 52, frameCount: Int.max) {})
        #expect(!pacer.enqueue(id: 53, frameCount: -1) {})
        #expect(pacer.statistics.refusedURBs == 3)
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
        // A second of audio queued at once: past the default bounds, which aren't what this tests.
        let pacer = EndpointPacer(lead: 0, maxQueuedURBs: 200, maxAhead: 5, clock: clock)
        pacer.setRateAdjustment(ppm: 10_000) // 1% fast
        let last = Locked<UInt64>(0)
        for id in UInt32(1) ... 100 { pacer.enqueue(id: id, frameCount: 480) { last.mutate { $0 = clock.now() } } }
        let start = clock.now()
        clock.advance(milliseconds: 1000)
        let elapsed = Double(last.value - start) / 1e6
        #expect(abs(elapsed - 1000 / 1.01) < 0.5)
    }

    /// What `AdaptiveLead` goes by: how late the late URBs came, and how much queued audio was left
    /// at the worst arrival once the stream had run a second. Asking starts the count over.
    @Test func saysHowItsURBsArrived() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0.04, clock: clock)
        var id: UInt32 = 0
        func submit() { id += 1; pacer.enqueue(id: id, frameCount: 480) {} }
        // The first second: 100 URBs, each as the one before it is due. No slack is said yet.
        for _ in 1 ... 100 { submit(); clock.advance(milliseconds: 10) }
        #expect(pacer.takeArrivals() == EndpointPacer.Arrivals())
        // On time from there: each arrives as the audio queued so far ends, so nothing is left ahead.
        submit()
        #expect(pacer.takeArrivals() == EndpointPacer.Arrivals(late: 0, worstLateness: 0, leastSlack: 0))
        // Two at once: the second finds the first's 10 ms ahead of it.
        submit()
        #expect(pacer.takeArrivals().leastSlack.map { abs($0 - 0.01) < 0.0001 } == true)
        // 70 ms with nothing sent: the audio queued ran out 50 ms ago.
        clock.advance(milliseconds: 70)
        submit()
        let arrivals = pacer.takeArrivals()
        #expect(arrivals.late == 1 && abs(arrivals.worstLateness - 0.05) < 0.0001 && arrivals.leastSlack == nil)
        #expect(pacer.takeArrivals() == EndpointPacer.Arrivals())
        #expect(pacer.statistics.lateURBs == 1 && abs(pacer.statistics.worstLateness - 0.05) < 0.0001)
    }

    /// A stream that starts within the idle gap of the last one's audio isn't late by the pause
    /// between them (it grew the lead to its most); a gap that long in the middle of a stream is the
    /// latest a URB can be, and one of seconds is a guest that was paused.
    @Test func aNewStreamIsNotLateAndAStallPastTheIdleGapIs() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0.04, clock: clock)
        var id: UInt32 = 0
        func submit() { id += 1; pacer.enqueue(id: id, frameCount: 480) {} }
        submit(); submit()
        _ = pacer.takeArrivals()
        // The stream stops, and another starts 150 ms after the queued audio's end.
        clock.advance(milliseconds: 170)
        pacer.newStream()
        submit(); submit()
        #expect(pacer.takeArrivals().late == 0)
        #expect(pacer.statistics.lateURBs == 0 && pacer.statistics.timelineRestarts == 0)
        // 0.5 s with nothing sent in the middle of it: a new timeline, and said as late.
        clock.advance(milliseconds: 520)
        submit()
        let stalled = pacer.takeArrivals()
        #expect(stalled.late == 1 && abs(stalled.worstLateness - 0.5) < 0.001)
        #expect(pacer.statistics.timelineRestarts == 1)
        // Ten seconds: the guest was paused.
        clock.advance(milliseconds: 10_010)
        submit()
        #expect(pacer.takeArrivals().late == 0)
        #expect(pacer.statistics.timelineRestarts == 2 && pacer.statistics.lateURBs == 1)
    }

    /// A lead that changes applies from the next URB queued; the ones waiting keep their times, and
    /// all still complete in order.
    @Test func aChangedLeadAppliesFromTheNextURB() {
        let clock = ManualClock()
        let pacer = EndpointPacer(lead: 0, clock: clock)
        let start = clock.now()
        let completions = Locked<[(UInt32, UInt64)]>([])
        func submit(_ id: UInt32) { pacer.enqueue(id: id, frameCount: 480) { completions.mutate { $0.append((id, clock.now() - start)) } } }
        submit(1) // due at 10 ms
        submit(2) // due at 20 ms
        pacer.setLead(0.015)
        submit(3) // its audio ends at 30 ms: due at 15 ms, but after 2
        submit(4) // due at 25 ms
        clock.advance(milliseconds: 40)
        #expect(completions.value.map(\.0) == [1, 2, 3, 4])
        #expect(completions.value.map { $0.1 / 1_000_000 } == [10, 20, 20, 25])
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
