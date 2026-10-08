import SpotCoreKit
import Testing

@Test func versionIsNotEmpty() {
    #expect(!version().isEmpty)
}

@Test func asyncCallRunsOnRustRuntime() async throws {
    #expect(try await runtimeCheck() == version())
}

@Test func rustErrorMapsToSpotCoreError() {
    #expect {
        try canonicalUri(uri: "not-a-uri")
    } throws: { error in
        guard case SpotCoreError.InvalidUri = error else { return false }
        return true
    }
}
