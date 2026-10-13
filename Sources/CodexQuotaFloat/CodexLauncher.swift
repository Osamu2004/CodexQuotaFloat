import AppKit
import Foundation

enum CodexLauncher {
    static func open(threadID: String? = nil, onError: ((Error) -> Void)? = nil) {
        if let threadID,
           let deepLink = URL(string: "codex://threads/\(threadID)"),
           NSWorkspace.shared.open(deepLink) {
            return
        }

        // Codex is integrated into ChatGPT in current desktop releases.
        // Keep the standalone path for older installations.
        let applicationURL: URL
        if FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") {
            applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        } else {
            applicationURL = URL(fileURLWithPath: "/Applications/Codex.app")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    onError?(error)
                }
            }
        }
    }
}
