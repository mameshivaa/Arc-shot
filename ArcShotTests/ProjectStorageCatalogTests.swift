import XCTest

@testable import ArcShot

final class ProjectStorageCatalogTests: XCTestCase {
  func testTemporaryArcShotFileURLsMatchesPrefixesOnly() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let recordingURL = tempDir.appendingPathComponent("\(AppIdentifiers.TempFilePrefix.recording)test-\(UUID().uuidString).mov")
    let cameraURL = tempDir.appendingPathComponent("\(AppIdentifiers.TempFilePrefix.camera)test-\(UUID().uuidString).mov")
    let otherURL = tempDir.appendingPathComponent("unrelated-\(UUID().uuidString).mov")

    defer {
      try? FileManager.default.removeItem(at: recordingURL)
      try? FileManager.default.removeItem(at: cameraURL)
      try? FileManager.default.removeItem(at: otherURL)
    }

    try Data("screen".utf8).write(to: recordingURL)
    try Data("camera".utf8).write(to: cameraURL)
    try Data("other".utf8).write(to: otherURL)

    let urls = Set(ProjectStorageCatalog.temporaryArcShotFileURLs().map(\.lastPathComponent))
    XCTAssertTrue(urls.contains(recordingURL.lastPathComponent))
    XCTAssertTrue(urls.contains(cameraURL.lastPathComponent))
    XCTAssertFalse(urls.contains(otherURL.lastPathComponent))
  }

  func testClearTemporaryArcShotFilesRemovesOnlyArcShotTempFiles() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let recordingURL = tempDir.appendingPathComponent("\(AppIdentifiers.TempFilePrefix.recording)clear-\(UUID().uuidString).mov")
    let otherURL = tempDir.appendingPathComponent("keep-\(UUID().uuidString).mov")

    defer {
      try? FileManager.default.removeItem(at: otherURL)
    }

    let payload = Data(repeating: 0xAB, count: 128)
    try payload.write(to: recordingURL)
    try Data("keep".utf8).write(to: otherURL)

    let result = try ProjectStorageCatalog.clearTemporaryArcShotFiles()
    XCTAssertGreaterThanOrEqual(result.removedFileCount, 1)
    XCTAssertGreaterThanOrEqual(result.freedBytes, Int64(payload.count))
    XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))
  }

  func testDirectoryByteCountSumsNestedFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arcshot-bytecount-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let nested = directory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let rootFile = directory.appendingPathComponent("root.bin")
    let nestedFile = nested.appendingPathComponent("nested.bin")
    try Data(repeating: 1, count: 10).write(to: rootFile)
    try Data(repeating: 2, count: 20).write(to: nestedFile)

    XCTAssertEqual(ProjectStorageCatalog.directoryByteCount(at: directory), 30)
  }

  func testFormattedByteCountIsNonEmpty() {
    XCTAssertFalse(ProjectStorageCatalog.formattedByteCount(0).isEmpty)
    XCTAssertFalse(ProjectStorageCatalog.formattedByteCount(1_048_576).isEmpty)
  }
}
