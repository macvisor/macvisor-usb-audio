import Foundation
import Testing
@testable import USBAudioCoreAudio
@testable import USBAudioDevice

/// A guest can start and stop its streams as fast as it sends SET_INTERFACE (5 Nov 2026). Each event
/// used to queue a block of its own: every microphone start built an engine and reset the failures'
/// pause, every playback stop left a 30 s work item behind, and a flood grew the queue until the
/// runner was killed. These flood a playback and a capture with stand-ins and count what they did.
/// Bounds that depend on time are worked out from the time the flood took, so a slow Mac gets more,
/// never a failure.
@Suite struct StreamFloodTests {
    private static let toggles = 10_000

    private func playback(_ outputs: FakeOutputs, idleStop: TimeInterval = 30) -> CoreAudioPlayback {
        CoreAudioPlayback(idleStop: idleStop, bounds: .playback) { try outputs.make($0, $1) }
    }

    private func capture(_ inputs: FakeInputs) -> CoreAudioCapture {
        CoreAudioCapture(idleClose: 1) { try inputs.make($0, $1) }
    }

    /// How many attempts a growing pause allows in `seconds` (0.5, 1, 2… seconds after each failure).
    private func attemptsAllowed(in seconds: TimeInterval) -> Int {
        var attempts = 1
        var at = 0.0
        while true {
            at += min(30, 0.5 * pow(2, Double(attempts - 1)))
            guard at <= seconds else { return attempts }
            attempts += 1
        }
    }

    /// The gaps between attempts: each at least the pause the failure before it set (a little less,
    /// for the time between the failure and the attempt's own record).
    private func pausesHeld(_ attempts: [Date], pause: (Int) -> TimeInterval) -> Bool {
        guard attempts.count > 1 else { return true }
        return (1 ..< attempts.count).allSatisfy { attempts[$0].timeIntervalSince(attempts[$0 - 1]) >= pause($0) - 0.05 }
    }

    @Test func aPlaybackFloodStartsTheOutputOnceAndQueuesOneBlockAtATime() {
        let outputs = FakeOutputs()
        let sink = playback(outputs)
        for _ in 0 ..< Self.toggles {
            sink.playbackStarted()
            sink.playbackStopped()
        }
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(outputs.all.count == 1) // started once; the stops only set the idle stop again
        #expect(outputs.all[0].isRunning && outputs.all[0].stopCount == 0)
        let statistics = sink.queueStatistics
        #expect(statistics.mostAtOnce <= 2) // one running, one queued
        #expect(statistics.queued <= 2 * Self.toggles + 1)
    }

    /// The stops of a flood set one idle stop again and again: the last one stops the output.
    @Test func aPlaybackFloodEndingInAStopStopsTheOutputAfterTheIdleTime() {
        let outputs = FakeOutputs()
        let sink = playback(outputs, idleStop: 0.3)
        sink.playbackStarted()
        sink.waitForQueue()
        for _ in 0 ..< 1000 {
            sink.playbackStopped()
            sink.playbackStarted()
        }
        sink.playbackStopped()
        #expect(eventually(within: 5) { outputs.all.allSatisfy { !$0.isRunning } })
        #expect(sink.queueStatistics.mostAtOnce <= 2)
    }

    /// A start right after a stop keeps the output: an earlier stop's idle time doesn't stop it.
    @Test func aStartAfterAStopKeepsTheOutputPastTheIdleTime() throws {
        let outputs = FakeOutputs()
        let sink = playback(outputs, idleStop: 1)
        sink.playbackStarted()
        sink.waitForQueue()
        sink.playbackStopped()
        sink.waitForQueue()
        sink.playbackStarted()
        sink.waitForQueue()
        Thread.sleep(forTimeInterval: 1.5)
        sink.waitForQueue()
        let output = try #require(outputs.all.first)
        #expect(outputs.all.count == 1 && output.isRunning && output.stopCount == 0)
    }

    /// An output that fails to start is tried after a growing pause, also when the stream starts again
    /// and again: a start used to try at once.
    @Test func aFailingOutputKeepsItsPauseAcrossStreamStarts() {
        let outputs = FakeOutputs()
        outputs.fail = true
        let sink = playback(outputs)
        let began = Date()
        for _ in 0 ..< Self.toggles {
            sink.playbackStarted()
            sink.playbackStopped()
        }
        sink.playbackStarted()
        sink.waitForQueue()
        let elapsed = Date().timeIntervalSince(began)
        let attempts = outputs.attempts
        #expect(attempts.count >= 1 && attempts.count <= attemptsAllowed(in: elapsed))
        #expect(pausesHeld(attempts) { 0.5 * pow(2, Double($0 - 1)) })
        #expect(sink.queueStatistics.mostAtOnce <= 2)
    }

