import Foundation
import Testing
@testable import USBAudioCoreAudio
@testable import USBAudioDevice

@Suite struct PlaybackLifecycleTests {
    private func playback(_ outputs: FakeOutputs, idleStop: TimeInterval = 30) -> CoreAudioPlayback {
        CoreAudioPlayback(idleStop: idleStop, bounds: .playback) { outputs.make($0, $1) }
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
        #expect(!output.isRunning && output.stopCount >= 1)
    }

    /// A device change in the idle window after a stream used to build the engine again and cancel
    /// its stop, so it ran until the next stream ended. Now it just stops.
    @Test func aDeviceChangeAfterTheStreamStopsTheOutput() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs)
        sink.playbackStarted()
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
        #expect(!input.isRunning && input.stopCount >= 1)
    }

    /// A paused VM asks for no audio: the microphone closes, and opens again, once, when it asks.
    @Test func theMicrophoneClosesWhenTheHostStopsAskingAndOpensWhenItAsks() {
        let inputs = FakeInputs()
        let source = capture(inputs, idleClose: 0.2)
        source.captureStarted()
        for _ in 0 ..< 30 { // 0.3 s of a recording host: stays open
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
        for _ in 0 ..< 30 { // 0.3 s: within the first pause (0.5 s)
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
    /// The first read after an output starts has the newest 40 ms: the audio due now.
    @Test func anOutputStartsWithTheNewestTarget() {
        let ring = StereoRing(capacitySeconds: 0.5, bounds: .playback)
        ring.write(int16: tagged(first: 0, frames: 4320)) // 90 ms, below the ceiling
        ring.trimOnNextRead()
        var left = [Float](repeating: 0, count: 1), right = left
        #expect(ring.read(frames: 1, left: &left, right: &right) == 1)
        #expect(Int((left[0] * 32768).rounded()) == 4320 - 1920)
        #expect(ring.bufferedFrames == 1920 - 1)
    }

    /// Nothing reads while an output starts: the ring stays between the target and the ceiling.
    @Test func writesPastTheCeilingDropToTheTarget() {
        let ring = StereoRing(capacitySeconds: 0.5, bounds: .playback)
        for urb in 0 ..< 50 {
            ring.write(int16: tagged(first: urb * 480, frames: 480))
            #expect(ring.bufferedFrames <= 4800)
        }
        #expect(ring.bufferedFrames >= 1920)
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
