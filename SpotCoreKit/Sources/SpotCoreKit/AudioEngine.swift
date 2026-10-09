import AVFoundation
import os
import spotcoreFFI

public enum AudioEngineError: Error, Equatable, Sendable {
    /// Each `AudioOutput` feeds exactly one engine.
    case renderHandleTaken
}

/// Plays an `AudioOutput`'s ring through the system default output device,
/// following it when it changes (ADR-006).
@MainActor
public final class AudioEngine {
    private static let log = Logger(subsystem: "veya", category: "audio")

    private let engine = AVAudioEngine()
    // nonisolated(unsafe) only so deinit, which has sole access, can free it.
    private nonisolated(unsafe) let renderHandle: OpaquePointer
    private var configurationObserver: (any NSObjectProtocol)?

    public init(output: AudioOutput) throws {
        guard let handle = OpaquePointer(bitPattern: UInt(output.takeRenderHandle())) else {
            throw AudioEngineError.renderHandleTaken
        }
        renderHandle = handle
        let source = Self.sourceNode(rendering: handle)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: source.outputFormat(forBus: 0))
        // The engine stops when the default device changes; restart it on the new one.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    deinit {
        engine.stop()
        spotcore_audio_render_handle_free(renderHandle)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    private func restart() {
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do {
            try engine.start()
        } catch {
            Self.log.error("audio engine restart failed: \(error, privacy: .public)")
        }
    }

    /// Nonisolated so the render block is not main-actor isolated: it runs on
    /// the real-time audio thread and must not lock or allocate.
    private nonisolated static func sourceNode(rendering handle: OpaquePointer) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
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
