import Foundation
import OSLog

enum ProjectStorageCatalog {
  struct ScannedProjectSummary: Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var storageURL: URL
    var storageBytes: Int64
  }

  struct ProjectLibraryScanResult: Sendable {
    var projects: [ScannedProjectSummary]
    var projectsBytes: Int64
    var temporaryCacheBytes: Int64
    var errorMessage: String?
  }

  struct TemporaryCacheSweepResult: Equatable {
    var removedFileCount: Int
    var freedBytes: Int64
  }

  /// Scans the projects directory and temp cache. Safe to call off the main actor.
  static func scanProjectLibrary() -> ProjectLibraryScanResult {
    do {
      let dir = try projectsDirectoryURL()
      let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      let packageSummaries: [ScannedProjectSummary] = files
        .filter { $0.pathExtension == "arcshot" }
        .compactMap { packageURL in
          let projectURL = packageURL.appendingPathComponent("project.json")
          guard let data = try? Data(contentsOf: projectURL) else { return nil }
          guard let project = try? makeProjectJSONDecoder().decode(RecordingProject.self, from: data) else { return nil }
          return ScannedProjectSummary(
            id: project.id,
            title: project.title,
            createdAt: project.createdAt,
            storageURL: packageURL,
            storageBytes: directoryByteCount(at: packageURL)
          )
        }

      let sorted = packageSummaries.sorted { $0.createdAt > $1.createdAt }
      let projectsBytes = sorted.reduce(into: Int64(0)) { $0 += $1.storageBytes }
      return ProjectLibraryScanResult(
        projects: sorted,
        projectsBytes: projectsBytes,
        temporaryCacheBytes: temporaryCacheByteCount(),
        errorMessage: nil
      )
    } catch {
      return ProjectLibraryScanResult(
        projects: [],
        projectsBytes: 0,
        temporaryCacheBytes: 0,
        errorMessage: String(describing: error)
      )
    }
  }

  static func projectsDirectoryURL() throws -> URL {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root = appSupport.appendingPathComponent(AppIdentifiers.ApplicationSupport.appFolderName, isDirectory: true)
    let projects = root.appendingPathComponent(AppIdentifiers.ApplicationSupport.projectsFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    return projects
  }

  static func directoryByteCount(at url: URL) -> Int64 {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
      else { continue }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }

  static func temporaryArcShotFileURLs() -> [URL] {
    let directory = FileManager.default.temporaryDirectory
    let prefixes = [
      AppIdentifiers.TempFilePrefix.recording,
      AppIdentifiers.TempFilePrefix.camera,
    ]
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return []
    }
    return names.compactMap { name in
      guard prefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
      return directory.appendingPathComponent(name)
    }
  }

  static func temporaryCacheByteCount() -> Int64 {
    temporaryArcShotFileURLs().reduce(into: Int64(0)) { partial, url in
      partial += fileByteCount(at: url)
    }
  }

  static func clearTemporaryArcShotFiles() throws -> TemporaryCacheSweepResult {
    let manager = FileManager.default
    var removedFileCount = 0
    var freedBytes: Int64 = 0
    for url in temporaryArcShotFileURLs() {
      let bytes = fileByteCount(at: url)
      try manager.removeItem(at: url)
      removedFileCount += 1
      freedBytes += bytes
    }
    return TemporaryCacheSweepResult(removedFileCount: removedFileCount, freedBytes: freedBytes)
  }

  static func formattedByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private static func makeProjectJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func fileByteCount(at url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? 0)
  }
}

