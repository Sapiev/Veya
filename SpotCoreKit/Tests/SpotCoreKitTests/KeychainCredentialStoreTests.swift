import Foundation
import SpotCoreKit
import Testing

/// Runs against the real login keychain; each test owns a unique service.
@Suite(.serialized)
struct KeychainCredentialStoreTests {
    let store = KeychainCredentialStore(
        service: "app.veya.tests.\(UUID().uuidString)",
        account: "spotcore-credentials"
    )

    @Test func loadMissingIsNil() throws {
        #expect(try store.load() == nil)
    }

    @Test func roundTrip() throws {
        defer { try? store.delete() }
        let blob = Data("blob-1".utf8)

        try store.save(blob)

        #expect(try store.load() == blob)
    }

    @Test func savingTwiceOverwrites() throws {
        defer { try? store.delete() }

        try store.save(Data("first".utf8))
        try store.save(Data("second".utf8))
        try store.save(Data("second".utf8))

        #expect(try store.load() == Data("second".utf8))
    }

    @Test func deleteRemovesAndDeletingMissingSucceeds() throws {
        try store.save(Data("blob".utf8))

        try store.delete()
        try store.delete()

        #expect(try store.load() == nil)
    }

    @Test func otherAccountIsSeparate() throws {
        let other = KeychainCredentialStore(service: store.service, account: "other")
        defer {
            try? store.delete()
            try? other.delete()
        }

        try store.save(Data("mine".utf8))

        #expect(try other.load() == nil)
    }
}
