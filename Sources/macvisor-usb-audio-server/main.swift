import Darwin
import Foundation
import USBAudioCoreAudio
import USBAudioDevice

/// The whole tool, outside the main actor: `dispatchMain()` services the main queue on a worker
/// thread, so main-actor closures would be called off the main thread.
func runServer() throws -> Never {
    let usage = """
    usage: macvisor-usb-audio-server [options]

    Serves a USB Audio Class device over USB/IP. Attach it from a USB/IP client, e.g. usbip-win2 on
    Windows:  usbip attach -r <this Mac's address> -b 1-1

      --listen <host:port>   address to listen on (default 127.0.0.1:3240; the device is for one client)
      --microphone           microphone: the Mac's (asks for it while the client records)
      --tone                 microphone: a 1 kHz tone
      --silent               microphone: silence (the default)
      --loopback             the guest's playback comes back as its microphone (latency tests)
      --record <file.wav>    write the guest's playback to a WAV file instead of playing it
      --product-id <hex>     USB product ID (default 4112, MacVisor USB Audio's under VID 1209;
                             0001 is pid.codes' testing PID)
      --verbose              log stream statistics every 10 seconds
    """

    var listenAddress = "127.0.0.1:3240"
    // Silence unless asked: whoever reaches the server would hear the Mac's microphone.
    var microphone = "silent"
    var loopback = false
    var recordPath: String?
    var productID: UInt16 = 0x4112
    var verbose = false

    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--listen": listenAddress = args.next() ?? listenAddress
        case "--microphone": microphone = "mac"
        case "--tone": microphone = "tone"
        case "--silent": microphone = "silent"
        case "--loopback": loopback = true
        case "--record": recordPath = args.next()
        case "--product-id": productID = UInt16(args.next() ?? "", radix: 16) ?? productID
        case "--verbose": verbose = true
        case "-h", "--help": print(usage); exit(0)
        default: FileHandle.standardError.write(Data("unknown option \(arg)\n\n\(usage)\n".utf8)); exit(2)
        }
    }

    @Sendable func log(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        FileHandle.standardError.write(Data("[\(t)] \(s)\n".utf8))
    }

    // Where the audio goes and comes from.
    let playback: PlaybackSink
    let capture: CaptureSource
    var wavSink: WAVFileSink?
    if loopback {
        let port = LoopbackPort()
        playback = port
        capture = port
    } else {
        if let recordPath {
            let sink = try WAVFileSink(url: URL(fileURLWithPath: recordPath))
            wavSink = sink
            playback = sink
        } else {
            let p = CoreAudioPlayback()
            p.log = log
            playback = p
        }
        switch microphone {
        case "tone": capture = ToneSource()
        case "mac":
            let c = CoreAudioCapture()
            c.log = log
            capture = c
        default: capture = SilentSource()
        }
    }

    let device = UAC1AudioDevice(identity: DeviceIdentity(productID: productID))
    let server = USBAudioServer(device: device, playback: playback, capture: capture)
    server.log = log
    // A connection that imports nothing in 10 s is closed, and at most `maxConnections` are served at
    // once (one imports the device; the rest are a client re-attaching): nobody holds the server with
    // idle connections or a thread each.
    server.importTimeout = 10
    let maxConnections = 4

    // A plain TCP listener; each connection is served on a thread of its own.
    let parts = listenAddress.split(separator: ":")
    guard parts.count == 2, let port = UInt16(parts[1]) else { print(usage); exit(2) }
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, String(parts[0]), &address.sin_addr) == 1 else { log("bad address \(parts[0])"); exit(2) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener, 8) == 0 else {
        log("cannot listen on \(listenAddress): \(String(cString: strerror(errno)))")
        exit(1)
    }
    log("serving \(device.identity.product) (\(String(format: "%04x:%04x", device.identity.vendorID, device.identity.productID))) as bus ID \(server.busID) on \(listenAddress)")
    if !parts[0].hasPrefix("127.") {
        log("warning: \(parts[0]) isn't a loopback address: anyone who can reach it can play through this Mac\(microphone == "mac" ? " and hear its microphone" : "")")
    }

    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        wavSink?.close()
        log("stopped")
        exit(0)
    }
    interrupt.resume()

    let statisticsTimer = DispatchSource.makeTimerSource(queue: .main)
    if verbose {
        statisticsTimer.schedule(deadline: .now() + 10, repeating: 10)
        statisticsTimer.setEventHandler {
            guard let s = server.statistics else { return }
            log("playback: \(s.playback.completedURBs) URBs, \(s.playback.lateURBs) late; capture: \(s.capture.completedURBs) URBs, \(s.capture.lateURBs) late")
        }
        statisticsTimer.resume()
    }

    let connections = NSLock()
    nonisolated(unsafe) var served = 0
    Thread.detachNewThread {
        // After a failed accept() (out of descriptors, say), a growing pause, not a busy loop.
        var pause: TimeInterval = 0
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if pause == 0 { log("accept failed: \(String(cString: strerror(errno))); trying again, less and less often") }
                pause = min(max(pause * 2, 0.05), 2)
                Thread.sleep(forTimeInterval: pause)
                continue
            }
            pause = 0
            let admitted: Bool = connections.withLock {
                guard served < maxConnections else { return false }
                served += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            Thread.detachNewThread {
                server.serve(FileDescriptorStream(fileDescriptor: client))
                connections.withLock { served -= 1 }
            }
        }
    }
    dispatchMain()
}

try runServer()
