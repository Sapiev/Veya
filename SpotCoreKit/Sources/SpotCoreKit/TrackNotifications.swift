import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Posts a banner once per track change, fed the same updates as Control Center.
/// Waits `settle` first so rapid skips post once and the artwork has time to load.
@MainActor
public final class TrackNotifications {
    public typealias Post = @MainActor (MediaControls.Info, CGImage?) -> Void

    private let isEnabled: @MainActor () -> Bool
    private let settle: Duration
    private let post: Post
    private var announced: [String]?
    private var latest: (info: MediaControls.Info, image: CGImage?)?
    private var pending: Task<Void, Never>?

    public init(
        settle: Duration = .seconds(1.5),
        isEnabled: @escaping @MainActor () -> Bool,
        post: @escaping Post = TrackNotifications.postToSystem
    ) {
        self.settle = settle
        self.isEnabled = isEnabled
        self.post = post
    }

    public func update(_ info: MediaControls.Info?, _ image: CGImage?) {
        guard let info else {
            pending?.cancel()
            announced = nil
            latest = nil
            return
        }
        latest = (info, image)
        let key = Self.key(info)
        guard key != announced else { return }
        announced = key
        pending?.cancel()
        pending = Task { [weak self, settle] in
            guard (try? await Task.sleep(for: settle)) != nil, let self, let latest,
                  Self.key(latest.info) == key, latest.info.isPlaying, isEnabled() else { return }
            post(latest.info, latest.image)
        }
    }

    private static func key(_ info: MediaControls.Info) -> [String] {
        [info.title, info.artist, info.album ?? ""]
    }

    public static func postToSystem(_ info: MediaControls.Info, _ image: CGImage?) {
        let content = UNMutableNotificationContent()
        content.title = info.title
        content.body = info.artist
        if let album = info.album { content.subtitle = album }
        if let image, let attachment = try? attachment(image) { content.attachments = [attachment] }
        // One identifier, so a new track replaces the previous banner in Notification Center.
        let request = UNNotificationRequest(identifier: "nowPlaying", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The system moves the file into its own store when the attachment is created.
    private static func attachment(_ image: CGImage) throws -> UNNotificationAttachment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
        return try UNNotificationAttachment(
            identifier: "artwork", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier]
        )
    }
}
