// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macvisor-usb-audio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USBAudioDevice", targets: ["USBAudioDevice"]),
        .library(name: "USBAudioCoreAudio", targets: ["USBAudioCoreAudio"]),
        .executable(name: "macvisor-usb-audio-server", targets: ["macvisor-usb-audio-server"]),
    ],
    targets: [
        // The USB/IP protocol, the USB Audio Class 1 device and the isochronous pacing. No audio framework.
        .target(name: "USBAudioDevice"),
        // Plays the guest's audio on the Mac and feeds the Mac's microphone to it (AVAudioEngine).
        .target(name: "USBAudioCoreAudio", dependencies: ["USBAudioDevice"]),
        // A stand-alone USB/IP server for trying the device with a USB/IP client such as usbip-win2.
        .executableTarget(name: "macvisor-usb-audio-server", dependencies: ["USBAudioDevice", "USBAudioCoreAudio"]),
        .testTarget(name: "USBAudioDeviceTests", dependencies: ["USBAudioDevice"]),
        .testTarget(name: "USBAudioCoreAudioTests", dependencies: ["USBAudioCoreAudio"]),
    ]
)
