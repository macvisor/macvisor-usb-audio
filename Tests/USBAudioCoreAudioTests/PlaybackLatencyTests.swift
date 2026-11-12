import Foundation
import Testing
@testable import USBAudioCoreAudio
@testable import USBAudioDevice

/// Drives a CoreAudioPlayback the way USBAudioServer and Windows do, on a simulated clock:
/// - the guest keeps two 10 ms URBs in flight, sending the next 0–2 ms after each completion;
/// - an `EndpointPacer` with the server's 40 ms lead completes them, and each completion plays its
///   audio;
/// - the server's steering (`PlaybackSteering`) adjusts the pacer every quarter of a second;
/// - the output's start returns `startDelay` after the stream starts; from then on it pulls 512
///   frames per render cycle (a Mac's default output, 5 Nov 2026), at its own clock.
/// Each pull's first frame says how long it waited in the ring after the server played it: the
/// latency the ring adds.
final class PlaybackSimulation {
    struct Pull {
        let time: Double // seconds since the stream started
        let frames: Int
        let latency: Double? // seconds
    }

    let clock = SimulatedClock()
    let outputs = FakeOutputs()
    let playback: CoreAudioPlayback
    let pacer: EndpointPacer
    private(set) var pulls: [Pull] = []

    private let origin: UInt64
    private let startDelay: TimeInterval
    private let pullInterval: Double // nanoseconds
    private var steering = PlaybackSteering(setPoint: 0.04)
    /// The server's fitting of the lead to the arrivals, when the simulation has it; and each change
    /// of the lead, with its time.
    private var adaptive: AdaptiveLead?
    private(set) var leads: [(time: Double, lead: Double)] = []
    private let gate = DispatchSemaphore(value: 0)
    /// When each URB's audio went into the ring, by URB.
    private let written = Box<[Int: UInt64]>([:])
    /// When the guest sends its next URBs.
    private let resubmits = Box<[UInt64]>([])
    private var random = SplitMix64(seed: 7)
    private var nextURB = 0
    private var held = 0
    private var stallEnd: UInt64 = 0
    private var started = false
    private var nextPull = 0.0
    private var nextSteer: UInt64

    /// - Parameters:
    ///   - outputDrift: the output's clock against the Mac's, in ppm (positive: faster).
    ///   - mostLead: how far the lead may grow (`AdaptiveLead`), as the server lets it; nil keeps it
    ///     at 40 ms.
    ///   - startLead: what the stream starts with, as the server's streams do (100 ms); nil: 40 ms.
    ///   - slowBuild: the output takes `startDelay` to be built, rather than to start.
    init(startDelay: TimeInterval, outputDrift: Double = 0, mostLead: TimeInterval? = nil, startLead: TimeInterval? = nil, slowBuild: Bool = false) {
        self.startDelay = startDelay
        adaptive = mostLead.map { AdaptiveLead(base: 0.04, most: $0, start: startLead) }
        pullInterval = 512 / 48000 * 1e9 / (1 + outputDrift / 1e6)
        let outputs = outputs
        let gate = gate
        if slowBuild { outputs.buildGate = gate } else { outputs.gate = gate }
        playback = CoreAudioPlayback(idleStop: 30, bounds: .playback) { try outputs.make($0, $1) }
        pacer = EndpointPacer(lead: adaptive?.lead ?? 0.04, clock: clock)
        if let lead = adaptive?.lead {
            playback.playbackLead(lead)
            steering.setPoint = lead
        }
        origin = clock.now()
        nextSteer = origin + 250_000_000
        playback.playbackStarted()
        submit()
        submit()
    }

    deinit {
        if !started { gate.signal() } // lets the playback's queue go
    }

    /// The guest sends nothing for `seconds` from `at` (seconds since the stream started).
    func stall(at: Double, for seconds: Double) {
        run(until: at)
        stallEnd = clock.now() + UInt64(seconds * 1e9)
    }

