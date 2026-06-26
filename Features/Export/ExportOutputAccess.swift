import Foundation

// Holds security-scoped access for the user-selected export URL for the duration of export.
//
// INVARIANT (docs/INVARIANTS.md §4):
//   Sandboxed ArcShot cannot write directly to arbitrary user paths. Exporter writes to a
//   container temp file, then copies to the bookmarked destination while this helper keeps
//   directory/file scope alive. Do not remove or bypass without an alternative entitlement story.

final class ExportOutputAccess {
  private var scopedURLs: [URL] = []

  @discardableResult
  func begin(for outputURL: URL) -> Bool {
    release()
    let directoryURL = outputURL.deletingLastPathComponent()
    let fileGranted = outputURL.startAccessingSecurityScopedResource()
    let directoryGranted = directoryURL.startAccessingSecurityScopedResource()
    if fileGranted { scopedURLs.append(outputURL) }
    if directoryGranted { scopedURLs.append(directoryURL) }
    if fileGranted || directoryGranted { return true }
    // User-picked folders return scope above. Tests and app-container temp paths are
    // writable without bookmarks — must not fail export (ExportSmokeTests).
    return FileManager.default.isWritableFile(atPath: directoryURL.path)
  }

  func release() {
    for url in scopedURLs {
      url.stopAccessingSecurityScopedResource()
    }
    scopedURLs.removeAll()
  }
}
