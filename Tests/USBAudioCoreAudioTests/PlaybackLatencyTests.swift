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

    /// - Parameter outputDrift: the output's clock against the Mac's, in ppm (positive: faster).
    init(startDelay: TimeInterval, outputDrift: Double = 0) {
        self.startDelay = startDelay
        pullInterval = 512 / 48000 * 1e9 / (1 + outputDrift / 1e6)
        let outputs = outputs
        let gate = gate
        outputs.gate = gate
        playback = CoreAudioPlayback(idleStop: 30, bounds: .playback) { outputs.make($0, $1) }
        pacer = EndpointPacer(lead: 0.04, clock: clock)
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
                pacer.setRateAdjustment(ppm: steering.adjustment(level: playback.bufferedSeconds))
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

    static func ms(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max() else { return "none" }
        let mean = values.reduce(0, +) / Double(values.count)
        return String(format: "%.1f–%.1f ms (mean %.1f)", low * 1000, high * 1000, mean * 1000)
    }
}

@Suite struct PlaybackLatencyTests {
    /// An output that takes 0.45 s to start (the Mac's default output took 0.43 s) used to start
    /// with half a second in the ring and keep it; the stream started 0.5 s behind and stayed there.
    @Test func aSlowEngineStartLeavesNoLatencyBehind() {
        let sim = PlaybackSimulation(startDelay: 0.45)
        sim.run(until: 10)
        let all = sim.latencies(from: 0)
        let settled = sim.latencies(from: 1)
        print("slow start (0.45 s): first pull at \(String(format: "%.3f", sim.firstPull)) s; latency \(PlaybackSimulation.ms(all)); after 1 s \(PlaybackSimulation.ms(settled))")
        #expect(sim.firstPull >= 0.45)
        #expect(all.max()! <= 0.045) // the start trims to the 40 ms target
        #expect(settled.min()! >= 0.015 && settled.max()! <= 0.06)
        #expect(sim.underruns(from: sim.firstPull) == 0) // glitch-free from the first pull
        let stats = sim.playback.ringStatistics
        #expect(stats.startTrims == 1 && stats.excessTrims == 0)
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
    }

    /// The guest stalls: the output plays silence, then the late URBs catch up all at once. What
    /// the stall would leave as latency goes within a window or two.
    @Test(arguments: [0.07, 0.1, 0.15, 0.3])
    func aStallDoesNotStayAsLatency(stall: Double) {
        let sim = PlaybackSimulation(startDelay: 0.45)
        sim.stall(at: 3, for: stall)
        sim.run(until: 8)
        let before = sim.latencies(from: 1, to: 3)
        let after = sim.latencies(from: 3 + stall + 0.6)
        let worst = sim.latencies(from: 3).max()!
        print("stall \(Int(stall * 1000)) ms: latency before \(PlaybackSimulation.ms(before)); worst after it \(String(format: "%.1f", worst * 1000)) ms; 0.6 s on \(PlaybackSimulation.ms(after))")
        #expect(worst <= 0.1) // never past the ceiling
        #expect(after.max()! <= 0.055) // back at the target (the 70 ms stall used to stay at 54–64 ms)
        #expect(sim.underruns(from: 3 + stall + 0.6) == 0)
    }

    /// A stall shorter than the lead is what the lead is for: nothing heard, nothing dropped.
    @Test func aStallShorterThanTheLeadIsAbsorbed() {
        let sim = PlaybackSimulation(startDelay: 0.05)
        sim.stall(at: 3, for: 0.025)
        sim.run(until: 6)
        #expect(sim.underruns(from: sim.firstPull) == 0)
        #expect(sim.playback.ringStatistics.excessTrims == 0)
        #expect(sim.latencies(from: 1).max()! <= 0.06)
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
