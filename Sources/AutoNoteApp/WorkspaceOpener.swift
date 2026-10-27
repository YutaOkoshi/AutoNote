import AppKit
import AutoNoteCore
import Foundation

/// Opens a Vault file in Obsidian when it is installed, otherwise in the default app for the file.
struct WorkspaceOpener: FileOpener {
    func open(_ file: URL) async {
        await MainActor.run {
            let workspace = NSWorkspace.shared
            // Ruling X38: Obsidian is detected through the app registered for its URL scheme.
            let obsidianInstalled = workspace.urlForApplication(toOpen: URL(string: "obsidian://open")!) != nil
            workspace.open(ObsidianLink.target(for: file, obsidianInstalled: obsidianInstalled))
        }
    }
}
