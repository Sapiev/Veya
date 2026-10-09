import CoreAudio
import Observation

public struct AudioDevice: Hashable, Identifiable, Sendable {
    /// Stable across reboots and reconnects, unlike `AudioDeviceID`.
    public let uid: String
    public let name: String

    public var id: String {
        uid
    }
}

/// The CoreAudio output devices, kept current as devices appear and disappear.
@MainActor
@Observable
public final class OutputDevices {
    public private(set) var list: [AudioDevice] = SystemAudio.outputDevices

    @ObservationIgnored private var listener: SystemAudioListener?

    public init() {
        listener = SystemAudioListener(kAudioHardwarePropertyDevices) { [weak self] in
            self?.list = SystemAudio.outputDevices
        }
    }
}

enum SystemAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static var outputDevices: [AudioDevice] {
        deviceIDs.filter(hasOutput).compactMap { id in
            guard let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            return AudioDevice(uid: uid, name: name)
        }
    }

    static var defaultOutputDevice: AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return id
    }

    /// `nil` when no output device with `uid` is connected.
    static func outputDevice(uid: String) -> AudioDeviceID? {
        deviceIDs.first { hasOutput($0) && string(kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static var deviceIDs: [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        // A device can vanish between the two calls, shrinking the list.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        // CoreAudio hands out a +1 reference for string properties.
        return value?.takeRetainedValue() as String?
    }
}

/// Calls `onChange` on the main actor whenever any of `selectors` changes on
/// the system audio object, until deinitialised.
final class SystemAudioListener {
    private let selectors: [AudioObjectPropertySelector]
    private let block: AudioObjectPropertyListenerBlock

    init(_ selectors: AudioObjectPropertySelector..., onChange: @escaping @MainActor @Sendable () -> Void) {
        self.selectors = selectors
        block = { _, _ in MainActor.assumeIsolated { onChange() } }
        for selector in selectors {
            var address = SystemAudio.address(selector)
            AudioObjectAddPropertyListenerBlock(SystemAudio.system, &address, .main, block)
        }
    }

    deinit {
        for selector in selectors {
            var address = SystemAudio.address(selector)
            AudioObjectRemovePropertyListenerBlock(SystemAudio.system, &address, .main, block)
        }
    }
}
