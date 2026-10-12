import SpotCoreKit
import SwiftUI

/// PBI-502: the now-playing bar's device picker. Choosing a device moves playback there.
struct DevicesButton: View {
    let player: PlayerModel
    @State private var showing = false

    private var playingElsewhere: ConnectDevice? {
        player.devices.first { $0.isActive && !$0.isThisDevice }
    }

    var body: some View {
        Button("Devices", systemImage: "hifispeaker.2") { showing.toggle() }
            .buttonStyle(TransportButtonStyle(on: playingElsewhere != nil))
            .accessibilityValue(playingElsewhere.map { "Playing on \($0.name)" } ?? "")
            .help("Devices")
            .popover(isPresented: $showing, arrowEdge: .top) {
                DeviceList(player: player)
            }
    }
}

private struct DeviceList: View {
    let player: PlayerModel
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text("Devices")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Theme.s2)
                .padding(.bottom, Theme.s1)
            if player.devices.isEmpty {
                Text("No devices found.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s2)
            }
            ForEach(player.devices, id: \.id) { device in
                // The active row stays enabled so VoiceOver reads it as selected; choosing it does nothing.
                Button { player.transfer(to: device.id) } label: {
                    DeviceRow(device: device)
                }
                .buttonStyle(.plain)
                .focused($focused, equals: device.id)
                .accessibilityAddTraits(device.isActive ? .isSelected : [])
                .disabled(!player.canTransfer)
            }
            if player.transferFailed {
                Text("Couldn't move playback. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Theme.s2)
            }
        }
        .padding(Theme.s3)
        .frame(width: 280)
        .onAppear {
            focused = (player.devices.first(where: \.isActive) ?? player.devices.first)?.id
        }
    }
}

private struct DeviceRow: View {
    let device: ConnectDevice

    private var name: String {
        device.isThisDevice ? String(localized: "This Mac") : device.name
    }

    private var volumePercent: Int {
        Int((Double(device.volume) / Double(UInt16.max) * 100).rounded())
    }

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 16))
                .frame(width: 22)
                .foregroundStyle(device.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .lineLimit(1)
                    .foregroundStyle(device.isActive ? Color.accentColor : .primary)
                if device.isActive {
                    Text("Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.s2)
            Label("\(volumePercent)%", systemImage: "speaker.wave.2")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if device.isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, Theme.s2)
        .padding(.vertical, Theme.s2)
        .contentShape(.rect(cornerRadius: Theme.smallRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(device.isActive ? "Playing, volume \(volumePercent)%" : "Volume \(volumePercent)%")
    }
}

private extension DeviceKind {
    var symbol: String {
        switch self {
        case .computer: "laptopcomputer"
        case .smartphone: "iphone"
        case .tablet: "ipad"
        case .speaker: "hifispeaker"
        case .tv: "tv"
        case .car: "car"
        case .gameConsole: "gamecontroller"
        case .watch: "applewatch"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}
