import spotcoreFFI
@testable import SpotCoreKit
import Testing

@MainActor
struct AudioEngineTests {
    @Test func eachOutputFeedsOneEngine() throws {
        let output = AudioOutput()
        let engine = try AudioEngine(output: output)

        #expect(throws: AudioEngineError.renderHandleTaken) { try AudioEngine(output: output) }
        withExtendedLifetime(engine) {}
    }

    @Test func rateIsClampedToEpisodeSpeeds() throws {
        let engine = try AudioEngine(output: AudioOutput())
        #expect(engine.rate == 1)

        for (asked, applied): (Float, Float) in [(1.25, 1.25), (0.5, 0.8), (4, 2), (.nan, 1)] {
            engine.rate = asked
            #expect(engine.rate == applied)
        }
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