    /// Runs the stream until `seconds` after it started.
    func run(until seconds: Double) {
        let end = origin + UInt64(seconds * 1e9)
        while clock.now() < end {
            let now = clock.now() + 250_000
            clock.advance(to: now) // completions: audio into the ring, and the guest's next URBs
            let due = resubmits.mutate { times -> Int in
                let n = times.filter { $0 <= now }.count
                times.removeAll { $0 <= now }
                return n
            }
            held += due
            if now >= stallEnd {
                for _ in 0 ..< held { submit() }
                held = 0
            }
            if !started, now >= origin + UInt64(startDelay * 1e9) {
                gate.signal()
                playback.waitForQueue()
                started = true
                nextPull = Double(now)
            }
            while started, Double(now) >= nextPull {
                pull(at: now)
                nextPull += pullInterval
            }
            if now >= nextSteer {
                if let lead = adaptive?.tick(pacer.takeArrivals()) {
                    playback.playbackLead(lead)
                    pacer.setLead(lead)
                    steering.setPoint = lead
                    leads.append((Double(now - origin) / 1e9, lead))
                }
                pacer.setRateAdjustment(ppm: steering.adjustment(level: playback.bufferedSeconds, backlog: playback.startBacklog))
                nextSteer += 250_000_000
            }
        }
    }

    private func submit() {
        let urb = nextURB
        nextURB += 1
        let pcm = tagged(first: urb * 480, frames: 480)
        let jitter = random.next() % 2_000_000
        let (clock, playback, written, resubmits) = (clock, playback, written, resubmits)
        pacer.enqueue(id: UInt32(urb), frameCount: 480) {
            written.mutate { $0[urb] = clock.now() }
            playback.play(pcm)
            resubmits.mutate { $0.append(clock.now() + jitter) }
        }
    }

    private func pull(at now: UInt64) {
        guard let output = outputs.all.last else { return }
        let (frames, first) = output.pull(512)
        let latency = first.flatMap { f in written.value[f / 480].map { Double(now - $0) / 1e9 } }
        pulls.append(Pull(time: Double(now - origin) / 1e9, frames: frames, latency: latency))
    }

    // MARK: Results

    func latencies(from: Double, to: Double = .infinity) -> [Double] {
        pulls.filter { $0.time >= from && $0.time < to }.compactMap(\.latency)
    }

    /// Pulls the ring couldn't fill (silence the output played).
    func underruns(from: Double, to: Double = .infinity) -> Int {
        pulls.filter { $0.time >= from && $0.time < to && $0.frames < 512 }.count
    }

    var firstPull: Double { pulls.first?.time ?? .infinity }

    /// The lead now.
    var lead: Double { adaptive?.lead ?? 0.04 }

    static func ms(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max() else { return "none" }
        let mean = values.reduce(0, +) / Double(values.count)
        return String(format: "%.1f–%.1f ms (mean %.1f)", low * 1000, high * 1000, mean * 1000)
    }
}

