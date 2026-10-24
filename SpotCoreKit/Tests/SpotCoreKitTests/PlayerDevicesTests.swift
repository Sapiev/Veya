import Foundation
@testable import SpotCoreKit
import Testing

/// PBI-502: the device picker's list and transfer.
@MainActor
struct PlayerDevicesTests {
    private let defaults = UserDefaults(suiteName: "PlayerDevicesTests-\(UUID().uuidString)")!

    private func device(_ id: String, active: Bool = false, this: Bool = false) -> ConnectDevice {
        ConnectDevice(id: id, name: id, kind: .speaker, volume: 100, isActive: active, isThisDevice: this)
    }

    @Test func clusterUpdatesReplaceTheDeviceList() {
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([]),
            settings: PlaybackSettings(defaults: defaults)
        )
        #expect(player.devices.isEmpty)

        player.apply(.devicesChanged(devices: [device("mac", this: true), device("phone", active: true)]))
        #expect(player.devices.map(\.id) == ["mac", "phone"])

        player.apply(.devicesChanged(devices: [device("mac", active: true, this: true)]))
        #expect(player.devices.map(\.id) == ["mac"])
        #expect(player.devices.first?.isActive == true)
    }

    private func connected(_ devices: ConnectStarts) async -> PlayerModel {
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([]),
            settings: PlaybackSettings(defaults: defaults), startConnect: devices.start, clock: Date.init, log: { _, _ in }
        )
        await player.connectStart?.value
        player.apply(.devicesChanged(devices: [device("mac", this: true), device("phone", active: true), device("tv")]))
        return player
    }

    @Test func choosingADeviceTransfersThroughConnect() async {
        let devices = ConnectStarts()
        let player = await connected(devices)
        #expect(player.hasConnect)

        await player.transfer(to: "tv")?.value

        #expect(devices.made.map(\.transfers) == [["tv"]])
        #expect(!player.transferFailed)
        #expect(player.canTransfer)
    }

    @Test func oneTransferRunsAtATime() async {
        let devices = ConnectStarts()
        let player = await connected(devices)

        let first = player.transfer(to: "tv")
        #expect(!player.canTransfer, "the rows are disabled while it runs")
        #expect(player.transfer(to: "mac") == nil)
        await first?.value

        #expect(devices.made.map(\.transfers) == [["tv"]])
    }

    @Test func choosingTheActiveDeviceDoesNothing() async {
        let devices = ConnectStarts()
        let player = await connected(devices)
        #expect(player.transfer(to: "phone") == nil)
        #expect(devices.made.map(\.transfers) == [[]])
    }

    @Test func aFailedTransferIsShownUntilTheNextOne() async {
        let devices = ConnectStarts()
        devices.failTransfers = true
        let player = await connected(devices)

        await player.transfer(to: "tv")?.value
        #expect(player.transferFailed)

        let retry = player.transfer(to: "tv")
        #expect(!player.transferFailed, "a new attempt clears the error")
        await retry?.value
    }

    /// PBI-503: the label follows Remote mode, not the device list's active flag.
    @Test func playingOnFollowsRemoteModeNotTheActiveDevice() {
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([]),
            settings: PlaybackSettings(defaults: defaults)
        )
        player.apply(.devicesChanged(devices: [device("mac", this: true), device("phone", active: true)]))
        #expect(player.playingOn == nil, "a paused active phone without Remote mode shows no label")

        player.apply(.remoteChanged(deviceName: "Pixel", volume: 6554))
        #expect(player.playingOn == "Pixel")

        player.apply(.remoteChanged(deviceName: nil, volume: nil))
        #expect(player.playingOn == nil, "a local load left Remote mode")
    }

    /// PBI-503: the remote's volume is shown and sent to it, never saved as the app's.
    @Test func remoteVolumeIsShownAndSentButNeverSaved() async {
        let fake = FakePlayer()
        let settings = PlaybackSettings(defaults: defaults)
        settings.volume = 0.8
        let player = PlayerModel(player: fake, engine: nil, metadata: StubMetadata([]), settings: settings)

        player.apply(.remoteChanged(deviceName: "Pixel", volume: 0))
        #expect(player.volume == 0)
        player.volume = 1
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(fake.recorded == ["remote volume 65535"], "nothing reaches the local mixer")
        #expect(settings.volume == 0.8)

        player.apply(.remoteChanged(deviceName: nil, volume: nil))
        #expect(player.volume == 0.8, "back in Local mode the app's volume shows again")
    }

    /// PBI-503: sign-out and quit stop only this Mac, never the device it controls.
    @Test func teardownStopsOnlyLocalPlayback() {
        let fake = FakePlayer()
        let player = PlayerModel(
            player: fake, engine: nil, metadata: StubMetadata([]), settings: PlaybackSettings(defaults: defaults)
        )
        player.teardown()
        #expect(fake.recorded == ["stopLocal"])
    }

    @Test func withoutConnectThereIsNothingToTransferTo() {
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([]),
            settings: PlaybackSettings(defaults: defaults)
        )
        #expect(!player.hasConnect)
        #expect(!player.canTransfer)
        #expect(player.transfer(to: "phone") == nil)
    }
}