    /// The flood the review found: a guest toggling its microphone. The microphone opens a quarter of
    /// a second after its last opening at the soonest, and the queue holds one block at a time. The
    /// flood ends with the guest recording: the microphone opens at its next request.
    @Test func aMicrophoneFloodOpensItAQuarterSecondApartAtMost() {
        let inputs = FakeInputs()
        let source = capture(inputs)
        let began = Date()
        for _ in 0 ..< Self.toggles {
            source.captureStarted()
            source.captureStopped()
        }
        source.waitForQueue()
        let elapsed = Date().timeIntervalSince(began)
        #expect(!source.isOpen)
        let opened = inputs.attempts
        #expect(opened.count <= 2 + Int(elapsed / CoreAudioCapture.openSpacing))
        #expect(pausesHeld(opened) { _ in CoreAudioCapture.openSpacing })
        let statistics = source.queueStatistics
        #expect(statistics.mostAtOnce <= 2)
        #expect(statistics.queued <= 2 * Self.toggles)
        // The guest records after all: its requests open the microphone.
        source.captureStarted()
        let open = eventually {
            _ = source.captureAudio(byteCount: 192)
            return source.isOpen
        }
        #expect(open)
        #expect(pausesHeld(inputs.attempts) { _ in CoreAudioCapture.openSpacing })
    }

    /// A microphone that fails to open keeps its pause when the guest starts recording again: each
    /// start used to reset it and try at once.
    @Test func aFailingMicrophoneKeepsItsPauseAcrossStarts() {
        let inputs = FakeInputs()
        inputs.fail = true
        let source = capture(inputs)
        let began = Date()
        for _ in 0 ..< Self.toggles {
            source.captureStarted()
            _ = source.captureAudio(byteCount: 192)
            source.captureStopped()
        }
        source.captureStarted()
        source.waitForQueue()
        let elapsed = Date().timeIntervalSince(began)
        let attempts = inputs.attempts
        #expect(attempts.count >= 1 && attempts.count <= attemptsAllowed(in: elapsed))
        #expect(pausesHeld(attempts) { 0.5 * pow(2, Double($0 - 1)) })
        #expect(!source.isOpen)
    }

    /// A tap that can't be installed (a format that isn't the device's, which on macOS 27 throws where
    /// the older call raised an exception) is a failed open: tried again after the pause, at the host's
    /// requests, and open once it can be.
    @Test func aTapThatCantBeInstalledIsAFailedOpenTriedAgainLater() {
        let inputs = FakeInputs()
        inputs.failToBuild = true
        let source = capture(inputs)
        source.captureStarted()
        source.waitForQueue()
        #expect(!source.isOpen && inputs.attempts.count == 1 && inputs.all.isEmpty)
        // Requests within the first pause (0.5 s from the failure) try nothing.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.2 {
            _ = source.captureAudio(byteCount: 192)
            Thread.sleep(forTimeInterval: 0.01)
        }
        source.waitForQueue()
        #expect(inputs.attempts.count <= attemptsAllowed(in: Date().timeIntervalSince(start) + 0.05))
        inputs.failToBuild = false
        let open = eventually(within: 5) {
            _ = source.captureAudio(byteCount: 192)
            return source.isOpen
        }
        #expect(open && inputs.all.count == 1)
    }

    /// The same for an output whose connection fails (macOS 27 throws there too).
    @Test func anOutputThatCantBeBuiltIsAFailedStartTriedAgainLater() {
        let outputs = FakeOutputs()
        outputs.failToBuild = true
        let sink = playback(outputs)
        sink.playbackStarted()
        sink.waitForQueue()
        #expect(outputs.attempts.count == 1 && outputs.all.isEmpty)
        outputs.failToBuild = false
        let started = eventually(within: 5) {
            sink.play(Data(count: 1920))
            return outputs.all.first?.isRunning ?? false
        }
        #expect(started && outputs.all.count == 1)
    }

    /// What EngineCaptureInput won't tap: a tap whose rate isn't the device's raised an exception.
    @Test func aTapNeedsAFormatAtTheDevicesRate() {
        #expect(EngineCaptureInput.tapProblem(tap: (48000, 2), hardware: (48000, 2)) == nil)
        #expect(EngineCaptureInput.tapProblem(tap: (48000, 1), hardware: (48000, 1)) == nil)
        #expect(EngineCaptureInput.tapProblem(tap: (48000, 2), hardware: (48000, 1)) == nil) // channels can differ
        #expect(EngineCaptureInput.tapProblem(tap: (0, 0), hardware: (0, 0)) != nil) // no input device
        #expect(EngineCaptureInput.tapProblem(tap: (48000, 2), hardware: (0, 0)) != nil)
        #expect(EngineCaptureInput.tapProblem(tap: (48000, 0), hardware: (48000, 2)) != nil)
        #expect(EngineCaptureInput.tapProblem(tap: (48000, 1), hardware: (16000, 1)) != nil) // an AirPods switch
        #expect(EngineCaptureInput.tapProblem(tap: (44100, 2), hardware: (48000, 2)) != nil)
    }
}
