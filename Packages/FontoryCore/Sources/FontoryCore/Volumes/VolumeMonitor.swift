import AppKit

public enum VolumeEvent: Sendable {
    case mounted(volumeURL: URL, uuid: String?)
    case unmounted(volumeURL: URL)
}

/// Stateless; every access to `events` creates an independent subscription.
public final class VolumeMonitor: Sendable {
    public init() {}

    public var events: AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let handler: @Sendable (Notification, Bool) -> Void = { note, mounted in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                if mounted {
                    let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                    continuation.yield(.mounted(volumeURL: url, uuid: uuid))
                } else {
                    continuation.yield(.unmounted(volumeURL: url))
                }
            }
            let mount = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { handler($0, true) }
            let will = center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { handler($0, false) }
            let did = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { handler($0, false) }
            nonisolated(unsafe) let tokens = [mount, will, did]
            continuation.onTermination = { _ in
                for token in tokens { center.removeObserver(token) }
            }
        }
    }
}
