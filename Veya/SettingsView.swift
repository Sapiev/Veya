import SpotCoreKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The Settings window (⌘,). Playback changes reach the live player through
/// the shared `PlaybackSettings`; nothing here needs a relaunch.
struct SettingsView: View {
    enum Tab: String {
        case general, playback, storage, connect, account, advanced
    }

    /// Written by other windows to open Settings on a given tab.
    static let tabKey = "settingsTab"
    /// Off by default; read by `TrackNotifications` on each track change.
    static let trackNotificationsKey = "notifications.trackChanged"

    let session: SessionModel
    let webAPI: WebAPIConnection
    let settings: PlaybackSettings
    let menuBar: MenuBarSettings
    let crashReports: CrashReports
    let updates: Updates
    let signOut: () -> Void
    @AppStorage(Self.tabKey) private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab(menuBar: menuBar)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            PlaybackSettingsTab(settings: settings)
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(Tab.playback)
            StorageSettingsTab(session: session, settings: settings)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(Tab.storage)
            ConnectSettingsTab(settings: settings)
                .tabItem { Label("Connect", systemImage: "hifispeaker.2") }
                .tag(Tab.connect)
            AccountSettingsTab(session: session, webAPI: webAPI, signOut: signOut)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(Tab.account)
            AdvancedSettingsTab(crashReports: crashReports, updates: updates)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.advanced)
        }
        .frame(width: 460, height: height)
        .background(HostingGroupLabel(label: String(localized: "Settings")))
    }

    private var height: CGFloat {
        switch tab {
        case .account: 520
        case .advanced: 420
        default: 320
        }
    }
}

/// PBI-501: how this Mac appears as a Spotify Connect device.
private struct ConnectSettingsTab: View {
    @Bindable var settings: PlaybackSettings
    /// Committed on Return or when the tab closes, as each change re-registers the device.
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Device name", text: $name)
                .accessibilityLabel("Device name")
                .onSubmit(commitName)
            Toggle(isOn: $settings.zeroconf) {
                Text("Discoverable on the local network")
                Text("Spotify apps on this network can find this Mac. Only your account can play on it.")
            }
            .accessibilityLabel("Discoverable on the local network")
        }
        .formStyle(.grouped)
        .onAppear { name = settings.connectDeviceName }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        if name != settings.connectDeviceName {
            settings.connectDeviceName = name
        }
        name = settings.connectDeviceName
    }
}

/// The menu bar mini-player, and the window colors: from the artwork, a fixed accent, or the accent cycling at a chosen speed.
private struct GeneralSettingsTab: View {
    @AppStorage(ColorSource.key) private var source = ColorSource.artwork
    @AppStorage(ColorSource.accentKey) private var accentHex = RGB.defaultAccent.hex
    @AppStorage(ColorSource.cycleSecondsKey) private var cycleSeconds = ColorSource.defaultCycleSeconds
    @AppStorage(SettingsView.trackNotificationsKey) private var notifiesTrackChanges = false
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @AppStorage(NowPlayingView.panesBackgroundKey) private var panesBackground = true
    @AppStorage(NowPlayingView.showsPanesKey) private var showsPanes = true
    @State private var notificationsDenied = false
    @Bindable var menuBar: MenuBarSettings