@Suite struct PlaybackLatencyTests {
    /// An output that takes 0.45 s to start (the Mac's default output took 0.43 to 0.53 s). It used to
    /// start with half a second in the ring and keep it, the stream 0.5 s behind for good; then it
    /// started with the newest 40 ms, and the stream's first half second went unheard. Now it plays
    /// the stream from its beginning, half a second behind, and the steering has the guest send
    /// slower until that is played down: nothing dropped, nothing missed, and at the lead ten
    /// seconds or so on.
    @Test func aSlowEngineStartPlaysTheBeginningAndLeavesNoLatencyBehind() {
        let sim = PlaybackSimulation(startDelay: 0.45)
        sim.run(until: 25)
        let all = sim.latencies(from: 0)
        let settled = sim.latencies(from: 15)
        let at: (Double) -> String = { t in String(format: "%.0f ms", (sim.latencies(from: t, to: t + 0.5).max() ?? 0) * 1000) }
        print("slow start (0.45 s): first pull at \(String(format: "%.3f", sim.firstPull)) s; latency at 1 s \(at(1)), 3 s \(at(3)), 5 s \(at(5)), 8 s \(at(8)), 12 s \(at(12)); after 15 s \(PlaybackSimulation.ms(settled))")
        #expect(sim.firstPull >= 0.45)
        #expect(sim.pulls.first?.latency.map { $0 >= 0.44 && $0 <= 0.5 } == true) // the stream's first audio
        #expect(all.max()! <= 0.56)
        #expect(sim.latencies(from: 8, to: 9).max()! <= 0.2)
        #expect(settled.min()! >= 0.015 && settled.max()! <= 0.06)
        #expect(sim.underruns(from: sim.firstPull) == 0) // glitch-free from the first pull
        let stats = sim.playback.ringStatistics
        #expect(stats.heldStarts == 1 && stats.startTrims == 0 && stats.excessTrims == 0 && stats.ceilingTrims == 0)
        #expect(sim.playback.statistics == CoreAudioPlayback.Statistics())
    }

    /// The same when it is the building of the output that takes the time (a tenth of a second of an
    /// engine's start): the ring keeps the stream's beginning from before the output is built. It
    /// kept it only from the output's own start, and the first 70 ms of a video went at the ceiling.
    @Test(arguments: [0.11, 0.45])
    func aSlowlyBuiltOutputPlaysTheBeginningToo(delay: Double) {
        let sim = PlaybackSimulation(startDelay: delay, mostLead: 0.2, startLead: 0.1, slowBuild: true)
        sim.run(until: 12)
        #expect(sim.pulls.first?.latency.map { $0 >= delay - 0.01 && $0 <= delay + 0.05 } == true) // the stream's first audio
        #expect(sim.playback.statistics == CoreAudioPlayback.Statistics())
        #expect(sim.underruns(from: sim.firstPull) == 0)
        #expect(sim.latencies(from: 8).max()! <= 0.1 + 0.025) // at the start's lead
    }

    /// Normal Windows playback with an output clock 100 ppm off either way: the steering holds the
    /// level near the lead, and nothing is dropped or missed.
    @Test(arguments: [100.0, -100.0])
    func steadyPlaybackIsGlitchFree(drift: Double) {
        let sim = PlaybackSimulation(startDelay: 0.05, outputDrift: drift)
        sim.run(until: 20)
        let settled = sim.latencies(from: 1)
        print("steady, output \(drift > 0 ? "+" : "")\(Int(drift)) ppm: latency after 1 s \(PlaybackSimulation.ms(settled))")
        #expect(sim.underruns(from: sim.firstPull) == 0)
        #expect(settled.min()! >= 0.015 && settled.max()! <= 0.06)
        let stats = sim.playback.ringStatistics
        #expect(stats.excessTrims == 0 && stats.ceilingTrims == 0)
        // Nothing but what piled up while the output started (0.05 s, and a URB or two) was dropped, and nothing missed.
        let heard = sim.playback.statistics
        #expect(heard.gaps == 0 && heard.gapSeconds == 0 && heard.droppedSeconds < 0.08)
    }

