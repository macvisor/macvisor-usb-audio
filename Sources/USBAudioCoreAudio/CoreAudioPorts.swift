@preconcurrency import AVFoundation
import Foundation
import USBAudioDevice

/// Plays the device's playback stream on the Mac's default output device.
///
/// The output engine starts when the host starts streaming and stops `idleStop` after it stops, so a
/// short system sound right after another doesn't pay for an engine start. `bufferedSeconds` reports
/// how much audio waits to be played; the server steers its pacer with it, so the guest follows the
/// output device's clock.
public final class CoreAudioPlayback: PlaybackSink, @unchecked Sendable {
    public var log: (@Sendable (String) -> Void)?

    private let ring = StereoRing(capacitySeconds: 0.5)
    private let idleStop: TimeInterval
    private let queue = DispatchQueue(label: "usb-audio.coreaudio.playback")
    private var engine: AVAudioEngine?
    private var stopWork: DispatchWorkItem?

    public init(idleStop: TimeInterval = 30) {
        self.idleStop = idleStop
    }

    public var bufferedSeconds: Double? {
        Double(ring.bufferedFrames) / Double(UAC1AudioDevice.sampleRate)
    }

    public func playbackStarted() {
        queue.async { self.startEngine() }
    }

    public func play(_ pcm: Data) {
        ring.write(int16: pcm)
        queue.async { if self.engine == nil { self.startEngine() } }
    }

    public func playbackStopped() {
        queue.async { [self] in
            stopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopEngine() }
            stopWork = work
            queue.asyncAfter(deadline: .now() + idleStop, execute: work)
        }
    }

    private func startEngine() {
        stopWork?.cancel()
        stopWork = nil
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(UAC1AudioDevice.sampleRate), channels: 2)!
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = ring.read(frames: Int(frameCount), left: l, right: r)
            for i in n ..< Int(frameCount) { l[i] = 0; r[i] = 0 } // underrun: silence
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
            log?("playback: output engine started (\(engine.outputNode.outputFormat(forBus: 0)))")
        } catch {
            log?("playback: output engine failed to start: \(error)")
        }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        ring.clear()
        log?("playback: output engine stopped")
    }
}

/// Feeds the Mac's default input device to the device's microphone stream, **only while the host
/// records** (the microphone opens on `captureStarted` and closes on `captureStopped`), so macOS's
/// microphone indicator and its permission prompt mean what they say.
public final class CoreAudioCapture: CaptureSource, @unchecked Sendable {
    public var log: (@Sendable (String) -> Void)?

    private let ring = StereoRing(capacitySeconds: 0.5)
    private let queue = DispatchQueue(label: "usb-audio.coreaudio.capture")
    private var engine: AVAudioEngine?
    private let targetFrames = UAC1AudioDevice.sampleRate * 40 / 1000
    private let trimFrames = UAC1AudioDevice.sampleRate * 150 / 1000

    public init() {}

    public func captureStarted() {
        queue.async { self.startEngine() }
    }

    public func captureStopped() {
        queue.async {
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine?.stop()
            self.engine = nil
            self.ring.clear()
            self.log?("capture: microphone closed")
        }
    }

    public func captureAudio(byteCount: Int) -> Data {
        ring.readInt16(frames: byteCount / UAC1AudioDevice.bytesPerFrame, trimAboveFrames: trimFrames, keepFrames: targetFrames).0
    }

    private func startEngine() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(UAC1AudioDevice.sampleRate), channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            log?("capture: no usable input device (\(inputFormat))")
            return
        }
        if inputFormat.channelCount == 1 { converter.channelMap = [0, 0] } // mono microphone to both channels
        let ring = self.ring
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var fed = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let data = out.floatChannelData?[0] {
                ring.write(float: UnsafeBufferPointer(start: data, count: Int(out.frameLength) * 2))
            }
        }
        do {
            try engine.start()
            self.engine = engine
            log?("capture: microphone open (\(inputFormat))")
        } catch {
            input.removeTap(onBus: 0)
            log?("capture: microphone failed to start: \(error)")
        }
    }
}
