import AVFoundation
import os
import spotcoreFFI

public enum AudioEngineError: Error, Equatable, Sendable {
    /// Each `AudioOutput` feeds exactly one engine.
    case renderHandleTaken
}

/// Plays an `AudioOutput`'s ring through the chosen output device, or the
/// system default when none is chosen or the chosen one is missing (ADR-006).
@MainActor
public final class AudioEngine {
    private static let log = Logger(subsystem: "veya", category: "audio")

    // nonisolated(unsafe) only so deinit, which has sole access, can stop and free them.
    private nonisolated(unsafe) let engine = AVAudioEngine()
    private nonisolated(unsafe) let renderHandle: OpaquePointer
    private let timePitch = AVAudioUnitTimePitch()
    private var configurationObserver: (any NSObjectProtocol)?
    private var deviceListener: SystemAudioListener?
    private var wantsToRun = false

    /// UID of the chosen output device; `nil` follows the system default.
    public var outputDeviceUID: String? {
        didSet { route() }
    }

    public static let rateRange: ClosedRange<Float> = 0.8 ... 2.0

    /// Playback speed with pitch preserved, clamped to `rateRange`; NaN means 1x.
    /// librespot keeps decoding at 1x and the ring drains faster (ADR-007).
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = Self.clamped(rate: newValue) }
    }

    static func clamped(rate: Float) -> Float {
        rate.isNaN ? 1 : min(max(rate, rateRange.lowerBound), rateRange.upperBound)
    }

    var outputDevice: AudioDeviceID {
        engine.outputNode.auAudioUnit.deviceID
    }

    public init(output: AudioOutput) throws {
        guard let handle = OpaquePointer(bitPattern: UInt(output.takeRenderHandle())) else {
            throw AudioEngineError.renderHandleTaken
        }
        renderHandle = handle
        let source = Self.sourceNode(rendering: handle)
        let format = source.outputFormat(forBus: 0)
        engine.attach(source)
        engine.attach(timePitch)
        engine.connect(source, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        // The engine stops when its device changes or goes away; restart it on the target.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.switchToTargetDevice()
                self?.restart()
            }
        }
        // Moves to the chosen device when it reappears, or to a new default.
        deviceListener = SystemAudioListener(
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            self?.route()
        }
    }

    deinit {
        engine.stop()
        spotcore_audio_render_handle_free(renderHandle)
    }

    public func start() throws {
        wantsToRun = true
        try engine.start()
    }

    public func stop() {
        wantsToRun = false
        engine.stop()
    }

    private func route() {
        if switchToTargetDevice() {
            restart()
        }
    }

    /// Returns whether it stopped the engine to switch devices.
    private func switchToTargetDevice() -> Bool {
        let target = outputDeviceUID.flatMap(SystemAudio.outputDevice(uid:)) ?? SystemAudio.defaultOutputDevice
        guard target != kAudioObjectUnknown, target != outputDevice else { return false }
        engine.stop()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(target)
        } catch {
            Self.log.error("audio output device switch failed: \(error, privacy: .public)")
        }
        return true
    }

    private func restart() {
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        guard wantsToRun else { return }
        do {
            try engine.start()
        } catch {
            Self.log.error("audio engine restart failed: \(error, privacy: .public)")
        }
    }

    /// Nonisolated so the render block is not main-actor isolated: it runs on
    /// the real-time audio thread and must not lock or allocate.
    private nonisolated static func sourceNode(rendering handle: OpaquePointer) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        nonisolated(unsafe) let handle = handle
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            spotcore_audio_render(handle, left, right, Int(frameCount))
            return noErr
        }
    }
}