    var body: some View {
        Form {
            Section {
                Picker("Text size", selection: $textSize) {
                    Text("Default").tag(TextSize.standard)
                    Text("Large").tag(TextSize.large)
                    Text("Larger").tag(TextSize.larger)
                    Text("Largest").tag(TextSize.largest)
                }
                .accessibilityLabel("Text size")
            }
            Section {
                Toggle("Show mini player in menu bar", isOn: $menuBar.shown)
                    .accessibilityLabel("Show mini player in menu bar")
                Toggle("Show song title in menu bar", isOn: $menuBar.showsTitle)
                    .accessibilityLabel("Show song title in menu bar")
                    .disabled(!menuBar.shown)
                Toggle(isOn: $menuBar.hidesDockIcon) {
                    Text("Keep running in menu bar only")
                    Text("Closing the window removes Veya from the Dock; playback continues.")
                }
                .accessibilityLabel("Keep running in menu bar only")
                .disabled(!menuBar.shown)
            }
            Section {
                Toggle(isOn: $notifiesTrackChanges) {
                    Text("Notify when the song changes")
                    Text("Shows the song and its artwork while Veya is in the background.")
                }
                .accessibilityLabel("Notify when the song changes")
                .onChange(of: notifiesTrackChanges) { _, on in
                    if on {
                        requestNotifications()
                    }
                }
                if notificationsDenied {
                    Text("Allow notifications for Veya in System Settings > Notifications.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Window colors", selection: $source) {
                    Text("From the Playing Artwork").tag(ColorSource.artwork)
                    Text("Accent Color").tag(ColorSource.accent)
                    Text("Cycle Through Colors").tag(ColorSource.cycle)
                }
                .accessibilityLabel("Window colors")
                ColorPicker(selection: accent, supportsOpacity: false) {
                    Text("Accent color")
                    Text(source == .cycle ? "Where the cycle starts." : "Also used while nothing is playing.")
                }
                .accessibilityLabel("Accent color")
                if source == .cycle {
                    Picker("Cycle speed", selection: $cycleSeconds) {
                        Text("Slow (5 min)").tag(300.0)
                        Text("Medium (1 min)").tag(60.0)
                        Text("Fast (15 s)").tag(15.0)
                    }
                    .accessibilityLabel("Cycle speed")
                }
            }
            Section {
                Toggle(isOn: $showsPanes) {
                    Text("Queue and lyrics panel")
                    Text("In full-window Now Playing. Off leaves only the artwork and controls in the middle.")
                }
                .accessibilityLabel("Queue and lyrics panel")
                Toggle(isOn: $panesBackground) {
                    Text("Panel behind queue and lyrics")
                    Text("In full-window Now Playing. Off shows them straight on the artwork.")
                }
                .accessibilityLabel("Panel behind queue and lyrics")
            }
        }
        .formStyle(.grouped)
    }

    /// A refusal turns the toggle back off, so it never claims banners that cannot show.
    private func requestNotifications() {
        Task {
            let granted = await (try? UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
            notificationsDenied = !granted
            if !granted {
                notifiesTrackChanges = false
            }
        }
    }

    private var accent: Binding<Color> {
        Binding(get: { Color(RGB(hex: accentHex) ?? .defaultAccent) }, set: { accentHex = RGB($0).hex })
    }
}

private struct PlaybackSettingsTab: View {
    @Bindable var settings: PlaybackSettings
    @State private var devices = OutputDevices()
    @State private var choosingFolders = false

    private static let speeds: [Float] = [0.8, 1, 1.25, 1.5, 1.75, 2]

    private var crossfade: Binding<Double> {
        Binding { Double(settings.crossfadeSeconds) } set: { settings.crossfadeSeconds = UInt8($0.rounded()) }
    }

    var body: some View {
        Form {
            Picker("Streaming quality", selection: $settings.bitrate) {
                Text("Low (96 kbps)").tag(Bitrate.kbps96)
                Text("Normal (160 kbps)").tag(Bitrate.kbps160)
                Text("High (320 kbps)").tag(Bitrate.kbps320)
            }
            // The grouped form shows row labels but leaves pop-up buttons and switches unnamed for VoiceOver.
            .accessibilityLabel("Streaming quality")
            Toggle("Normalize volume", isOn: $settings.normalises)
                .accessibilityLabel("Normalize volume")
            Picker("Loudness", selection: $settings.loudness) {
                Text("Quiet").tag(LoudnessPreset.quiet)
                Text("Normal").tag(LoudnessPreset.normal)
                Text("Loud").tag(LoudnessPreset.loud)
            }
            .accessibilityLabel("Loudness")
            .disabled(!settings.normalises)
            LabeledContent("Crossfade songs") {
                HStack {
                    Slider(value: crossfade, in: 0 ... Double(PlaybackSettings.maxCrossfadeSeconds), step: 1)
                        .accessibilityLabel("Crossfade songs")
                        .accessibilityValue(settings.crossfadeSeconds == 0 ? "Off" : "\(settings.crossfadeSeconds) seconds")
                    Text(settings.crossfadeSeconds == 0 ? "Off" : "\(settings.crossfadeSeconds) s")
                        .monospacedDigit()
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }
            Toggle(isOn: $settings.autoplay) {
                Text("Autoplay")
                Text("When an album or playlist ends, similar songs keep playing.")
            }
            .accessibilityLabel("Autoplay")
            Picker("Podcast speed", selection: $settings.episodeSpeed) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text("\(speed.formatted())×").tag(speed)
                }
            }
            .accessibilityLabel("Podcast speed")
            Picker("Output device", selection: $settings.outputDeviceUID) {
                Text("System Default").tag(String?.none)
                ForEach(devices.list) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .accessibilityLabel("Output device")
            Section {
                ForEach(settings.localFolders, id: \.self) { folder in
                    LabeledContent {
                        Button("Remove") { settings.removeLocalFolder(folder) }
                            .accessibilityLabel("Remove \(folder.lastPathComponent)")
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                        Text(folder.path(percentEncoded: false))
                    }
                }
                Button("Add Folder…") { choosingFolders = true }
                    .fileImporter(isPresented: $choosingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) {
                        if case let .success(folders) = $0 {
                            settings.addLocalFolders(folders)
                        }
                    }
            } header: {
                Text("Local Files")
            } footer: {
                Text("Only MP3, MP4 and FLAC files sampled at 44.1 kHz play, matched to local files in your playlists.")
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
    @State private var confirmingAudioClear = false
    @State private var audioCleared = false
    @State private var failure: LocalizedStringKey?
    @State private var limitChange: Task<Void, Never>?

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
                .accessibilityLabel("Audio cache size")
                LabeledContent("Downloaded audio") {
                    Button("Clear Audio Cache…") { confirmingAudioClear = true }
                        // Its own dialog: the Form already presents the metadata reset one.
                        .confirmationDialog("Clear the audio cache?", isPresented: $confirmingAudioClear) {
                            Button("Clear", role: .destructive, action: clearAudio)
                        } message: {
                            Text("Songs download again from Spotify the next time they play.")
                        }
                }
                if audioCleared {
                    Text("Audio cache cleared.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Changing the size reconnects to Spotify; the current track picks up where it was.")
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
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: {
            if !$0 {
                failure = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// The live cache changes first, so a failure leaves the saved size matching it;
    /// changes run in order so the last pick is the one both keep.
    private func setLimit(_ bytes: UInt64) {
        limitChange = Task { [previous = limitChange] in
            await previous?.value
            do {
                try await session.setAudioCacheLimit(bytes: bytes)
                settings.audioCacheLimitBytes = bytes
            } catch {
                failure = "Couldn't change the audio cache size."
            }
        }
    }

    private func clearAudio() {
        Task {
            do {
                try await session.clearAudioCache()
                audioCleared = true
            } catch {
                failure = "Couldn't clear the audio cache."
            }
        }
    }

    private func reset() {
        Task {
            do {
                try await session.resetMetadataCache()
                resetDone = true
            } catch {
                failure = "Couldn't reset the metadata cache."
            }
        }
    }
}

private struct AccountSettingsTab: View {
    let session: SessionModel
    let webAPI: WebAPIConnection
    let signOut: () -> Void

    private var signedIn: Bool {
        session.state != .signedOut
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Spotify") {
                    Text(signedIn ? "Signed in" : "Not signed in")
                }
                Button("Sign Out", action: signOut)
                    .disabled(!signedIn)
            }
            WebAPISection(webAPI: webAPI)
        }
        .formStyle(.grouped)
        // A sign-out deletes the Web API token too.
        .onChange(of: session.state) { webAPI.reload() }
    }
}

/// Search, Recently Played and podcast progress go through the user's own
/// Spotify app, since the shared client ID is rate limited on the Web API.
private struct WebAPISection: View {
    let webAPI: WebAPIConnection
    @State private var clientID = ""

    private var connecting: Bool {
        webAPI.attempt?.state == .signingIn
    }

    var body: some View {
        Section {
            TextField("Client ID", text: $clientID, prompt: Text(verbatim: "0123456789abcdef0123456789abcdef"))
                .accessibilityLabel("Client ID")
                .scaledFont(size: 13, design: .monospaced)
                .onSubmit(connect)
            LabeledContent("Status") {
                // Separate branches: an updated Text kept its old accessibility value.
                Group {
                    if connecting {
                        Text("Connecting…")
                    } else if webAPI.isConnected {
                        Text("Connected")
                    } else {
                        Text("Not connected")
                    }
                }
                .accessibilityIdentifier("webAPIStatus")
            }
            if connecting {
                Button("Cancel") { webAPI.attempt?.cancel() }
            } else {
                Button(webAPI.isConnected ? "Reconnect" : "Connect", action: connect)
                    .disabled(!WebAPIConnection.isValid(clientID: trimmed))
            }
            if webAPI.isConnected {
                Button("Disconnect") { try? webAPI.disconnect() }
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Spotify Web API")
        } footer: {
            Text(
                // swiftlint:disable:next line_length
                "Create an app at developer.spotify.com/dashboard, add the redirect URI \(WebAPIConnection.redirectURI), select Web API, then paste its Client ID here. Search, Recently Played and podcast progress use it."
            )
            .textSelection(.enabled)
        }
        .onAppear {
            clientID = webAPI.clientID
            webAPI.reload()
        }
    }

    private var trimmed: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var problem: LocalizedStringKey? {
        if webAPI.saveFailed {
            return "Couldn't save the connection in the Keychain."
        }
        if !trimmed.isEmpty, !WebAPIConnection.isValid(clientID: trimmed) {
            return "A Client ID is 32 letters and digits (0-9, a-f)."
        }
        switch webAPI.attempt?.state {
        case let .failed(failure) where failure != .cancelled:
            return "Couldn't connect. Check the Client ID and the redirect URI, then try again."
        default: return nil
        }
    }

    private func connect() {
        webAPI.connect(clientID: trimmed)
    }
}

private struct AdvancedSettingsTab: View {
    @Bindable var crashReports: CrashReports
    let updates: Updates
    @AppStorage(Diagnostics.levelKey) private var levelName = Diagnostics.defaultLevel.storedName

    var body: some View {
        Form {
            Picker("Log level", selection: $levelName) {
                ForEach(LogLevel.choices, id: \.storedName) { level in
                    Text(level.title).tag(level.storedName)
                }
            }
            .accessibilityLabel("Log level")
            .onChange(of: levelName) { _, name in
                Diagnostics.startLogging(level: LogLevel(storedName: name) ?? Diagnostics.defaultLevel)
            }
            Toggle(isOn: $crashReports.keepsReports) {
                Text("Keep crash reports")
                Text("Kept on this Mac and included when you export diagnostics. Turning this off deletes them.")
            }
            .accessibilityLabel("Keep crash reports")
            UpdatesSection(updates: updates)
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
