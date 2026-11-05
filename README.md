# MacVisor USB Audio

A software-defined **USB Audio Class 1.0 device**, a stereo speaker and a stereo microphone at
48 kHz / 16-bit, served over **USB/IP**. MacVisor uses it to give Windows on Arm virtual machines sound
through **Windows' own USB audio driver**, with no third-party or test-signed audio driver in the guest.

This repository is the device side, in Swift:
- the USB/IP server;
- the USB Audio Class device (descriptors, control requests, volume and mute);
- isochronous streaming, paced in real time;
- CoreAudio adapters that play the guest's audio on the Mac and feed the Mac's microphone back.

It also has a small command-line server for trying the device with any USB/IP client.

## Why

Windows on Arm loads only Microsoft-signed kernel drivers. Apple's Virtualization.framework gives a VM
virtio sound, and no Microsoft-signed virtio sound driver exists, so a Windows VM is silent unless it
runs in Test Mode.

Windows does ship a signed driver for USB audio (`usbaudio.sys`, `usbaudio2.sys`). Present a USB audio
device and Windows drives it. This device is presented through a USB/IP client in the guest, such as
[usbip-win2](https://github.com/vadimgrn/usbip-win2), whose ARM64 drivers are Microsoft
attestation-signed. So the VM keeps signature enforcement on, with no Test Mode.

```
Windows app → audio engine → usbaudio.sys (Microsoft)
  → usbip-win2 virtual host controller (Microsoft-attested) → TCP or a VM socket
  → USBAudioServer (this package) → UAC1AudioDevice → CoreAudio on the Mac
```

## The device

| | |
|---|---|
| USB | full speed, USB 1.1, Audio Class 1.0, three interfaces |
| Speaker | isochronous OUT, adaptive; 48 kHz, 2 channels, 16-bit; 1 ms packets |
| Microphone | isochronous IN, synchronous; 48 kHz, 2 channels, 16-bit |
| Controls | mute and volume per direction, −60 to 0 dB in 1 dB steps, applied by the device |
| Strings | "MacVisor" / "MacVisor Audio" (configurable); Windows shows *Speakers (MacVisor Audio)* |

**Timing.**
- `EndpointPacer` completes each endpoint's URBs **in submission order** on a **fixed timeline**.
- Playback URBs complete 40 ms early, so the guest keeps that much audio queued, which absorbs jitter.
- A URB that arrives late completes at once, and the stream's long-run rate stays exact.
- The playback timeline is steered to hold the output buffer at those 40 ms, so the guest follows the
  Mac's audio clock.
- `CoreAudioPlayback` holds what the guest keeps queued: an output engine starts with the newest 40 ms
  (it can take half a second to start), the buffer never holds more than 100 ms, and what a stall
  leaves behind once the late URBs catch up is dropped.
- Windows keeps only about two 10 ms URBs in flight, which is why these rules matter.

**Privacy.** `CoreAudioCapture` opens the Mac's microphone only while the guest records (the capture
interface's alternate setting 1), so macOS's microphone indicator shows exactly when the guest is
listening. A guest that stops asking for audio for a second (a paused VM) has it closed until it asks
again.

**One session per device.** A second import is refused while a client has the device, so a client
can't present it to the guest twice. After a VM is restored, its old connections are dead without
anyone noticing: call `disconnectAll()` first.

**Bounded by the device, not the client.** Whatever a client sends, the server holds a few seconds of
audio at most:
- transfers longer than the device ever needs end the session;
- isochronous packets longer than twice wMaxPacketSize, or summing past their buffer, stall;
- each endpoint queues at most 64 URBs, reaching at most 2 s ahead, and stalls the rest.

With `importTimeout` set, a connection that imports nothing within it is closed, so idle connections
can't hold a server's places. `CoreAudioPlayback` and `CoreAudioCapture` follow a change of the Mac's
output or input device, and stop their engines when they are freed.

## Try it

```sh
swift run macvisor-usb-audio-server --listen 127.0.0.1:3240
```

The server plays what the guest plays on your default output. The guest's microphone is silent
unless you ask: whoever reaches the server would hear it.
- `--microphone` gives the guest your default microphone while it records.
- `--tone` sends a test tone as the microphone instead.
- `--loopback` sends the guest's own playback back as its microphone (latency tests).
- `--record file.wav` writes playback to a file.

It serves four connections at once at most, closes one that imports nothing within 10 seconds, and
warns when it listens on an address other than loopback.

In a Windows guest with usbip-win2 installed, reach the server on its address. An SSH reverse tunnel
(`ssh -R 127.0.0.1:3240:127.0.0.1:3240 <guest>`) avoids opening a port on the Mac. Then:

```bat
usbip attach -r 127.0.0.1 -b 1-1
```

"Speakers (MacVisor Audio)" and "Microphone (MacVisor Audio)" appear, bound to Microsoft's driver.

## Use it as a library

```swift
import USBAudioDevice
import USBAudioCoreAudio

let server = USBAudioServer(playback: CoreAudioPlayback(), capture: CoreAudioCapture())
server.importTimeout = 10
// For each connection, e.g. a VZVirtioSocketConnection accepted by a VZVirtioSocketListener. The
// stream gets a duplicate of the descriptor, which it closes itself once nothing uses it.
Thread.detachNewThread {
    server.serve(FileDescriptorStream(fileDescriptor: dup(connection.fileDescriptor)))
}
```

`PlaybackSink` and `CaptureSource` are small protocols, if you'd rather route audio elsewhere.
`RecordingSink`, `ToneSource`, `LoopbackPort` and `WAVFileSink` are included.

## Measured

On Windows 11 26H2 ARM64, in a VM on Apple Virtualization.framework, with usbip-win2 0.9.8.1:
- **Playback:** bit-exact. A 10-minute run had no glitches, and 600.020 s of audio took 599.981 s of
  wall time.
- **Round trip, guest app to guest app through a loopback:** 52–64 ms, of which ~30 ms was the
  loopback buffer.
- **Microphone:** works. Windows adds its Voice Clarity processing to new microphones, which removes
  steady tones by design.

## USB IDs

- **Default:** 1209:4112, MacVisor USB Audio's own IDs: vendor 0x1209 is [pid.codes'](https://pid.codes/),
  product 0x4112 is this device's ([requested](https://github.com/pidcodes/pidcodes.github.com/pull/1354)).
- **A device of your own:** if you change what the device does, give it your own PID with
  `DeviceIdentity(productID:)` (or the server's `--product-id`). pid.codes' testing PID, 1209:0001, is
  for experiments.

## Requirements

macOS 14 or later, Swift 6. A USB/IP client in the guest; it was developed against usbip-win2 on
Windows on Arm.

## Credits

- **The USB/IP protocol:** the Linux kernel's
  [protocol documentation](https://www.kernel.org/doc/html/latest/usb/usbip_protocol.html).
- **[usbip-win2](https://github.com/vadimgrn/usbip-win2)** (BSD-2-Clause): the Windows client. Not
  included here.
- **[Virtual Cables](https://github.com/tarekwasfy01/Virtual-Cables)** (BSD-2-Clause): showed that a
  USB/IP-served USB audio device works with Windows' inbox driver.

## License

MIT; see [LICENSE](LICENSE).
