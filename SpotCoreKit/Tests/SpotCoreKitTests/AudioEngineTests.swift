@testable import SpotCoreKit
import spotcoreFFI
import Testing

@MainActor
struct AudioEngineTests {
    @Test func eachOutputFeedsOneEngine() throws {
        let output = AudioOutput()
        let engine = try AudioEngine(output: output)

        #expect(throws: AudioEngineError.renderHandleTaken) { try AudioEngine(output: output) }
        withExtendedLifetime(engine) {}
    }

    @Test func renderWithAnEmptyRingWritesSilence() throws {
        let handle = try #require(OpaquePointer(bitPattern: UInt(AudioOutput().takeRenderHandle())))
        defer { spotcore_audio_render_handle_free(handle) }
        var left = [Float](repeating: 1, count: 8)
        var right = [Float](repeating: 1, count: 8)

        let frames = spotcore_audio_render(handle, &left, &right, 8)

        #expect(frames == 0)
        #expect(left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 })
    }
}
