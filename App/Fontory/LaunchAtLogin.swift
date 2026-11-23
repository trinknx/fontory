import Foundation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp`; if registration fails (e.g. with ad-hoc signing),
/// a LaunchAgent plist in `~/Library/LaunchAgents` is written instead.
enum LaunchAtLogin {
    enum Outcome: Equatable {
        case registered
        /// Registered, but the user must allow it in System Settings › General › Login Items.
        case requiresApproval
        case launchAgent
        case failed(String)
    }

    static let agentLabel = "local.fontory.app"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func agentPlist(executablePath: String) throws -> Data {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "Program": executablePath,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval || FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func enable() -> Outcome {
        do {
            try SMAppService.mainApp.register()
            return SMAppService.mainApp.status == .requiresApproval ? .requiresApproval : .registered
        } catch {
            guard let executable = Bundle.main.executablePath else { return .failed(error.localizedDescription) }
            do {
                try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try agentPlist(executablePath: executable).write(to: agentURL, options: .atomic)
                return .launchAgent
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Removes both mechanisms. Returns an error message if the login item could not be removed.
    @discardableResult
    static func disable() -> String? {
        var message: String?
        if SMAppService.mainApp.status != .notRegistered && SMAppService.mainApp.status != .notFound {
            do { try SMAppService.mainApp.unregister() } catch { message = error.localizedDescription }
        }
        try? FileManager.default.removeItem(at: agentURL)
        return message
    }
}