    /// The guest stalls: the output plays silence, then the late URBs catch up all at once. That
    /// audio is played, not skipped: the ring holds it and the steering has the guest send a tenth
    /// slower until it is played down, ten times the stall's length on, so the stall doesn't stay
    /// as latency either. (It was dropped within a window or two: a gap, then a skip as long.)
    @Test(arguments: [0.07, 0.1, 0.15, 0.3])
    func aStallIsPlayedAndDoesNotStayAsLatency(stall: Double) {
        // Half a minute in: the little an output's start leaves above the lead is played by then.
        let at = 30.0
        let sim = PlaybackSimulation(startDelay: 0.05)
        sim.run(until: at)
        let droppedBefore = sim.playback.statistics.droppedSeconds
        sim.stall(at: at, for: stall)
        sim.run(until: at + 6)
        let before = sim.latencies(from: at - 2, to: at)
        // Played down by a tenth of real time, and a second for the steering to settle.
        let settledAt = at + stall + 10 * stall + 1
        let after = sim.latencies(from: settledAt)
        let worst = sim.latencies(from: at).max()!
        print("stall \(Int(stall * 1000)) ms: latency before \(PlaybackSimulation.ms(before)); worst after it \(String(format: "%.1f", worst * 1000)) ms; from \(String(format: "%.1f", settledAt - at)) s on \(PlaybackSimulation.ms(after))")
        #expect(worst <= 0.04 + stall + 0.02) // the lead and the stall, never more
        #expect(worst <= 0.04 + 0.25 + 0.02) // nor more than a rush's quarter of a second
        #expect(after.max()! <= 0.06) // back at the target
        #expect(sim.underruns(from: at + stall + 0.6) == 0)
        #expect(sim.playback.statistics.droppedSeconds == droppedBefore) // nothing skipped
        // The stall is said as one gap: the silence the output played past the lead, about.
        let heard = sim.playback.statistics
        print("stall \(Int(stall * 1000)) ms: \(heard.gaps) gap(s), \(String(format: "%.0f", heard.gapSeconds * 1000)) ms of silence, \(String(format: "%.0f", heard.droppedSeconds * 1000)) ms dropped")
        #expect(heard.gaps >= 1 && heard.gaps <= 2)
        #expect(heard.gapSeconds > stall - 0.06 && heard.gapSeconds < stall + 0.02)
    }

    /// A guest that keeps submitting late (a busy guest, or vCPUs waiting for a busy Mac's cores): 80 ms
    /// every two seconds. At a fixed 40 ms each one is a gap and a skip; the lead grows at the first
    /// to what the stalls need, and the rest are absorbed.
    @Test func theLeadGrowsToWhatAStallingGuestNeeds() {
        let fixed = PlaybackSimulation(startDelay: 0.05)
        let fitted = PlaybackSimulation(startDelay: 0.05, mostLead: 0.2)
        for sim in [fixed, fitted] {
            for at in stride(from: 3.0, to: 23, by: 2) { sim.stall(at: at, for: 0.08) }
            sim.run(until: 24)
        }
        let before = fixed.playback.statistics, after = fitted.playback.statistics
        print("stalls of 80 ms every 2 s: at 40 ms \(before.gaps) gaps, \(String(format: "%.0f", before.gapSeconds * 1000)) ms of silence, \(String(format: "%.0f", before.droppedSeconds * 1000)) ms dropped; fitted \(after.gaps) gap(s), \(String(format: "%.0f", after.gapSeconds * 1000)) ms, \(String(format: "%.0f", after.droppedSeconds * 1000)) ms dropped; lead \(fitted.leads.map { String(format: "%.0f ms at %.1f s", $0.lead * 1000, $0.time) })")
        #expect(before.gaps == 10)
        #expect(after.gaps <= 2)
        #expect(fitted.underruns(from: 6) == 0) // from the second stall on, at the latest
        #expect(fitted.lead >= 0.09 && fitted.lead <= 0.14)
        // The audio waits in the ring as long as the lead says, and no longer.
        let settled = fitted.latencies(from: 8)
        #expect(settled.max()! <= fitted.lead + 0.025)
        // Nothing dropped for it but what the first stall's catching up took.
        #expect(after.droppedSeconds <= before.droppedSeconds / 5 + 0.1)
    }

