import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ProjectStore {
  struct ProjectSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var storageURL: URL
    var storageBytes: Int64
  }

  struct StorageOverview: Equatable {
    var projectCount: Int
    var projectsBytes: Int64
    var temporaryCacheBytes: Int64

    var totalManagedBytes: Int64 {
      projectsBytes + temporaryCacheBytes
    }
  }

  private(set) var storageOverview = StorageOverview(projectCount: 0, projectsBytes: 0, temporaryCacheBytes: 0)

  private(set) var current: RecordingProject?
  private(set) var lastErrorMessage: String?
  private(set) var projects: [ProjectSummary] = []
  private(set) var pendingQuickShareProjectID: UUID?

  private var projectsRefreshTask: Task<Void, Never>?
  private var projectsRefreshGeneration = 0

  func setCurrent(_ project: RecordingProject) {
    current = project
  }

  func presentQuickShare(for projectID: UUID) {
    pendingQuickShareProjectID = projectID
  }

  func dismissQuickShare() {
    pendingQuickShareProjectID = nil
  }

  /// Apply a mutation to `current`; persist to disk when `persist == true`.
  func applyToCurrent(_ mutate: (inout RecordingProject) -> Void, persist: Bool = true) {
    guard var p = current else { return }
    mutate(&p)
    current = p
    if persist { saveCurrent() }
  }

  func ensureAutoZoomAnalysisForCurrent(assetDurationSeconds: Double) {
    guard var p = current,
      p.stylePreset == .cursorFocus,
      !p.cursorSamples.isEmpty
    else { return }
    if AutoZoomAnalysisService.validAnalysis(in: p, assetDurationSeconds: assetDurationSeconds) != nil {
      return
    }
    p.autoZoomAnalysis = AutoZoomAnalysisService.makeCursorDrivenAnalysis(
      project: p,
      assetDurationSeconds: assetDurationSeconds
    )
    current = p
    saveCurrent()
  }

  func refreshProjects() {
    scheduleProjectsRefresh(debounceNanoseconds: 0)
  }

  /// Coalesces repeated refreshes (e.g. after each save) so the main thread stays responsive.
  private func scheduleProjectsRefresh(debounceNanoseconds: UInt64 = 250_000_000) {
    projectsRefreshTask?.cancel()
    let generation = projectsRefreshGeneration &+ 1
    projectsRefreshGeneration = generation
    projectsRefreshTask = Task { [debounceNanoseconds] in
      if debounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
      }
      guard !Task.isCancelled else { return }
      let started = CFAbsoluteTimeGetCurrent()
      let scan = await Task.detached(priority: .utility) {
        ProjectStorageCatalog.scanProjectLibrary()
      }.value
      let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard generation == self.projectsRefreshGeneration else { return }
        self.applyProjectLibraryScan(scan, elapsedMs: elapsedMs, generation: generation)
      }
    }
  }

  private func applyProjectLibraryScan(
    _ scan: ProjectStorageCatalog.ProjectLibraryScanResult,
    elapsedMs: Int,
    generation: Int
  ) {
    projects = scan.projects.map {
      ProjectSummary(
        id: $0.id,
        title: $0.title,
        createdAt: $0.createdAt,
        storageURL: $0.storageURL,
        storageBytes: $0.storageBytes
      )
    }
    storageOverview = StorageOverview(
      projectCount: scan.projects.count,
      projectsBytes: scan.projectsBytes,
      temporaryCacheBytes: scan.temporaryCacheBytes
    )
    lastErrorMessage = scan.errorMessage
  }

  func saveCurrent() {
    guard var current else { return }
    do {
      let packageURL = try makeProjectPackageURL(for: current.id)
      try prepareProjectPackage(at: packageURL)
      current = try normalizeMediaReferencesForPackage(project: current, packageURL: packageURL)
      let data = try JSONEncoder.iso8601.encode(current)
      let url = packageURL.appendingPathComponent(ProjectPackage.projectFilename)
      try data.write(to: url, options: [.atomic])
      self.current = current
      lastErrorMessage = nil
      scheduleProjectsRefresh()
    } catch {
      lastErrorMessage = String(describing: error)
    }
  }

  func loadProject(id: UUID) {
    do {
      let url = try resolveProjectJSONURL(for: id)
      let data = try Data(contentsOf: url)
      current = try JSONDecoder.iso8601.decode(RecordingProject.self, from: data)
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = String(describing: error)
    }
  }

  func deleteProject(id: UUID) {
    deleteProjects(ids: [id])
  }

  func deleteProjects(ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    var firstError: String?
    for id in ids {
      do {
        try removeProjectPackage(id: id)
      } catch {
        firstError = String(describing: error)
      }
    }
    lastErrorMessage = firstError
    refreshProjects()
  }

  func renameCurrentProject(title: String) {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard var project = current else { return }
    project.title = title
    current = project
    saveCurrent()
  }

  func revealProjectInFinder(id: UUID) {
    revealProjectsInFinder(ids: [id])
  }

  func revealProjectsInFinder(ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    let urls = ids.compactMap { id -> URL? in
      guard let packageURL = try? makeProjectPackageURL(for: id),
            FileManager.default.fileExists(atPath: packageURL.path)
      else { return nil }
      return packageURL
    }
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
    lastErrorMessage = nil
  }

  @discardableResult
  func clearTemporaryRecordingCache() -> ProjectStorageCatalog.TemporaryCacheSweepResult? {
    do {
      let result = try ProjectStorageCatalog.clearTemporaryArcShotFiles()
      lastErrorMessage = nil
      refreshProjects()
      return result
    } catch {
      lastErrorMessage = String(describing: error)
      return nil
    }
  }

  private func makeProjectPackageURL(for id: UUID) throws -> URL {
    let dir = try makeProjectsDirectoryURL()
    return dir.appendingPathComponent("\(id.uuidString).arcshot", isDirectory: true)
  }

  private func removeProjectPackage(id: UUID) throws {
    let packageURL = try makeProjectPackageURL(for: id)
    if FileManager.default.fileExists(atPath: packageURL.path) {
      try FileManager.default.removeItem(at: packageURL)
    }
    if current?.id == id {
      current = nil
    }
    if pendingQuickShareProjectID == id {
      pendingQuickShareProjectID = nil
    }
  }

  private func resolveProjectJSONURL(for id: UUID) throws -> URL {
    let package = try makeProjectPackageURL(for: id)
    return package.appendingPathComponent(ProjectPackage.projectFilename)
  }

  private func makeProjectsDirectoryURL() throws -> URL {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )

    let arcShotRoot = appSupport.appendingPathComponent(AppIdentifiers.ApplicationSupport.appFolderName, isDirectory: true)

    let projects = arcShotRoot
      .appendingPathComponent(AppIdentifiers.ApplicationSupport.projectsFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    return projects
  }

  private enum ProjectPackage {
    static let projectFilename = "project.json"
    static let mediaFolderName = "media"
    static let assetsFolderName = "assets"
    static let exportsFolderName = "exports"
  }

  private func prepareProjectPackage(at packageURL: URL) throws {
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent(ProjectPackage.mediaFolderName, isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent(ProjectPackage.assetsFolderName, isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent(ProjectPackage.exportsFolderName, isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  /// Keep project packages self-contained without breaking already-packaged URLs.
  private func normalizeMediaReferencesForPackage(project: RecordingProject, packageURL: URL) throws -> RecordingProject {
    var p = project
    p.mediaURL = try copyIntoPackageIfNeeded(
      sourceURL: p.mediaURL,
      packageURL: packageURL,
      folderName: ProjectPackage.mediaFolderName,
      fallbackName: "recording.mov"
    )
    if p.timeline.clips.isEmpty {
      p.timeline = RecordingProject.TimelineModel.singleClip(mediaURL: p.mediaURL)
    } else {
      p.timeline = RecordingProject.TimelineModel(
        clips: p.timeline.clips.map { clip in
          var updated = clip
          if updated.sourceURL == project.mediaURL {
            updated.sourceURL = p.mediaURL
          }
          return updated
        },
        speedSegments: p.timeline.speedSegments
      )
    }

    if let secondary = p.secondaryRecording {
      let copied = try copyIntoPackageIfNeeded(
        sourceURL: secondary.mediaURL,
        packageURL: packageURL,
        folderName: ProjectPackage.mediaFolderName,
        fallbackName: "camera.mov"
      )
      var s = secondary
      s.mediaURL = copied
      p.secondaryRecording = s.clampedForExport()
    }

    if let bg = p.audioTrackSettings.backgroundMusicURL {
      p.audioTrackSettings.backgroundMusicURL = try copyIntoPackageIfNeeded(
        sourceURL: bg,
        packageURL: packageURL,
        folderName: ProjectPackage.assetsFolderName,
        fallbackName: "background-audio.m4a"
      )
    }

    return p
  }

  private func copyIntoPackageIfNeeded(
    sourceURL: URL,
    packageURL: URL,
    folderName: String,
    fallbackName: String
  ) throws -> URL {
    let standardizedSource = sourceURL.standardizedFileURL
    let standardizedPackage = packageURL.standardizedFileURL
    if standardizedSource.path.hasPrefix(standardizedPackage.path) {
      return sourceURL
    }

    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      return sourceURL
    }

    let filename = sourceURL.lastPathComponent.isEmpty ? fallbackName : sourceURL.lastPathComponent
    let destDir = packageURL.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    var dest = destDir.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: dest.path) {
      let ext = dest.pathExtension
      let base = dest.deletingPathExtension().lastPathComponent
      let unique = "\(base)-\(UUID().uuidString.prefix(8))"
      dest = destDir.appendingPathComponent(unique).appendingPathExtension(ext.isEmpty ? sourceURL.pathExtension : ext)
    }
    try FileManager.default.copyItem(at: sourceURL, to: dest)
    return dest
  }
}

private extension JSONEncoder {
  static var iso8601: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private extension JSONDecoder {
  static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
