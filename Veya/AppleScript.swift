import AppKit
import SpotCoreKit

/// PBI-605: AppleScript support, described in `Veya.sdef` and run through `ShortcutActions`.
@MainActor
enum AppleScript {
    static var actions: ShortcutActions?
}

extension NSApplication {
    @objc var scriptingPlayerState: FourCharCode {
        guard let info = AppleScript.actions?.nowPlaying?.info else { return "kPSS".fourCharCode }
        return (info.isPlaying ? "kPSP" : "kPSp").fourCharCode
    }

    @objc var scriptingCurrentTrack: ScriptingTrack? {
        AppleScript.actions?.nowPlaying.map { ScriptingTrack(uri: $0.uri, info: $0.info) }
    }
}

@objc(VeyaScriptingTrack)
final nonisolated class ScriptingTrack: NSObject {
    @objc let name: String
    @objc let artist: String
    @objc let album: String
    @objc let duration: Int
    @objc let uniqueID: String

    init(uri: String, info: MediaControls.Info) {
        name = info.title
        artist = info.artist
        album = info.album ?? ""
        duration = Int(info.durationMs)
        uniqueID = uri
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSPropertySpecifier(containerClassDescription: app, containerSpecifier: nil, key: "scriptingCurrentTrack")
    }
}

/// Runs every command in `Veya.sdef`: suspends the Apple event while the action
/// runs, then replies or reports its failure.
@objc(VeyaScriptCommand)
final nonisolated class ScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Cocoa scripting delivers commands on the main thread, and the task resumes there.
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated {
            guard let actions = AppleScript.actions else { return command.fail(.notReady) }
            let code = command.commandDescription.appleEventCode
            let uri = command.directParameter as? String ?? ""
            command.suspendExecution()
            Task {
                do throws(ShortcutActions.Failure) {
                    switch code {
                    case "PlPs".fourCharCode: try await actions.perform(.togglePlayPause)
                    case "Next".fourCharCode: try await actions.perform(.next)
                    case "Prev".fourCharCode: try await actions.perform(.previous)
                    default: try await actions.play(uri)
                    }
                } catch {
                    command.fail(error)
                }
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    private func fail(_ failure: ShortcutActions.Failure) {
        scriptErrorNumber = errAEEventFailed
        scriptErrorString = String(localized: failure.localizedStringResource)
    }
}

private nonisolated extension String {
    var fourCharCode: FourCharCode {
        utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