    /// The lead comes down again once the guest's audio has come on time for a while, 10 ms each
    /// half minute, without a gap or a drop for it.
    @Test func theLeadComesDownWhenTheGuestIsOnTimeAgain() {
        let sim = PlaybackSimulation(startDelay: 0.05, mostLead: 0.2)
        sim.stall(at: 3, for: 0.1)
        sim.run(until: 6)
        let grown = sim.lead
        let heard = sim.playback.statistics
        let trims = sim.playback.ringStatistics
        sim.run(until: 100)
        print("one stall of 100 ms, then on time: lead \(sim.leads.map { String(format: "%.0f ms at %.1f s", $0.lead * 1000, $0.time) })")
        #expect(grown >= 0.1 && grown <= 0.14)
        #expect(sim.lead <= grown - 0.025 && sim.lead >= 0.04) // three steps in 94 s
        #expect(sim.underruns(from: 6) == 0)
        #expect(sim.playback.statistics == heard) // no gap and no drop since
        #expect(sim.playback.ringStatistics == trims)
        #expect(sim.latencies(from: 95).max()! <= sim.lead + 0.025)
    }

    /// A guest that needs its lead keeps it: with 80 ms stalls every 20 s, the lead comes down only
    /// while 40 ms are left at each stall, and no stall is heard after the first.
    @Test func aLeadThatIsNeededStays() {
        let sim = PlaybackSimulation(startDelay: 0.05, mostLead: 0.2)
        for at in stride(from: 3.0, to: 180, by: 20) { sim.stall(at: at, for: 0.08) }
        sim.run(until: 185)
        print("stalls of 80 ms every 20 s for 3 min: lead \(sim.leads.map { String(format: "%.0f ms at %.1f s", $0.lead * 1000, $0.time) }); \(sim.playback.statistics.gaps) gap(s)")
        #expect(sim.playback.statistics.gaps <= 2)
        #expect(sim.underruns(from: 6) == 0)
        #expect(sim.lead >= 0.09)
    }

    /// A guest is busiest as it starts to play: 90 ms with nothing sent, a second and a half into the
    /// stream. At 40 ms that is a gap and a skip in the first words; a stream starts with 100 ms,
    /// which takes it, and is at 40 ms two minutes later, with nothing dropped on the way down.
    @Test func aStreamsStartHasRoomForABusyGuest() {
        let fixed = PlaybackSimulation(startDelay: 0.05)
        let cushioned = PlaybackSimulation(startDelay: 0.05, mostLead: 0.2, startLead: 0.1)
        for sim in [fixed, cushioned] {
            sim.stall(at: 1.5, for: 0.09)
            sim.run(until: 5)
        }
        #expect(fixed.playback.statistics.gaps == 1)
        #expect(cushioned.playback.statistics.gaps == 0)
        #expect(cushioned.underruns(from: cushioned.firstPull) == 0)
        let trims = cushioned.playback.ringStatistics
        cushioned.run(until: 125)
        print("a stream starting at 100 ms with a 90 ms stall at 1.5 s: lead \(cushioned.leads.map { String(format: "%.0f ms at %.1f s", $0.lead * 1000, $0.time) })")
        #expect(cushioned.lead <= 0.045)
        #expect(cushioned.playback.statistics.gaps == 0)
        #expect(cushioned.playback.ringStatistics == trims) // nothing dropped as the lead came down
        #expect(cushioned.underruns(from: cushioned.firstPull) == 0)
        #expect(cushioned.latencies(from: 122).max()! <= cushioned.lead + 0.025)
    }

    /// A stall shorter than the lead is what the lead is for: nothing heard, nothing dropped.
    @Test func aStallShorterThanTheLeadIsAbsorbed() {
        let sim = PlaybackSimulation(startDelay: 0.05)
        sim.stall(at: 3, for: 0.025)
        sim.run(until: 6)
        #expect(sim.underruns(from: sim.firstPull) == 0)
        #expect(sim.playback.ringStatistics.excessTrims == 0)
        #expect(sim.latencies(from: 1).max()! <= 0.06)
        #expect(sim.playback.statistics.gaps == 0)
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
