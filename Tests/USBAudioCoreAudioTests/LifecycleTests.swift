import Foundation
import Testing
@testable import USBAudioCoreAudio
@testable import USBAudioDevice

@Suite struct PlaybackLifecycleTests {
    private func playback(_ outputs: FakeOutputs, idleStop: TimeInterval = 30) -> CoreAudioPlayback {
        CoreAudioPlayback(idleStop: idleStop, bounds: .playback) { try outputs.make($0, $1) }
    }

    /// A runner drops its USB audio after a restart with other settings, and the Mac's audio stops
    /// with it: no call of its own, no 30 s idle stop.
    @Test func aFreedPlaybackStopsItsOutput() throws {
        let outputs = FakeOutputs()
        var sink: CoreAudioPlayback? = playback(outputs)
        sink?.playbackStarted()
        sink?.play(Data(count: 1920))
        sink?.waitForQueue()
        let output = try #require(outputs.all.first)
        #expect(output.isRunning)
        let freed = Weak(sink)
        sink = nil
        #expect(freed.object == nil)
        #expect(eventually { !output.isRunning && output.stopCount >= 1 })
    }

    /// The runner lets its USB audio go on its main thread, and an engine's stop takes 25-40 ms there,
    /// more on Bluetooth: a freed playback hands its output to a queue to stop, and returns at once.
    @Test func aFreedPlaybackDoesNotWaitForItsOutputToStop() throws {
        let outputs = FakeOutputs()
        let stopGate = DispatchSemaphore(value: 0)
        outputs.stopGate = stopGate
        var sink: CoreAudioPlayback? = playback(outputs)
        sink?.playbackStarted()
        sink?.waitForQueue()
        let output = try #require(outputs.all.first)
        let freed = Weak(sink)
        sink = nil // a stop here would wait 10 s for the gate, and be counted
        #expect(freed.object == nil)
        #expect(output.stopCount == 0)
        stopGate.signal()
        #expect(eventually { !output.isRunning && output.stopCount == 1 })
    }

