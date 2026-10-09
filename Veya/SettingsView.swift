import SpotCoreKit
import SwiftUI

/// The Settings window (⌘,). Playback changes reach the live player through
/// the shared `PlaybackSettings`; nothing here needs a relaunch.
struct SettingsView: View {
    let session: SessionModel
    let settings: PlaybackSettings
    let signOut: () -> Void

    var body: some View {
        TabView {
            NoSettingsYet()
                .tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettingsTab(settings: settings)
                .tabItem { Label("Playback", systemImage: "play.circle") }
            StorageSettingsTab(session: session, settings: settings)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            NoSettingsYet()
                .tabItem { Label("Connect", systemImage: "hifispeaker.2") }
            AccountSettingsTab(session: session, signOut: signOut)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 460, height: 320)
    }
}

private struct NoSettingsYet: View {
    var body: some View {
        Text("No settings yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct PlaybackSettingsTab: View {
    @Bindable var settings: PlaybackSettings
    @State private var devices = OutputDevices()

    private static let speeds: [Float] = [0.8, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Form {
            Picker("Streaming quality", selection: $settings.bitrate) {
                Text("Low (96 kbps)").tag(Bitrate.kbps96)
                Text("Normal (160 kbps)").tag(Bitrate.kbps160)
                Text("High (320 kbps)").tag(Bitrate.kbps320)
            }
            .accessibilityIdentifier("streamingQuality")
            Toggle("Normalize volume", isOn: $settings.normalises)
            Picker("Loudness", selection: $settings.loudness) {
                Text("Quiet").tag(LoudnessPreset.quiet)
                Text("Normal").tag(LoudnessPreset.normal)
                Text("Loud").tag(LoudnessPreset.loud)
            }
            .disabled(!settings.normalises)
            Picker("Podcast speed", selection: $settings.episodeSpeed) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text("\(speed.formatted())×").tag(speed)
                }
            }
            Picker("Output device", selection: $settings.outputDeviceUID) {
                Text("System Default").tag(String?.none)
                ForEach(devices.list) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StorageSettingsTab: View {
    let session: SessionModel
    let settings: PlaybackSettings
    @State private var confirmingReset = false
    @State private var resetDone = false
    @State private var failure: LocalizedStringKey?

    private static let limits: [UInt64] = [512 << 20, 1 << 30, 2 << 30, 5 << 30, 10 << 30]

    private var limitChoices: [UInt64] {
        Self.limits.contains(settings.audioCacheLimitBytes)
            ? Self.limits
            : (Self.limits + [settings.audioCacheLimitBytes]).sorted()
    }

    var body: some View {
        Form {
            Section {
                Picker("Audio cache size", selection: Binding(get: { settings.audioCacheLimitBytes }, set: setLimit)) {
                    ForEach(limitChoices, id: \.self) { bytes in
                        Text(Int64(bytes).formatted(.byteCount(style: .memory))).tag(bytes)
                    }
                }
            } footer: {
                Text("Changing the size reconnects to Spotify, which stops the current track.")
            }
            Section {
                LabeledContent("Library and metadata") {
                    Button("Reset Metadata Cache…") { confirmingReset = true }
                }
                if resetDone {
                    Text("Metadata cache cleared.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Veya fetches your library and track details again from Spotify.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the metadata cache?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text("Veya fetches your library and track details again from Spotify.")
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// The live cache changes first, so a failure leaves the saved size matching it.
    private func setLimit(_ bytes: UInt64) {
        do {
            try session.setAudioCacheLimit(bytes: bytes)
            settings.audioCacheLimitBytes = bytes
        } catch {
            failure = "Couldn't change the audio cache size."
        }
    }

    private func reset() {
        do {
            try session.resetMetadataCache()
            resetDone = true
        } catch {
            failure = "Couldn't reset the metadata cache."
        }
    }
}

private struct AccountSettingsTab: View {
    let session: SessionModel
    let signOut: () -> Void

    private var signedIn: Bool {
        session.state != .signedOut
    }

    var body: some View {
        Form {
            LabeledContent("Spotify") {
                Text(signedIn ? "Signed in" : "Not signed in")
            }
            Button("Sign Out", action: signOut)
                .disabled(!signedIn)
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsTab: View {
    @AppStorage(Diagnostics.levelKey) private var levelName = Diagnostics.defaultLevel.storedName

    var body: some View {
        Form {
            Picker("Log level", selection: $levelName) {
                ForEach(LogLevel.choices, id: \.storedName) { level in
                    Text(level.title).tag(level.storedName)
                }
            }
            .accessibilityIdentifier("logLevel")
            .onChange(of: levelName) { _, name in
                Diagnostics.startLogging(level: LogLevel(storedName: name) ?? Diagnostics.defaultLevel)
            }
        }
        .formStyle(.grouped)
    }
}

private extension LogLevel {
    var title: LocalizedStringKey {
        switch self {
        case .error: "Errors"
        case .warn: "Warnings"
        case .info: "Info"
        case .debug: "Debug"
        }
    }
}
