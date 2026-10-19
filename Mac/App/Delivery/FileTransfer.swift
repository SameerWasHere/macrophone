import AppKit
import Foundation
import MacrophoneKit

/// Save to Mac's Downloads (Oct 19 2026): a photo or file from the phone, put back together by
/// `AttachmentInbox`, goes into ~/Downloads under its own name (never replacing one — "name 2")
/// and is shown selected in Finder. If macOS keeps Macrophone out of Downloads (the person said no
/// to the one-time "access files in your Downloads folder" question), it stays in Macrophone's
/// From iPhone folder and that's shown instead. Names and sizes are never logged.
@MainActor
enum DownloadsSaver {
    static func save(_ url: URL, isImage: Bool, log: DiagnosticLog) -> (Bool, String) {
        let what = isImage ? "photo" : "file"
        let fm = FileManager.default
        // A locked Mac can't show Finder; the file is there once it's unlocked.
        let shows = !StayAwake.isLocked
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            let dest = SaveToDownloads.freeURL(in: downloads, for: url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: dest)
                log.add("downloads: saved a \(what)")
                if shows { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
                return (true, "Saved to Downloads on your Mac" + (shows ? " — shown in Finder" : ""))
            } catch {
                log.add("downloads: couldn't save there, kept in From iPhone")
            }
        }
        if shows { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return (true, "Macrophone can't save to Downloads — the \(what) is in its From iPhone folder" + (shows ? ", shown in Finder" : ""))
    }
}
