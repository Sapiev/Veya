import CoreAudio
import Foundation
@testable import SpotCoreKit
import Testing

/// Uses a private aggregate of the default output as a device that can be
/// plugged and unplugged, so these need a Mac with an output device.
@MainActor
struct OutputDevicesTests {
    @Test func listUpdatesAsDevicesAppearAndDisappear() async throws {
        let devices = OutputDevices()
        let device = try TestDevice()

        try await until { devices.list.contains { $0.uid == device.uid } }
        device.unplug()
        try await until { !devices.list.contains { $0.uid == device.uid } }
    }

    @Test func engineFollowsChosenDeviceAndFallsBackToDefaultWhenMissing() async throws {
        let engine = try AudioEngine(output: AudioOutput())
        let device = try TestDevice()

        engine.outputDeviceUID = device.uid
        #expect(engine.outputDevice == device.id)

        device.unplug()
        try await until { engine.outputDevice == SystemAudio.defaultOutputDevice }
    }

    @Test func missingChosenDeviceUsesSystemDefault() throws {
        let engine = try AudioEngine(output: AudioOutput())

        engine.outputDeviceUID = "no-such-device"

        #expect(engine.outputDevice == SystemAudio.defaultOutputDevice)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

private final class TestDevice {
    let uid = "veya.test.\(UUID().uuidString)"
    private(set) var id = AudioDeviceID(kAudioObjectUnknown)

    init() throws {
        let defaultOutput = try #require(SystemAudio.outputDevices.first {
            SystemAudio.outputDevice(uid: $0.uid) == SystemAudio.defaultOutputDevice
        })
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "Veya Test Output",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: defaultOutput.uid]],
        ]
        try #require(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr)
    }

    func unplug() {
        guard id != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(id)
        id = AudioDeviceID(kAudioObjectUnknown)
    }

    deinit { unplug() }
}