    /// A device change in the idle window after a stream used to build the engine again and cancel
    /// its stop, so it ran until the next stream ended. Now it just stops.
    @Test func aDeviceChangeAfterTheStreamStopsTheOutput() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs)
        sink.playbackStarted()
        sink.waitForQueue() // a start and a stop the queue takes together start nothing
        sink.playbackStopped()
        sink.waitForQueue()
        let output = try #require(outputs.all.first)
        #expect(output.isRunning) // the idle window
        output.deviceChanged()
        #expect(eventually { output.stopCount >= 1 })
        Thread.sleep(forTimeInterval: 1.2) // past the second a rebuild waits for
        sink.waitForQueue()
        #expect(outputs.all.count == 1)
        // A stream after it starts one again.
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(outputs.all.count == 2 && outputs.all[1].isRunning)
    }

    /// While the host streams, a device change builds the output again on the new device, a second
    /// after the last start; the idle stop still comes after the stream.
    @Test func aDeviceChangeWhileStreamingRebuildsTheOutputAndTheIdleStopStillComes() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs, idleStop: 0.2)
        sink.playbackStarted()
        sink.waitForQueue()
        try #require(outputs.all.first).deviceChanged()
        #expect(eventually(within: 3) { outputs.all.count == 2 && outputs.all[1].isRunning })
        #expect(outputs.all[0].stopCount >= 1)
        sink.playbackStopped()
        #expect(eventually { !outputs.all[1].isRunning })
    }

    /// A change while the engine starts was lost when observed only after start(): the engine stayed
    /// stopped, and silent, for the rest of the stream.
    @Test func aChangeWhileStartingIsNotLost() {
        let outputs = FakeOutputs()
        outputs.changeWhileStarting = true
        let sink = playback(outputs)
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(eventually { outputs.all.first?.stopCount ?? 0 >= 1 }) // taken down, not kept
        outputs.changeWhileStarting = false
        #expect(eventually(within: 3) { outputs.all.count == 2 && outputs.all[1].isRunning })
    }

    /// An engine that stopped without a notification counts as a change at the next URB.
    @Test func aStoppedOutputIsReplaced() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs)
        sink.playbackStarted()
        sink.waitForQueue()
        try #require(outputs.all.first).stopSilently()
        let replaced = eventually(within: 3) {
            sink.play(Data(count: 1920))
            return outputs.all.count == 2 && outputs.all[1].isRunning
        }
        #expect(replaced)
        #expect(outputs.all[0].stopCount >= 1)
    }

    /// The idle window over, the output pauses rather than goes: the next stream starts the same one
    /// again, which takes milliseconds where building one took up to half a second, and that much of
    /// the stream's beginning with it (11 Nov 2026).
    @Test func theIdleStopPausesTheOutputAndTheNextStreamStartsItAgain() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs, idleStop: 0.2)
        let said = Box<[String]>([])
        sink.log = { line in said.mutate { $0.append(line) } }
        sink.playbackStarted()
        sink.waitForQueue()
        let output = try #require(outputs.all.first)
        #expect(output.isRunning && output.startCount == 1)
        sink.playbackStopped()
        #expect(eventually { output.pauseCount == 1 && !output.isRunning })
        #expect(output.stopCount == 0)
        // Nothing more happens to it while nothing plays.
        Thread.sleep(forTimeInterval: 0.4)
        sink.waitForQueue()
        #expect(output.pauseCount == 1 && output.stopCount == 0)
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(outputs.all.count == 1)
        #expect(output.isRunning && output.startCount == 2 && output.stopCount == 0)
        // And again after the next idle window.
        sink.playbackStopped()
        #expect(eventually { output.pauseCount == 2 && !output.isRunning })
        sink.play(Data(count: 1920)) // audio with no start event after it: nothing starts
        sink.waitForQueue()
        #expect(!output.isRunning)
        let lines = said.value
        #expect(lines.filter { $0.contains("output engine paused") }.count == 2)
        #expect(lines.filter { $0.contains("output engine started again") }.count == 1)
    }

    /// On a wired output the engine runs on for longer after a stream (two minutes in use), since
    /// starting the Mac's audio hardware costs each stream its first half second; on a wireless one,
    /// which a silent stream holds and drains, for the short time.
    @Test func aWiredOutputRunsOnLongerAfterAStream() throws {
        let outputs = FakeOutputs()
        let sink = CoreAudioPlayback(idleStop: 0.2, wiredIdleStop: 1.5, bounds: .playback) { try outputs.make($0, $1) }
        sink.playbackStarted()
        sink.waitForQueue()
        let output = try #require(outputs.all.first)
        output.isWired = true
        sink.playbackStopped()
        sink.waitForQueue()
        Thread.sleep(forTimeInterval: 0.7) // well past the short time
        sink.waitForQueue()
        #expect(output.isRunning && output.pauseCount == 0)
        // A stream in that time finds it running: nothing to start.
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(output.startCount == 1)
        sink.playbackStopped()
        #expect(eventually(within: 3) { output.pauseCount == 1 && !output.isRunning })
        // The Mac's output is a headset now: the short time.
        output.isWired = false
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(output.isRunning && output.startCount == 2)
        sink.playbackStopped()
        #expect(eventually(within: 1) { output.pauseCount == 2 })
    }

    /// A paused output that doesn't start again (the Mac's output went meanwhile, without a word) is
    /// let go and another built, in the same stream start.
    @Test func aPausedOutputThatDoesNotStartAgainIsReplaced() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs, idleStop: 0.2)
        sink.playbackStarted()
        sink.waitForQueue()
        let first = try #require(outputs.all.first)
        sink.playbackStopped()
        #expect(eventually { first.pauseCount == 1 })
        first.failToResume()
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(outputs.all.count == 2)
        #expect(first.stopCount == 1 && !first.isRunning)
        #expect(outputs.all[1].isRunning)
    }

    /// A change of the Mac's output while the output is paused lets it go; the next stream builds one
    /// on the new device.
    @Test func aDeviceChangeWhilePausedLetsTheOutputGo() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs, idleStop: 0.2)
        sink.playbackStarted()
        sink.waitForQueue()
        let first = try #require(outputs.all.first)
        sink.playbackStopped()
        #expect(eventually { first.pauseCount == 1 })
        first.deviceChanged()
        #expect(eventually { first.stopCount == 1 })
        Thread.sleep(forTimeInterval: 1.2) // past the second a rebuild waits for: none comes
        sink.waitForQueue()
        #expect(outputs.all.count == 1)
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(outputs.all.count == 2 && outputs.all[1].isRunning)
    }

    /// A freed playback stops a paused output too.
    @Test func aFreedPlaybackStopsItsPausedOutput() throws {
        let outputs = FakeOutputs()
        var sink: CoreAudioPlayback? = playback(outputs, idleStop: 0.2)
        sink?.playbackStarted()
        sink?.waitForQueue()
        let output = try #require(outputs.all.first)
        sink?.playbackStopped()
        #expect(eventually { output.pauseCount == 1 })
        sink = nil
        #expect(eventually { output.stopCount == 1 })
    }

    /// The server's steering holds the sink at its lead; it used to hold whatever the first two
    /// seconds of a stream showed (half a second, after a slow engine start).
    @Test func theSteeringHoldsTheLeadNotTheFirstLevel() {
        var steering = PlaybackSteering(setPoint: 0.04)
        for _ in 1 ... 8 { #expect(steering.adjustment(level: 0.45) == 0) } // two seconds of following
        #expect(steering.adjustment(level: 0.45) == -500) // far too much buffered: as slow as it goes
        var settled = PlaybackSteering(setPoint: 0.04)
        for _ in 1 ... 40 { _ = settled.adjustment(level: 0.04) }
        #expect(abs(settled.adjustment(level: 0.04)) < 1)
        #expect(settled.adjustment(level: nil) == 0) // nothing plays: start over
        #expect(settled.adjustment(level: 0.45) == 0)
    }

    /// A sink whose output started late with the stream's beginning says how much it holds for that:
    /// while it does, the pacer runs a tenth slow, never by more in a quarter second than is there
    /// to play, the drift correction resting meanwhile.
    @Test func theSteeringPlaysALateStartsBacklogDown() {
        var steering = PlaybackSteering(setPoint: 0.1)
        #expect(steering.adjustment(level: 0.6, backlog: 0.5) == -100_000) // 25 ms a quarter second
        #expect(steering.adjustment(level: 0.16, backlog: 0.06) == -100_000)
        #expect(abs(steering.adjustment(level: 0.123, backlog: 0.023) - -40_000) < 1) // half of the 20 ms above the floor
        // The floor and below is left to the drift correction, after two seconds of following.
        for _ in 1 ... 8 { #expect(steering.adjustment(level: 0.1, backlog: 0.003) == 0) }
        #expect(abs(steering.adjustment(level: 0.1, backlog: 0)) < 1)
        // What the sink holds while nothing plays is its to play out.
        #expect(steering.adjustment(level: nil, backlog: 0.5) == 0)
    }

    /// An output that started twice (the Mac's output changed just after a stream began) said its
    /// backlog twice, and a count of it ran the pacer slow for twice as long: the lead drained. The
    /// sink says what it holds now, so what it said before doesn't add up.
    @Test func aBacklogIsWhatTheSinkHoldsNow() throws {
        let ring = StereoRing(capacitySeconds: 1.5, bounds: .playback)
        ring.outputStarts()
        ring.write(int16: tagged(first: 0, frames: 24000))
        #expect(ring.heldExcess == 0) // nothing reads yet: nothing to play down
        var left = [Float](repeating: 0, count: 480), right = left
        #expect(ring.read(frames: 480, left: &left, right: &right) == 480)
        #expect(ring.heldExcess == 24000 - 1920)
        // The output starts again with as much: the same audio, said once.
        ring.outputStarts()
        #expect(ring.read(frames: 480, left: &left, right: &right) == 480)
        #expect(ring.heldExcess == 24000 - 480 - 1920)
        // Played down to the usual bounds: none.
        for _ in 0 ..< 100 { _ = ring.read(frames: 480, left: &left, right: &right) } // a second: four windows
        #expect(ring.heldExcess == 0)
        ring.clear()
        #expect(ring.heldExcess == 0)
    }

    /// A stream that ends with no output (it failed to start, or went with the Mac's output) leaves
    /// nothing in the ring for the next one: its tail played before the next stream, however old.
    @Test func aStreamThatEndsWithNoOutputLeavesNothingBehind() {
        let outputs = FakeOutputs()
        outputs.fail = true
        let sink = playback(outputs, idleStop: 0.2)
        sink.playbackStarted()
        sink.waitForQueue() // the start is tried, and fails
        for _ in 0 ..< 30 { sink.play(Data(count: 1920)) } // 0.3 s, kept for an output that never comes
        sink.waitForQueue()
        #expect((sink.bufferedSeconds ?? 0) > 0.25)
        sink.playbackStopped()
        #expect(eventually { (sink.bufferedSeconds ?? 1) == 0 })
        #expect(sink.startBacklog == 0)
    }
}

@Suite struct CaptureLifecycleTests {
    private func capture(_ inputs: FakeInputs, idleClose: TimeInterval = 1) -> CoreAudioCapture {
        CoreAudioCapture(idleClose: idleClose) { try inputs.make($0, $1) }
    }

    @Test func aFreedCaptureClosesTheMicrophone() throws {
        let inputs = FakeInputs()
        var source: CoreAudioCapture? = capture(inputs)
        source?.captureStarted()
        source?.waitForQueue()
        let input = try #require(inputs.all.first)
        #expect(input.isRunning)
        let freed = Weak(source)
        source = nil
        #expect(freed.object == nil)
        #expect(eventually { !input.isRunning && input.stopCount >= 1 })
    }

    /// As for playback: the microphone closes on a queue of its own, not on the thread that lets the
    /// capture go.
    @Test func aFreedCaptureDoesNotWaitForTheMicrophoneToClose() throws {
        let inputs = FakeInputs()
        let stopGate = DispatchSemaphore(value: 0)
        inputs.stopGate = stopGate
        var source: CoreAudioCapture? = capture(inputs)
        source?.captureStarted()
        source?.waitForQueue()
        let input = try #require(inputs.all.first)
        let freed = Weak(source)
        source = nil // a stop here would wait 10 s for the gate, and be counted
        #expect(freed.object == nil)
        #expect(input.stopCount == 0)
        stopGate.signal()
        #expect(eventually { !input.isRunning && input.stopCount == 1 })
    }

    /// A paused VM asks for no audio: the microphone closes, and opens again, once, when it asks.
    @Test func theMicrophoneClosesWhenTheHostStopsAskingAndOpensWhenItAsks() {
        let inputs = FakeInputs()
        // A gap of 0.5 s closes it: a URB every 10 ms keeps it open even on a slow CI Mac, and the close
        // still comes well within `eventually`'s 2 s.
        let source = capture(inputs, idleClose: 0.5)
        source.captureStarted()
        for _ in 0 ..< 30 { // 0.3 s or more of a recording host: stays open
            _ = source.captureAudio(byteCount: 1920)
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(source.isOpen && inputs.all.count == 1)
        #expect(eventually { !source.isOpen }) // paused
        #expect(inputs.all[0].stopCount >= 1)
        for _ in 0 ..< 50 { _ = source.captureAudio(byteCount: 1920) } // resumed: a burst of URBs
        source.waitForQueue()
        #expect(source.isOpen && inputs.all.count == 2) // opened once, not per URB
        source.captureStopped()
        source.waitForQueue()
        #expect(!source.isOpen)
    }

    /// A microphone that fails to open is tried again after a growing pause, not at every URB.
    @Test func aFailingMicrophoneIsTriedLessAndLessOften() {
        let inputs = FakeInputs()
        inputs.fail = true
        let source = capture(inputs)
        source.captureStarted()
        source.waitForQueue()
        #expect(inputs.all.count == 1)
        // URBs for 0.25 s by the clock, well within the first pause (0.5 s from the failure, which came
        // before this): a count of loops took longer than the pause on a slow CI Mac.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.25 {
            _ = source.captureAudio(byteCount: 1920)
            Thread.sleep(forTimeInterval: 0.01)
        }
        source.waitForQueue()
        #expect(inputs.all.count == 1)
        inputs.fail = false
        let opened = eventually {
            _ = source.captureAudio(byteCount: 1920)
            return source.isOpen
        }
        #expect(opened && inputs.all.count == 2)
    }

    /// Exactly the bytes asked for, whatever the count: the server's reply says that many.
    @Test(arguments: [0, 2, 191, 1920, 1922])
    func captureReturnsExactlyTheBytesAskedFor(byteCount: Int) {
        let source = capture(FakeInputs())
        #expect(source.captureAudio(byteCount: byteCount).count == byteCount)
    }
}

@Suite struct RingTests {
    /// Silence in the middle of a stream is a gap when audio follows it soon; seconds of it is a
    /// stream left open with nothing to play.
    @Test func secondsOfSilenceInAnOpenStreamAreNoGap() {
        let ring = StereoRing(capacitySeconds: 1.5, bounds: .playback)
        var left = [Float](repeating: 0, count: 480), right = left
        ring.write(int16: tagged(first: 0, frames: 480))
        _ = ring.read(frames: 480, left: &left, right: &right)
        for _ in 0 ..< 5 { _ = ring.read(frames: 480, left: &left, right: &right) } // 50 ms of nothing
        ring.write(int16: tagged(first: 480, frames: 480))
        #expect(ring.statistics.gaps == 1 && ring.statistics.gapFrames == 2400)
        _ = ring.read(frames: 480, left: &left, right: &right)
        for _ in 0 ..< 300 { _ = ring.read(frames: 480, left: &left, right: &right) } // three seconds
        ring.write(int16: tagged(first: 960, frames: 480))
        #expect(ring.statistics.gaps == 1 && ring.statistics.gapFrames == 2400)
    }

    /// An output that starts has the stream from its beginning: what was played while it started
    /// isn't dropped for the newest 40 ms (it was), and isn't held to the ceiling while it is played
    /// down.
    @Test func anOutputStartsWithTheStreamsBeginning() {
        let ring = StereoRing(capacitySeconds: 1.5, bounds: .playback)
        ring.outputStarts()
        ring.write(int16: tagged(first: 0, frames: 24000)) // half a second while it starts
        var left = [Float](repeating: 0, count: 1), right = left
        #expect(ring.read(frames: 1, left: &left, right: &right) == 1)
        #expect(Int((left[0] * 32768).rounded()) == 0)
        #expect(ring.bufferedFrames == 24000 - 1)
        ring.write(int16: tagged(first: 24000, frames: 480))
        #expect(ring.bufferedFrames == 24480 - 1) // above the ceiling, and kept
        let stats = ring.statistics
        #expect(stats.heldStarts == 1 && stats.startTrims == 0 && stats.ceilingTrims == 0 && stats.trimmedFrames == 0)
    }

    /// One that takes longer than that has the newest three quarters of a second above the target:
    /// the oldest goes while it starts.
    @Test func anOutputThatStartsLateHasTheNewestOfWhatWasKept() {
        let ring = StereoRing(capacitySeconds: 1.5, bounds: .playback)
        ring.outputStarts()
        for urb in 0 ..< 120 { ring.write(int16: tagged(first: urb * 480, frames: 480)) } // 1.2 s
        #expect(ring.bufferedFrames <= 1920 + 36000 + 960)
        var left = [Float](repeating: 0, count: 1), right = left
        #expect(ring.read(frames: 1, left: &left, right: &right) == 1)
        let first = Int((left[0] * 32768).rounded()) | Int((right[0] * 32768).rounded()) << 15
        #expect(first == 57600 - (1920 + 36000))
        #expect(ring.statistics.trimmedFrames == 57600 - (1920 + 36000))
    }

    /// An output that starts with no more than the target and a little has nothing to play down.
    @Test func anOutputThatStartsAtOnceIsHeldToTheUsualBounds() {
        let ring = StereoRing(capacitySeconds: 1.5, bounds: .playback)
        ring.outputStarts()
        ring.write(int16: tagged(first: 0, frames: 1920))
        var left = [Float](repeating: 0, count: 1), right = left
        #expect(ring.read(frames: 1, left: &left, right: &right) == 1)
        #expect(ring.statistics.heldStarts == 0)
        for urb in 0 ..< 50 { ring.write(int16: tagged(first: 1920 + urb * 480, frames: 480)) }
        // A rush from here on: a quarter of a second of it is kept above the target, no more.
        #expect(ring.bufferedFrames <= 1920 + 12000 + 960)
        #expect(ring.statistics.heldRushes == 1)
    }

    /// Nothing reads (an output that failed to start, say): the ring keeps a rush's quarter of a
    /// second above the target and drops the oldest of more, so what it holds stays bounded.
    @Test func writesWithNothingReadingKeepARushAndNoMore() {
        let ring = StereoRing(capacitySeconds: 0.5, bounds: .playback)
        for urb in 0 ..< 50 {
            ring.write(int16: tagged(first: urb * 480, frames: 480))
            #expect(ring.bufferedFrames <= 1920 + 12000 + 960)
        }
        #expect(ring.bufferedFrames >= 1920 + 12000)
        #expect(ring.statistics.heldRushes == 1 && ring.statistics.ceilingTrims > 0)
    }

    /// A ring whose bounds keep no rush (a sink nothing steers) drops to the target at the ceiling,
    /// as every ring did before 12 Nov 2026.
    @Test func writesPastTheCeilingDropToTheTargetWithoutARushKept() {
        var bounds = StereoRing.Bounds.playback
        bounds.rushKeep = 0
        let ring = StereoRing(capacitySeconds: 0.5, bounds: bounds)
        for urb in 0 ..< 50 {
            ring.write(int16: tagged(first: urb * 480, frames: 480))
            #expect(ring.bufferedFrames <= 4800)
        }
        #expect(ring.bufferedFrames >= 1920)
        #expect(ring.statistics.heldRushes == 0)
    }

    /// A rush in the middle of a stream is kept whole and said to the server (`heldExcess`), which
    /// plays it down; the ring lets go of the hold once its level is back at the target. It used to
    /// drop what was above the target: a skip as long as the gap before it.
    @Test func aRushIsHeldForTheServerToPlayDown() {
        let ring = StereoRing(capacitySeconds: 1.5, bounds: .playback)
        var left = [Float](repeating: 0, count: 480), right = left
        var next = 0
        func write(_ frames: Int) { ring.write(int16: tagged(first: next, frames: frames)); next += frames }
        // Steady at the target: a URB in, a URB out.
        write(1920)
        for _ in 0 ..< 100 { write(480); _ = ring.read(frames: 480, left: &left, right: &right) }
        #expect(ring.heldExcess == 0)
        // 150 ms comes at once.
        write(7200)
        #expect(ring.bufferedFrames == 1920 + 7200)
        #expect(ring.heldExcess == 7200)
        #expect(ring.statistics.heldRushes == 1 && ring.statistics.trimmedFrames == 0 && ring.statistics.excessFrames == 0)
        // The server has the guest send a tenth less: 432 frames in for each 480 out.
        var reads = 0
        while ring.heldExcess > 0, reads < 2000 {
            write(432)
            _ = ring.read(frames: 480, left: &left, right: &right)
            reads += 1
        }
        #expect(reads > 100 && reads < 200) // 7200 frames at 48 a read
        #expect(ring.bufferedFrames <= 1920 + 480)
        #expect(ring.statistics.trimmedFrames == 0 && ring.statistics.excessFrames == 0) // nothing skipped
    }

    /// A rush nobody plays down (nothing steers this ring's source) goes after all, once the time
    /// the server has for it is over: the latency doesn't stay.
    @Test func aRushNobodyPlaysDownIsDroppedInTheEnd() {
        var bounds = StereoRing.Bounds.playback
        bounds.startHold = StereoRing.Bounds.frames(ms: 1000)
        let ring = StereoRing(capacitySeconds: 1.5, bounds: bounds)
        var left = [Float](repeating: 0, count: 480), right = left
        var next = 0
        func write(_ frames: Int) { ring.write(int16: tagged(first: next, frames: frames)); next += frames }
        write(1920)
        for _ in 0 ..< 100 { write(480); _ = ring.read(frames: 480, left: &left, right: &right) }
        write(7200)
        #expect(ring.heldExcess == 7200)
        for _ in 0 ..< 150 { write(480); _ = ring.read(frames: 480, left: &left, right: &right) } // a second and a half
        #expect(ring.heldExcess == 0)
        #expect(ring.statistics.excessTrims == 1 && ring.statistics.excessFrames >= 7200 - 480)
        #expect(ring.bufferedFrames <= 1920 + 480)
    }

    /// The host starts asking for microphone audio late, or a fast microphone fills the ring: the
    /// trim keeps one of the tap's 100 ms buffers and a margin. Trimming to 40 ms left the host about
    /// 60 ms of silence before the next buffer.
    @Test func theCaptureTrimKeepsATapBuffer() {
        let ring = StereoRing(capacitySeconds: 1)
        var silent = 0
        var tap = 0.0 // ms of the next tap buffer
        let tapFrames = 4800
        for ms in stride(from: 0.0, to: 3000, by: 10) {
            while tap <= ms {
                let buffer = [Float](repeating: 0.5, count: tapFrames * 2)
                buffer.withUnsafeBufferPointer { ring.write(float: $0) }
                tap += 100 + (tap.truncatingRemainder(dividingBy: 300) == 0 ? 4 : -2) // a little jitter
            }
            guard ms >= 300 else { continue } // the host starts asking 0.3 s in: the ring is full
            let (_, n) = ring.readInt16(frames: 480, keepFrames: 1920, marginFrames: 960, trimAboveFrames: 7200)
            if n < 480 { silent += 480 - n }
            #expect(ring.bufferedFrames <= 4800 * 2 + 960 * 2)
        }
        #expect(silent == 0)
    }
}
