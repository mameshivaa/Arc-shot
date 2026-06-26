@preconcurrency import AVFoundation
import CoreVideo
import XCTest

@testable import ArcShot

extension AVMutableComposition: @retroactive @unchecked Sendable {}

// MARK: - Fixture (minimal H.264 .mov for Exporter smoke)

private enum ExportSmokeFixtureConstants {
  static let pixelWidth: Int = 320
  static let pixelHeight: Int = 240
  static let frameRate: Int32 = 30
  static let frameCount = 24
}

private func exportSmokeTopDownPiPRect(
  originXN: Double,
  originYN: Double,
  widthN: Double,
  heightN: Double,
  renderSize: CGSize
) -> CGRect {
  ExportVideoGeometry.pipCompositorRect(
    originXN: originXN,
    originYN: originYN,
    widthN: widthN,
    heightN: heightN,
    renderSize: renderSize
  )
}

private enum ExportSmokeFixtureMaker {
  struct MakerError: Error {
    let message: String
  }

  private enum VideoPattern {
    case solidBlack
    case solidBright
    case asymmetricCamera
    case cameraAspectFillBands
    case temporalCamera
    case verticalStripes(stripeWidth: Int)
  }

  static func tempDirectory(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      prefix + "_" + UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func remove(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// Writes a short solid black H.264 video (no audio) for determinism on export pipelines.
  static func writeSolidBlackVideoMOV(to url: URL) throws {
    try writeVideoMOV(to: url, pattern: .solidBlack)
  }

  /// Writes a short bright H.264 video (no audio) for fade/darkening export checks.
  static func writeSolidBrightVideoMOV(to url: URL) throws {
    try writeVideoMOV(to: url, pattern: .solidBright)
  }

  /// Writes a short asymmetric camera video for PiP mirroring and clipping export checks.
  static func writeAsymmetricCameraVideoMOV(to url: URL) throws {
    try writeVideoMOV(to: url, pattern: .asymmetricCamera)
  }

  /// Writes a short banded camera video for PiP aspect-fill crop export checks.
  static func writeCameraAspectFillBandsVideoMOV(to url: URL) throws {
    try writeVideoMOV(to: url, pattern: .cameraAspectFillBands)
  }

  /// Writes a short camera video that changes color over time for PiP playback checks.
  static func writeTemporalCameraVideoMOV(to url: URL) throws {
    try writeVideoMOV(to: url, pattern: .temporalCamera)
  }

  /// Writes a short striped H.264 video (no audio) for blur/edge contrast export checks.
  static func writeVerticalStripeVideoMOV(to url: URL, stripeWidth: Int = 6) throws {
    try writeVideoMOV(to: url, pattern: .verticalStripes(stripeWidth: stripeWidth))
  }

  private static func writeVideoMOV(to url: URL, pattern: VideoPattern) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: ExportSmokeFixtureConstants.pixelWidth,
      AVVideoHeightKey: ExportSmokeFixtureConstants.pixelHeight,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 400_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
      ] as [String: Any],
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: ExportSmokeFixtureConstants.pixelWidth,
        kCVPixelBufferHeightKey as String: ExportSmokeFixtureConstants.pixelHeight,
      ])

    guard writer.canAdd(input) else {
      throw MakerError(message: "Writer cannot add video input.")
    }
    writer.add(input)

    guard writer.startWriting() else {
      throw MakerError(message: writer.error?.localizedDescription ?? "startWriting failed.")
    }

    writer.startSession(atSourceTime: .zero)

    try feedFrames(videoInput: input, adaptor: adaptor, pattern: pattern)

    input.markAsFinished()
    try awaitWriterFinish(writer)
  }

  static func writeSineAudioCAF(to url: URL, durationSeconds: Double = 0.8) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }

    let sampleRate = 44_100.0
    let frameCount = AVAudioFrameCount(max(1, Int(sampleRate * durationSeconds)))
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let channel = buffer.floatChannelData?[0]
    else {
      throw MakerError(message: "Audio buffer create failed.")
    }

    buffer.frameLength = frameCount
    for i in 0 ..< Int(frameCount) {
      channel[i] = Float(sin((Double(i) / sampleRate) * 440.0 * 2.0 * Double.pi) * 0.18)
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  private static func feedFrames(
    videoInput: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    pattern: VideoPattern
  ) throws {
    let w = ExportSmokeFixtureConstants.pixelWidth
    let h = ExportSmokeFixtureConstants.pixelHeight

    let frameDur = CMTime(value: 1, timescale: CMTimeScale(ExportSmokeFixtureConstants.frameRate))

    for frameIdx in 0 ..< ExportSmokeFixtureConstants.frameCount {
      while !videoInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
      }

      guard let pb = try makeFilledBGRABuffer(width: w, height: h, pattern: pattern, frameIdx: frameIdx) else {
        throw MakerError(message: "CVPixelBuffer create failed.")
      }

      let pts = CMTimeMultiply(frameDur, multiplier: Int32(frameIdx))
      guard adaptor.append(pb, withPresentationTime: pts) else {
        throw MakerError(message: "append(buffer,pts) failed.")
      }
    }
  }

  private static func makeFilledBGRABuffer(
    width: Int,
    height: Int,
    pattern: VideoPattern,
    frameIdx: Int
  ) throws -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary?,
      &buffer
    )

    guard let pb = buffer else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    guard let ptr = CVPixelBufferGetBaseAddress(pb) else { return pb }
    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
    switch pattern {
    case .solidBlack:
      for row in 0 ..< height {
        let rowPtr = ptr.advanced(by: row * rowBytes)
        memset(rowPtr, 0, rowBytes)
      }
    case .solidBright:
      let bytes = ptr.assumingMemoryBound(to: UInt8.self)
      for row in 0 ..< height {
        for col in 0 ..< width {
          let offset = row * rowBytes + col * 4
          bytes[offset] = 235
          bytes[offset + 1] = 235
          bytes[offset + 2] = 235
          bytes[offset + 3] = 255
        }
      }
    case .asymmetricCamera:
      let bytes = ptr.assumingMemoryBound(to: UInt8.self)
      for row in 0 ..< height {
        for col in 0 ..< width {
          let offset = row * rowBytes + col * 4
          if col < width / 2 {
            bytes[offset] = 20
            bytes[offset + 1] = 20
            bytes[offset + 2] = 235
          } else {
            bytes[offset] = 20
            bytes[offset + 1] = 235
            bytes[offset + 2] = 20
          }
          bytes[offset + 3] = 255
        }
      }
    case .cameraAspectFillBands:
      let bytes = ptr.assumingMemoryBound(to: UInt8.self)
      for row in 0 ..< height {
        for col in 0 ..< width {
          let offset = row * rowBytes + col * 4
          if row < 48 {
            bytes[offset] = 235
            bytes[offset + 1] = 20
            bytes[offset + 2] = 20
          } else if row >= height - 48 {
            bytes[offset] = 20
            bytes[offset + 1] = 20
            bytes[offset + 2] = 235
          } else {
            bytes[offset] = 20
            bytes[offset + 1] = 235
            bytes[offset + 2] = 20
          }
          bytes[offset + 3] = 255
        }
      }
    case .temporalCamera:
      let isFirstHalf = frameIdx < ExportSmokeFixtureConstants.frameCount / 2
      let bytes = ptr.assumingMemoryBound(to: UInt8.self)
      for row in 0 ..< height {
        for col in 0 ..< width {
          let offset = row * rowBytes + col * 4
          bytes[offset] = 20
          bytes[offset + 1] = isFirstHalf ? 20 : 235
          bytes[offset + 2] = isFirstHalf ? 235 : 20
          bytes[offset + 3] = 255
        }
      }
    case let .verticalStripes(stripeWidth):
      let clampedStripeWidth = max(1, stripeWidth)
      let bytes = ptr.assumingMemoryBound(to: UInt8.self)
      for row in 0 ..< height {
        for col in 0 ..< width {
          let ramp = Double(col) / Double(max(1, width - 1))
          let midpoint = 72 + 112 * ramp
          let value = UInt8(max(8, min(245, midpoint + ((col / clampedStripeWidth).isMultiple(of: 2) ? 54 : -54))))
          let offset = row * rowBytes + col * 4
          bytes[offset] = value
          bytes[offset + 1] = value
          bytes[offset + 2] = value
          bytes[offset + 3] = 255
        }
      }
    }

    return pb
  }

  private static func awaitWriterFinish(_ writer: AVAssetWriter) throws {
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting {
      sem.signal()
    }
    sem.wait()

    guard writer.status == .completed else {
      throw MakerError(message: writer.error?.localizedDescription ?? "finishWriting incomplete.")
    }
  }
}

private func volume(at index: Int, in mix: AVAudioMix) throws -> Float {
  let params = try XCTUnwrap(mix.inputParameters[safe: index])
  var startVolume: Float = -1
  var endVolume: Float = -1
  var timeRange = CMTimeRange.zero
  XCTAssertTrue(params.getVolumeRamp(for: .zero, startVolume: &startVolume, endVolume: &endVolume, timeRange: &timeRange))
  return startVolume
}

private struct AverageRGB {
  var red: Double
  var green: Double
  var blue: Double

  var luminance: Double {
    0.2126 * red + 0.7152 * green + 0.0722 * blue
  }
}

private func averageRGB(in image: CGImage, rect: CGRect) throws -> AverageRGB {
  let width = image.width
  let height = image.height
  XCTAssertGreaterThan(width, 0)
  XCTAssertGreaterThan(height, 0)
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Could not create pixel sampling context.")
  }

  context.translateBy(x: 0, y: CGFloat(height))
  context.scaleBy(x: 1, y: -1)
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

  let sampleRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
  guard !sampleRect.isNull, sampleRect.width >= 1, sampleRect.height >= 1 else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Pixel sample rect is outside the frame.")
  }

  var redTotal = 0.0
  var greenTotal = 0.0
  var blueTotal = 0.0
  var count = 0
  for y in Int(sampleRect.minY) ..< Int(sampleRect.maxY) {
    for x in Int(sampleRect.minX) ..< Int(sampleRect.maxX) {
      let offset = y * bytesPerRow + x * bytesPerPixel
      let r = Double(pixels[offset])
      let g = Double(pixels[offset + 1])
      let b = Double(pixels[offset + 2])
      redTotal += r
      greenTotal += g
      blueTotal += b
      count += 1
    }
  }

  guard count > 0 else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Pixel sample rect had no pixels.")
  }
  return AverageRGB(
    red: redTotal / Double(count),
    green: greenTotal / Double(count),
    blue: blueTotal / Double(count)
  )
}

private func averageLuminance(in image: CGImage, rect: CGRect) throws -> Double {
  try averageRGB(in: image, rect: rect).luminance
}

private func maximumLuminance(in image: CGImage, rect: CGRect) throws -> Double {
  let width = image.width
  let height = image.height
  XCTAssertGreaterThan(width, 0)
  XCTAssertGreaterThan(height, 0)
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Could not create pixel sampling context.")
  }

  context.translateBy(x: 0, y: CGFloat(height))
  context.scaleBy(x: 1, y: -1)
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

  let sampleRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
  guard !sampleRect.isNull, sampleRect.width >= 1, sampleRect.height >= 1 else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Pixel sample rect is outside the frame.")
  }

  var maximum = 0.0
  for y in Int(sampleRect.minY) ..< Int(sampleRect.maxY) {
    for x in Int(sampleRect.minX) ..< Int(sampleRect.maxX) {
      let offset = y * bytesPerRow + x * bytesPerPixel
      let r = Double(pixels[offset])
      let g = Double(pixels[offset + 1])
      let b = Double(pixels[offset + 2])
      maximum = max(maximum, 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }
  }
  return maximum
}

private func averageAdjacentHorizontalLuminanceDelta(in image: CGImage, rect: CGRect) throws -> Double {
  let width = image.width
  let height = image.height
  XCTAssertGreaterThan(width, 0)
  XCTAssertGreaterThan(height, 0)
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Could not create pixel sampling context.")
  }

  context.translateBy(x: 0, y: CGFloat(height))
  context.scaleBy(x: 1, y: -1)
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

  let sampleRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
  guard !sampleRect.isNull, sampleRect.width >= 2, sampleRect.height >= 1 else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Pixel sample rect is outside the frame.")
  }

  func luminanceAt(x: Int, y: Int) -> Double {
    let offset = y * bytesPerRow + x * bytesPerPixel
    let r = Double(pixels[offset])
    let g = Double(pixels[offset + 1])
    let b = Double(pixels[offset + 2])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  var total = 0.0
  var count = 0
  for y in Int(sampleRect.minY) ..< Int(sampleRect.maxY) {
    for x in Int(sampleRect.minX) ..< (Int(sampleRect.maxX) - 1) {
      total += abs(luminanceAt(x: x, y: y) - luminanceAt(x: x + 1, y: y))
      count += 1
    }
  }

  guard count > 0 else {
    throw ExportSmokeFixtureMaker.MakerError(message: "Pixel sample rect had no adjacent pixels.")
  }
  return total / Double(count)
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

// MARK: - Exporter smoke (public export API only)

final class ExportSmokeIntegrationTests: XCTestCase {
  func testExporterProducesNonEmptyMp4MinimalProject() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmoke")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_input.mov")
    let mp4URL = root.appendingPathComponent("fixture_output.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: []
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }

    guard case let .finished(out) = terminalState else {
      XCTFail("Expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertEqual(out, mp4URL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

    let size = (
      try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64
    ) ?? 0
    XCTAssertGreaterThan(size, 2_048, "Output MP4 unusually small.")

    let progress = await MainActor.run { exporter.progress }
    XCTAssertEqual(progress, 1, accuracy: 0.001)
  }

  func testExporterValidatorCoversCodecsAndAspectRatios() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokePresetMatrix")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_preset_matrix_in.mov")
    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let cases: [(RecordingProject.ExportPresetID, AspectRatioPreset, CGSize)] = [
      (.p1080p30, .sixteenNine, CGSize(width: 1920, height: 1080)),
      (.p1080p30Hevc, .nineSixteen, CGSize(width: 1080, height: 1920)),
      (.p720p30, .oneOne, CGSize(width: 720, height: 720)),
      (.p720p30Hevc, .fourThree, CGSize(width: 960, height: 720)),
      (.p720p30, .threeFour, CGSize(width: 720, height: 960)),
    ]

    for (presetID, aspectRatio, expectedSize) in cases {
      let mp4URL = root.appendingPathComponent("fixture_\(presetID.rawValue)_\(aspectRatio.rawValue).mp4")
      let project = RecordingProject(
        id: UUID(),
        createdAt: Date(),
        title: "Fixture \(presetID.rawValue) \(aspectRatio.rawValue)",
        source: .init(kind: .display, displayID: 1, windowID: nil),
        mediaURL: movURL,
        cursorSamples: [],
        exportPreset: presetID,
        outputAspectRatio: aspectRatio,
        stylePreset: .none,
        styleSettings: RecordingProject.StyleSettings(),
        cursorHighlightRegions: []
      )

      let exporter = await MainActor.run { () -> Exporter in
        let e = Exporter()
        e.export(project: project, to: mp4URL)
        return e
      }

      try await waitForTerminalExport(exporter)

      let terminalState = await MainActor.run { exporter.state }
      guard case let .finished(out) = terminalState else {
        XCTFail("Preset export expected finished for \(presetID.rawValue)/\(aspectRatio.rawValue), got \(describeExportState(terminalState))")
        continue
      }

      XCTAssertEqual(out, mp4URL)
      let encodedSize = try await encodedVideoSize(at: out)
      XCTAssertEqual(encodedSize.width, expectedSize.width, accuracy: 1, "\(presetID.rawValue)/\(aspectRatio.rawValue)")
      XCTAssertEqual(encodedSize.height, expectedSize.height, accuracy: 1, "\(presetID.rawValue)/\(aspectRatio.rawValue)")
    }
  }

  func testExporterCancellationPreservesExistingOutputAndRemovesPartialOutput() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeCancel")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_cancel_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_cancel_out.mp4")
    let originalData = Data("stable existing export".utf8)

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try originalData.write(to: mp4URL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Cancel",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: []
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      e.stop()
      return e
    }

    let terminalState = await MainActor.run { exporter.state }
    XCTAssertEqual(describeExportState(terminalState), "idle")
    XCTAssertEqual(try Data(contentsOf: mp4URL), originalData)

    let leftovers = try await waitForNoTemporaryOutputs(
      in: root,
      matching: "fixture_cancel_out"
    )
    XCTAssertTrue(leftovers.isEmpty, "Cancelled export left temporary output files: \(leftovers)")
  }

  func testExporterProducesNonEmptyMp4WithTrim() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeTrim")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_trim_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_trim_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let assetDur = Double(ExportSmokeFixtureConstants.frameCount) / Double(ExportSmokeFixtureConstants.frameRate)
    let trimEnd = assetDur * 0.85
    let trimStart = min(0.12, trimEnd - 0.35)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Trim",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      timeline: RecordingProject.TimelineModel.singleClip(
        mediaURL: movURL,
        sourceStartSeconds: trimStart,
        sourceEndSeconds: trimEnd
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }

    guard case let .finished(out) = terminalState else {
      XCTFail("Trim export expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    let size = (
      try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64
    ) ?? 0
    XCTAssertGreaterThan(size, 2_048, "Trim export MP4 unusually small.")
  }

  func testExporterProducesMp4FromTimelineClipsAndSpeed() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeTimeline")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_timeline_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_timeline_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let clipID = UUID()
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Timeline",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      timeline: RecordingProject.TimelineModel(
        clips: [
          .init(id: clipID, sourceURL: movURL, sourceStartSeconds: 0, timelineStartSeconds: 0, durationSeconds: 0.20),
          .init(sourceURL: movURL, sourceStartSeconds: 0.45, timelineStartSeconds: 0.20, durationSeconds: 0.20),
        ],
        speedSegments: [
          .init(startSeconds: 0, endSeconds: 0.20, rate: 2),
        ]
      ),
      zoomSegments: [
        RecordingProject.ZoomSegment(startSeconds: 0.08, endSeconds: 0.32, scale: 1.4, anchorX: 0.5, anchorY: 0.5),
      ]
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Timeline export expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    let size = (
      try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64
    ) ?? 0
    XCTAssertGreaterThan(size, 2_048, "Timeline export MP4 unusually small.")

    let asset = AVURLAsset(url: out)
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 0.4, accuracy: 0.16)
  }

  func testPreviewCompositionUsesSingleTimelineClipDuration() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotPreviewSingleClip")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_preview_single_clip.mov")
    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Preview Single Clip",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      timeline: RecordingProject.TimelineModel(clips: [
        .init(sourceURL: movURL, sourceStartSeconds: 0.2, timelineStartSeconds: 0, durationSeconds: 0.35),
      ])
    )

    let maybeComposition = try await EditorPlaybackController.makeTimelinePreviewComposition(project: project)
    let composition = try XCTUnwrap(maybeComposition)
    let duration = try await composition.load(.duration)
    XCTAssertEqual(duration.seconds, 0.35, accuracy: 0.08)
  }

  func testPreviewCompositionUsesSpeedAdjustedSingleTimelineClipDuration() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotPreviewSpeedSingleClip")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_preview_speed_single_clip.mov")
    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Preview Speed Single Clip",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      timeline: RecordingProject.TimelineModel(
        clips: [
          .init(sourceURL: movURL, sourceStartSeconds: 0.1, timelineStartSeconds: 0, durationSeconds: 0.25),
        ],
        speedSegments: [
          .init(startSeconds: 0, endSeconds: 0.25, rate: 2),
        ]
      )
    )

    let maybeComposition = try await EditorPlaybackController.makeTimelinePreviewComposition(project: project)
    let composition = try XCTUnwrap(maybeComposition)
    let duration = try await composition.load(.duration)
    XCTAssertEqual(duration.seconds, 0.25, accuracy: 0.08)
  }

  func testExporterProducesMp4FromSingleTimelineClipBounds() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeSingleClipBounds")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_single_clip_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_single_clip_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Single Clip Bounds",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      timeline: RecordingProject.TimelineModel(clips: [
        .init(sourceURL: movURL, sourceStartSeconds: 0.18, timelineStartSeconds: 0, durationSeconds: 0.42),
      ])
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Single clip bounds export expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    let asset = AVURLAsset(url: out)
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 0.42, accuracy: 0.16)
  }

  func testExporterProducesMp4FromSpeedAdjustedSingleTimelineClipBounds() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeSpeedSingleClip")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_speed_single_clip_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_speed_single_clip_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Speed Single Clip Bounds",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      timeline: RecordingProject.TimelineModel(
        clips: [
          .init(sourceURL: movURL, sourceStartSeconds: 0.1, timelineStartSeconds: 0, durationSeconds: 0.25),
        ],
        speedSegments: [
          .init(startSeconds: 0, endSeconds: 0.25, rate: 2),
        ]
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Speed single clip bounds export expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    let asset = AVURLAsset(url: out)
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 0.25, accuracy: 0.16)
  }

  func testExporterProducesNonEmptyMp4WithWindowStageLayout() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeStage")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_stage_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_stage_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Stage",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings.defaulted(forSourceKind: .window)
    )

    XCTAssertNotEqual(project.exportVisualSettings.stageStyle, .none)

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }

    guard case let .finished(out) = terminalState else {
      XCTFail("Stage export expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    let size = (
      try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64
    ) ?? 0
    XCTAssertGreaterThan(size, 2_048, "Window stage export MP4 unusually small.")
  }

  func testExporterRendersWindowStageCornerWithoutBlackFringe() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeWindowCorner")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_window_corner_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_window_corner_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .roundedCard,
      backgroundKind: .solid,
      backgroundColorHex: "#5EEAD4",
      gradientEndColorHex: "#5EEAD4",
      backgroundBlur: 0,
      backgroundPadding: 48,
      contentCornerRadius: 24,
      contentInset: 0,
      dropShadowOpacity: 0,
      shadowRadius: 0,
      shadowYOffset: 0,
      enabledForDisplayCapture: true
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Window Corner",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Window corner export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.2, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let sourceSize = CGSize(
      width: ExportSmokeFixtureConstants.pixelWidth,
      height: ExportSmokeFixtureConstants.pixelHeight
    )
    let geometry = ArcShotRenderGeometry.make(
      stageSize: renderSize,
      contentAspectRatio: sourceSize.width / sourceSize.height,
      padding: CGFloat(visualSettings.backgroundPadding),
      contentInset: 0,
      cornerRadius: CGFloat(visualSettings.contentCornerRadius),
      sourceKind: .window,
      sourceVideoSize: sourceSize
    )
    let cornerRect = CGRect(
      x: geometry.contentRect.pixelAligned.minX + 3,
      y: geometry.contentRect.pixelAligned.minY + 3,
      width: 12,
      height: 12
    )
    let topRightRect = CGRect(
      x: geometry.contentRect.pixelAligned.maxX - 15,
      y: geometry.contentRect.pixelAligned.minY + 3,
      width: 12,
      height: 12
    )
    let centerRect = CGRect(
      x: geometry.contentRect.midX - 12,
      y: geometry.contentRect.midY - 12,
      width: 24,
      height: 24
    )
    let cornerRGB = try averageRGB(in: cgImage, rect: cornerRect)
    let topRightRGB = try averageRGB(in: cgImage, rect: topRightRect)
    let centerRGB = try averageRGB(in: cgImage, rect: centerRect)
    let diagnostic =
      "renderSize=\(renderSize) visualRadius=\(geometry.sourceCornerRadius) exportClipRadius=\(geometry.windowExportClipRadius ?? -1) cornerRect=\(cornerRect) topRightRect=\(topRightRect) cornerRGB=\(cornerRGB) topRightRGB=\(topRightRGB) centerRGB=\(centerRGB)"

    XCTAssertLessThan(
      centerRGB.luminance,
      35,
      "Center sample should remain inside the black source video. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      cornerRGB.luminance,
      centerRGB.luminance + 55,
      "Window export top-left corner wedge should reveal stage background instead of black fringe. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      topRightRGB.luminance,
      centerRGB.luminance + 55,
      "Window export top-right corner wedge should reveal stage background instead of black fringe. \(diagnostic)"
    )
    XCTAssertGreaterThanOrEqual(
      geometry.windowExportClipRadius ?? geometry.sourceCornerRadius,
      geometry.sourceCornerRadius,
      "Export clip radius should never be smaller than the macOS visual radius. \(diagnostic)"
    )
  }

  func testExporterRendersNonWindowStageCardShadowPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeStageShadow")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_stage_shadow_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_stage_shadow_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .roundedCard,
      backgroundKind: .solid,
      backgroundColorHex: "#F4F4F4",
      gradientEndColorHex: "#F4F4F4",
      backgroundBlur: 0,
      backgroundPadding: 48,
      contentCornerRadius: 24,
      contentInset: 0,
      dropShadowOpacity: 1,
      shadowRadius: 36,
      shadowYOffset: 24,
      enabledForDisplayCapture: true
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Stage Shadow",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Stage shadow export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.2, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let geometry = ArcShotRenderGeometry.make(
      stageSize: renderSize,
      contentAspectRatio: renderSize.width / renderSize.height,
      padding: CGFloat(visualSettings.backgroundPadding),
      contentInset: 0,
      cornerRadius: CGFloat(visualSettings.contentCornerRadius),
      sourceKind: .display
    )
    let bandWidth = min(360, max(40, geometry.cardRect.width * 0.32))
    let bandHeight: CGFloat = 12
    let bandX = geometry.cardRect.midX - bandWidth / 2
    let shadowY = max(2, geometry.cardRect.minY - 24)
    let referenceY = min(renderSize.height - bandHeight - 2, geometry.cardRect.maxY + 8)
    let shadowLuminance = try averageLuminance(
      in: cgImage,
      rect: CGRect(x: bandX, y: shadowY, width: bandWidth, height: bandHeight)
    )
    let shadowRect = CGRect(x: bandX, y: shadowY, width: bandWidth, height: bandHeight)
    let backgroundLuminance = try averageLuminance(
      in: cgImage,
      rect: CGRect(x: bandX, y: referenceY, width: bandWidth, height: bandHeight)
    )
    let backgroundRect = CGRect(x: bandX, y: referenceY, width: bandWidth, height: bandHeight)
    let diagnostic = "renderSize=\(renderSize) cardRect=\(geometry.cardRect) shadowRect=\(shadowRect) backgroundRect=\(backgroundRect) shadowLuma=\(shadowLuminance) backgroundLuma=\(backgroundLuminance)"

    XCTAssertGreaterThan(backgroundLuminance, 220, "Fixture background should remain bright. \(diagnostic)")
    XCTAssertGreaterThan(shadowLuminance, 35, "Shadow sample should not land inside the black video card. \(diagnostic)")
    XCTAssertLessThan(
      shadowLuminance,
      backgroundLuminance - 18,
      "Card shadow should darken pixels below the non-window stage card. \(diagnostic)"
    )
  }

  func testExporterSuppressesExtraStageCardShadowForWindowCaptures() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeWindowStageShadow")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_window_stage_shadow_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_window_stage_shadow_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .roundedCard,
      backgroundKind: .solid,
      backgroundColorHex: "#F4F4F4",
      gradientEndColorHex: "#F4F4F4",
      backgroundBlur: 0,
      backgroundPadding: 48,
      contentCornerRadius: 24,
      contentInset: 0,
      dropShadowOpacity: 1,
      shadowRadius: 36,
      shadowYOffset: 24,
      enabledForDisplayCapture: true
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Window Stage Shadow",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Window stage shadow export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.2, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let sourceSize = CGSize(
      width: ExportSmokeFixtureConstants.pixelWidth,
      height: ExportSmokeFixtureConstants.pixelHeight
    )
    let geometry = ArcShotRenderGeometry.make(
      stageSize: renderSize,
      contentAspectRatio: sourceSize.width / sourceSize.height,
      padding: CGFloat(visualSettings.backgroundPadding),
      contentInset: 0,
      cornerRadius: CGFloat(visualSettings.contentCornerRadius),
      sourceKind: .window,
      sourceVideoSize: sourceSize
    )
    let bandWidth = min(360, max(40, geometry.cardRect.width * 0.32))
    let bandHeight: CGFloat = 12
    let bandX = geometry.cardRect.midX - bandWidth / 2
    let belowY = max(2, geometry.cardRect.minY - 24)
    let referenceY = min(renderSize.height - bandHeight - 2, geometry.cardRect.maxY + 8)
    let belowLuminance = try averageLuminance(
      in: cgImage,
      rect: CGRect(x: bandX, y: belowY, width: bandWidth, height: bandHeight)
    )
    let belowRect = CGRect(x: bandX, y: belowY, width: bandWidth, height: bandHeight)
    let referenceLuminance = try averageLuminance(
      in: cgImage,
      rect: CGRect(x: bandX, y: referenceY, width: bandWidth, height: bandHeight)
    )
    let referenceRect = CGRect(x: bandX, y: referenceY, width: bandWidth, height: bandHeight)
    let diagnostic = "renderSize=\(renderSize) cardRect=\(geometry.cardRect) belowRect=\(belowRect) referenceRect=\(referenceRect) belowLuma=\(belowLuminance) referenceLuma=\(referenceLuminance)"

    XCTAssertGreaterThan(referenceLuminance, 220, "Fixture background should remain bright. \(diagnostic)")
    XCTAssertGreaterThan(belowLuminance, 220, "Window stage should not darken the below-card background. \(diagnostic)")
    XCTAssertLessThan(
      abs(referenceLuminance - belowLuminance),
      10,
      "Window captures should suppress the extra stage card shadow. \(diagnostic)"
    )
  }

  func testExporterRendersStageGradientAndRoundedClipPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeStageGradientClip")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_stage_gradient_clip_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_stage_gradient_clip_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .roundedCard,
      backgroundKind: .linearGradientVertical,
      backgroundColorHex: "#F03A6A",
      gradientEndColorHex: "#22C55E",
      backgroundBlur: 0,
      backgroundPadding: 96,
      contentCornerRadius: 48,
      contentInset: 0,
      dropShadowOpacity: 0,
      shadowRadius: 0,
      shadowYOffset: 0,
      enabledForDisplayCapture: true
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Stage Gradient Clip",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Stage gradient/clip export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.2, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let geometry = ArcShotRenderGeometry.make(
      stageSize: renderSize,
      contentAspectRatio: renderSize.width / renderSize.height,
      padding: CGFloat(visualSettings.backgroundPadding),
      contentInset: 0,
      cornerRadius: CGFloat(visualSettings.contentCornerRadius),
      sourceKind: .display
    )
    XCTAssertEqual(geometry.sourceCornerRadius, 0, accuracy: 0.01)
    let bandSize = CGSize(width: 56, height: 16)
    let margin: CGFloat = 18
    let topBackgroundRect = CGRect(
      x: margin,
      y: renderSize.height - margin - bandSize.height,
      width: bandSize.width,
      height: bandSize.height
    )
    let bottomBackgroundRect = CGRect(
      x: margin,
      y: margin,
      width: bandSize.width,
      height: bandSize.height
    )
    let centerRect = CGRect(
      x: geometry.contentRect.midX - 12,
      y: geometry.contentRect.midY - 12,
      width: 24,
      height: 24
    )

    let topBackground = try averageRGB(in: cgImage, rect: topBackgroundRect)
    let bottomBackground = try averageRGB(in: cgImage, rect: bottomBackgroundRect)
    let contentCenter = try averageRGB(in: cgImage, rect: centerRect)
    let diagnostic = "renderSize=\(renderSize) cardRect=\(geometry.cardRect) contentRect=\(geometry.contentRect) topRect=\(topBackgroundRect) bottomRect=\(bottomBackgroundRect) centerRect=\(centerRect) topRGB=\(topBackground) bottomRGB=\(bottomBackground) centerRGB=\(contentCenter)"

    XCTAssertGreaterThan(
      topBackground.red,
      topBackground.green + 35,
      "Top background sample should keep the gradient start color. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      bottomBackground.green,
      bottomBackground.red + 35,
      "Bottom background sample should keep the gradient end color. \(diagnostic)"
    )
    XCTAssertLessThan(
      contentCenter.luminance,
      35,
      "Center sample should remain inside the black source video. \(diagnostic)"
    )
  }

  func testExporterDensifiesSparseCursorSamplesIntoRenderedMiddlePosition() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeSparseCursor")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_sparse_cursor_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_sparse_cursor_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .none,
      backgroundKind: .solid,
      backgroundColorHex: "#000000",
      gradientEndColorHex: "#000000",
      backgroundBlur: 0,
      backgroundPadding: 0,
      contentCornerRadius: 0,
      contentInset: 0,
      dropShadowOpacity: 0,
      shadowRadius: 0,
      shadowYOffset: 0,
      enabledForDisplayCapture: true
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Sparse Cursor",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [
        .init(timeSeconds: 0, x: 0.2, y: 0.5, shape: .arrow),
        .init(timeSeconds: 0.6, x: 0.8, y: 0.5, shape: .arrow),
      ],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings,
      zoomSegments: [
        RecordingProject.ZoomSegment(
          startSeconds: 0.25,
          inEndSeconds: 0.26,
          outStartSeconds: 0.34,
          endSeconds: 0.35,
          instantAnimation: true,
          scale: 1.2,
          anchorX: 0.5,
          anchorY: 0.5
        ),
      ],
      cursorVisualSettings: .init(
        isVisible: true,
        pointerStyle: .dot,
        sizeScale: 3,
        hideWhenIdle: false,
        showClickEffects: false,
        showKeyboardShortcuts: false
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Sparse cursor export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.3, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let sourceAspect = CGFloat(ExportSmokeFixtureConstants.pixelWidth) /
      CGFloat(ExportSmokeFixtureConstants.pixelHeight)
    let contentHeight = renderSize.height
    let contentWidth = min(renderSize.width, contentHeight * sourceAspect)
    let contentOriginX = (renderSize.width - contentWidth) / 2
    func cursorPoint(x: CGFloat) -> CGPoint {
      CGPoint(
        x: contentOriginX + contentWidth * x,
        y: renderSize.height / 2
      )
    }
    func probeRect(around point: CGPoint) -> CGRect {
      CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
    }

    let startRect = probeRect(around: cursorPoint(x: 0.2))
    let middleRect = probeRect(around: cursorPoint(x: 0.5))
    let endRect = probeRect(around: cursorPoint(x: 0.8))

    let startLuminance = try maximumLuminance(in: cgImage, rect: startRect)
    let middleLuminance = try maximumLuminance(in: cgImage, rect: middleRect)
    let endLuminance = try maximumLuminance(in: cgImage, rect: endRect)
    let diagnostic = "renderSize=\(renderSize) startRect=\(startRect) middleRect=\(middleRect) endRect=\(endRect) startLuma=\(startLuminance) middleLuma=\(middleLuminance) endLuma=\(endLuminance)"

    XCTAssertLessThan(startLuminance, 18, "Start cursor region should be near black at the middle frame. \(diagnostic)")
    XCTAssertLessThan(endLuminance, 18, "End cursor region should be near black at the middle frame. \(diagnostic)")
    XCTAssertGreaterThan(
      middleLuminance,
      max(startLuminance, endLuminance) + 120,
      "Sparse cursor samples should render a densified/interpolated cursor at the middle position. \(diagnostic)"
    )
  }

  func testExporterRendersClickPulsePixelsAfterClick() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeClickPulse")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_click_pulse_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_click_pulse_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .none,
      backgroundKind: .solid,
      backgroundColorHex: "#000000",
      gradientEndColorHex: "#000000",
      backgroundBlur: 0,
      backgroundPadding: 0,
      contentCornerRadius: 0,
      contentInset: 0,
      dropShadowOpacity: 0,
      shadowRadius: 0,
      shadowYOffset: 0,
      enabledForDisplayCapture: true
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Click Pulse",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [
        .init(timeSeconds: 0, x: 0.5, y: 0.5, shape: .arrow),
        .init(timeSeconds: 0.4, x: 0.5, y: 0.5, shape: .arrow),
      ],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings,
      cursorClickCues: [
        .init(timeSeconds: 0.05),
      ],
      cursorVisualSettings: .init(
        isVisible: true,
        pointerStyle: .dot,
        sizeScale: 3,
        hideWhenIdle: false,
        showClickEffects: true,
        showKeyboardShortcuts: false
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Click pulse export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.16, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
    let pulseRect = CGRect(
      x: center.x + 24,
      y: center.y - 80,
      width: 78,
      height: 160
    )
    let referenceRect = CGRect(
      x: center.x + 126,
      y: center.y - 80,
      width: 48,
      height: 160
    )
    let pulseLuminance = try maximumLuminance(in: cgImage, rect: pulseRect)
    let referenceLuminance = try maximumLuminance(in: cgImage, rect: referenceRect)
    let diagnostic = "renderSize=\(renderSize) pulseRect=\(pulseRect) referenceRect=\(referenceRect) pulseLuma=\(pulseLuminance) referenceLuma=\(referenceLuminance)"

    XCTAssertLessThan(referenceLuminance, 18, "Reference region should remain near black. \(diagnostic)")
    XCTAssertGreaterThan(
      pulseLuminance,
      referenceLuminance + 36,
      "Click pulse should brighten the post-click ring region in the exported frame. \(diagnostic)"
    )
  }

  func testExporterRendersKeyboardShortcutOverlayPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeKeyboardShortcut")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_keyboard_shortcut_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_keyboard_shortcut_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Keyboard Shortcut",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      inputEvents: [
        .init(
          timeSeconds: 0.12,
          kind: .keyDown,
          characters: "k",
          modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.command.rawValue)
        ),
      ],
      cursorVisualSettings: .init(
        isVisible: false,
        pointerStyle: .dot,
        sizeScale: 1,
        hideWhenIdle: false,
        showClickEffects: false,
        showKeyboardShortcuts: true
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Keyboard shortcut export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.32, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let overlayRect = ExportVideoGeometry.textOverlayRenderRect(
      originXN: 0.34,
      originYN: 0.06,
      widthN: 0.32,
      heightN: 0.075,
      renderSize: renderSize
    )
    let textProbeRect = overlayRect.insetBy(dx: overlayRect.width * 0.18, dy: overlayRect.height * 0.18)
    let referenceRect = CGRect(
      x: overlayRect.minX,
      y: overlayRect.minY - overlayRect.height - 24,
      width: overlayRect.width,
      height: overlayRect.height
    )
    let textLuminance = try maximumLuminance(in: cgImage, rect: textProbeRect)
    let referenceLuminance = try maximumLuminance(in: cgImage, rect: referenceRect)
    let diagnostic = "renderSize=\(renderSize) overlayRect=\(overlayRect) textProbeRect=\(textProbeRect) referenceRect=\(referenceRect) textLuma=\(textLuminance) referenceLuma=\(referenceLuminance)"

    XCTAssertLessThan(referenceLuminance, 18, "Reference region should remain near black. \(diagnostic)")
    XCTAssertGreaterThan(
      textLuminance,
      referenceLuminance + 120,
      "Keyboard shortcut overlay should render bright text pixels in the exported frame. \(diagnostic)"
    )
  }

  func testExporterRendersWrappedTextOverlayPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeWrappedTextOverlay")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_wrapped_text_overlay_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_wrapped_text_overlay_out.mp4")

    try ExportSmokeFixtureMaker.writeVerticalStripeVideoMOV(to: movURL)

    let overlay = RecordingProject.TextOverlayAnnotation(
      startSeconds: 0.08,
      endSeconds: 0.62,
      text: "A wrapped caption overlay proves exported CoreText draws multiple readable lines.",
      originXN: 0.24,
      originYN: 0.58,
      widthN: 0.34,
      heightN: 0.22,
      fontPointSize: 28
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Wrapped Text Overlay",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      textOverlayAnnotations: [overlay],
      captionTrack: RecordingProject.CaptionTrack(isEnabled: false),
      cursorVisualSettings: .init(
        isVisible: false,
        pointerStyle: .dot,
        sizeScale: 1,
        hideWhenIdle: false,
        showClickEffects: false,
        showKeyboardShortcuts: false
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Wrapped text overlay export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.32, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let overlayRect = ExportVideoGeometry.textOverlayRenderRect(
      originXN: overlay.originXN,
      originYN: overlay.originYN,
      widthN: overlay.widthN,
      heightN: overlay.heightN,
      renderSize: renderSize
    )
    let textInset = max(8, CGFloat(overlay.fontPointSize) * 0.35)
    let textRect = overlayRect.insetBy(dx: textInset, dy: textInset * 0.55)
    let upperLineProbeRect = CGRect(
      x: textRect.minX + textRect.width * 0.08,
      y: textRect.midY,
      width: textRect.width * 0.84,
      height: textRect.height * 0.42
    )
    let lowerLineProbeRect = CGRect(
      x: textRect.minX + textRect.width * 0.08,
      y: textRect.minY,
      width: textRect.width * 0.84,
      height: textRect.height * 0.42
    )
    let backgroundProbeRect = CGRect(
      x: overlayRect.minX + 4,
      y: overlayRect.midY - overlayRect.height * 0.20,
      width: 6,
      height: overlayRect.height * 0.40
    )
    let backgroundReferenceRect = CGRect(
      x: backgroundProbeRect.minX,
      y: overlayRect.maxY + 24,
      width: backgroundProbeRect.width,
      height: backgroundProbeRect.height
    )
    let upperTextLuminance = try maximumLuminance(in: cgImage, rect: upperLineProbeRect)
    let lowerTextLuminance = try maximumLuminance(in: cgImage, rect: lowerLineProbeRect)
    let overlayBackgroundLuminance = try averageLuminance(in: cgImage, rect: backgroundProbeRect)
    let referenceLuminance = try averageLuminance(in: cgImage, rect: backgroundReferenceRect)
    let diagnostic = "renderSize=\(renderSize) overlayRect=\(overlayRect) textRect=\(textRect) upperLineProbeRect=\(upperLineProbeRect) lowerLineProbeRect=\(lowerLineProbeRect) backgroundProbeRect=\(backgroundProbeRect) backgroundReferenceRect=\(backgroundReferenceRect) upperTextLuma=\(upperTextLuminance) lowerTextLuma=\(lowerTextLuminance) overlayBackgroundLuma=\(overlayBackgroundLuminance) referenceLuma=\(referenceLuminance)"

    XCTAssertGreaterThan(
      upperTextLuminance,
      210,
      "Wrapped text overlay should render bright pixels on an upper line. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      lowerTextLuminance,
      210,
      "Wrapped text overlay should render bright pixels on a lower wrapped line. \(diagnostic)"
    )
    XCTAssertLessThan(
      overlayBackgroundLuminance,
      referenceLuminance - 24,
      "Text overlay should draw a dark rounded background over the source video. \(diagnostic)"
    )
  }

  func testExporterRendersCaptionTrackOverlayPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeCaptionTrackOverlay")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_caption_track_overlay_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_caption_track_overlay_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let captionTrack = RecordingProject.CaptionTrack(
      isEnabled: true,
      segments: [
        .init(
          startSeconds: 0.08,
          endSeconds: 0.62,
          text: "Caption track text reaches export"
        ),
      ],
      style: .init(fontPointSize: 34, bottomInsetN: 0.08, backgroundOpacity: 0.35)
    )
    let captionOverlay = try XCTUnwrap(captionTrack.asTextOverlays().first)
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Caption Track Overlay",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      textOverlayAnnotations: [],
      captionTrack: captionTrack,
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Caption track overlay export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.32, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let overlayRect = ExportVideoGeometry.textOverlayRenderRect(
      originXN: captionOverlay.originXN,
      originYN: captionOverlay.originYN,
      widthN: captionOverlay.widthN,
      heightN: captionOverlay.heightN,
      renderSize: renderSize
    )
    let textInset = max(8, CGFloat(captionOverlay.fontPointSize) * 0.35)
    let textProbeRect = overlayRect
      .insetBy(dx: overlayRect.width * 0.20, dy: textInset * 0.55)
    let referenceRect = CGRect(
      x: textProbeRect.minX,
      y: min(renderSize.height - textProbeRect.height - 2, overlayRect.maxY + 24),
      width: textProbeRect.width,
      height: textProbeRect.height
    )
    let textLuminance = try maximumLuminance(in: cgImage, rect: textProbeRect)
    let referenceLuminance = try maximumLuminance(in: cgImage, rect: referenceRect)
    let diagnostic = "renderSize=\(renderSize) overlayRect=\(overlayRect) textProbeRect=\(textProbeRect) referenceRect=\(referenceRect) textLuma=\(textLuminance) referenceLuma=\(referenceLuminance)"

    XCTAssertLessThan(referenceLuminance, 18, "Reference region should remain near black. \(diagnostic)")
    XCTAssertGreaterThan(
      textLuminance,
      referenceLuminance + 120,
      "CaptionTrack.asTextOverlays() text should render bright pixels in the exported frame. \(diagnostic)"
    )
  }

  func testExporterRendersIntroOutroFadePixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeFade")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_fade_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_fade_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBrightVideoMOV(to: movURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Fade",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(introFadeSeconds: 0.2, outroFadeSeconds: 0.2),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      captionTrack: RecordingProject.CaptionTrack(isEnabled: false),
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Fade export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero

    let introImage = try await imageGenerator.image(at: CMTime(value: 1, timescale: 30)).image
    let middleImage = try await imageGenerator.image(at: CMTime(value: 12, timescale: 30)).image
    let outroImage = try await imageGenerator.image(at: CMTime(value: 23, timescale: 30)).image

    let renderSize = CGSize(width: middleImage.width, height: middleImage.height)
    let probeRect = CGRect(
      x: renderSize.width * 0.45,
      y: renderSize.height * 0.45,
      width: renderSize.width * 0.10,
      height: renderSize.height * 0.10
    )
    let introLuminance = try averageLuminance(in: introImage, rect: probeRect)
    let middleLuminance = try averageLuminance(in: middleImage, rect: probeRect)
    let outroLuminance = try averageLuminance(in: outroImage, rect: probeRect)
    let diagnostic = "renderSize=\(renderSize) probeRect=\(probeRect) introLuma=\(introLuminance) middleLuma=\(middleLuminance) outroLuma=\(outroLuminance)"

    XCTAssertGreaterThan(
      middleLuminance,
      190,
      "Middle frame outside intro/outro fades should keep the bright source video. \(diagnostic)"
    )
    XCTAssertLessThan(
      introLuminance,
      middleLuminance - 120,
      "Intro fade should darken an early exported frame. \(diagnostic)"
    )
    XCTAssertLessThan(
      outroLuminance,
      middleLuminance - 120,
      "Outro fade should darken a late exported frame. \(diagnostic)"
    )
  }

  func testExporterRendersMirroredRoundedCameraPiPPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeCameraPiP")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_pip_main_in.mov")
    let cameraURL = root.appendingPathComponent("fixture_pip_camera_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_pip_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeAsymmetricCameraVideoMOV(to: cameraURL)

    let pipSegment = RecordingProject.CameraLayoutSegment(
      startSeconds: 0,
      endSeconds: 0.72,
      layout: .pip,
      originXN: 0.25,
      originYN: 0.25,
      widthN: 0.40,
      heightN: 0.30,
      cornerRadiusPts: 56,
      isMirrored: true,
      shrinkDuringZoom: false
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Camera PiP",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      secondaryRecording: .init(
        mediaURL: cameraURL,
        originXN: pipSegment.originXN,
        originYN: pipSegment.originYN,
        widthN: pipSegment.widthN,
        heightN: pipSegment.heightN,
        cornerRadiusPts: pipSegment.cornerRadiusPts
      ),
      captionTrack: RecordingProject.CaptionTrack(isEnabled: false),
      cameraLayoutSegments: [pipSegment],
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Camera PiP export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = CMTime.zero
    imageGenerator.requestedTimeToleranceAfter = CMTime.zero

    let cgImage = try await imageGenerator.image(at: CMTime(value: 12, timescale: 30)).image
    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let pipRect = exportSmokeTopDownPiPRect(
      originXN: pipSegment.originXN,
      originYN: pipSegment.originYN,
      widthN: pipSegment.widthN,
      heightN: pipSegment.heightN,
      renderSize: renderSize
    )
    let probeSize = CGSize(width: 28, height: 28)
    let leftProbe = CGRect(
      x: pipRect.minX + pipRect.width * 0.18,
      y: pipRect.midY - probeSize.height / 2,
      width: probeSize.width,
      height: probeSize.height
    )
    let rightProbe = CGRect(
      x: pipRect.maxX - pipRect.width * 0.18 - probeSize.width,
      y: pipRect.midY - probeSize.height / 2,
      width: probeSize.width,
      height: probeSize.height
    )
    let roundedCornerProbes = [
      CGRect(x: pipRect.minX + 2, y: pipRect.minY + 2, width: 10, height: 10),
      CGRect(x: pipRect.maxX - 12, y: pipRect.minY + 2, width: 10, height: 10),
      CGRect(x: pipRect.minX + 2, y: pipRect.maxY - 12, width: 10, height: 10),
      CGRect(x: pipRect.maxX - 12, y: pipRect.maxY - 12, width: 10, height: 10),
    ]
    let outsideProbe = CGRect(
      x: max(0, pipRect.minX - 56),
      y: pipRect.midY - probeSize.height / 2,
      width: probeSize.width,
      height: probeSize.height
    )

    let leftColor = try averageRGB(in: cgImage, rect: leftProbe)
    let rightColor = try averageRGB(in: cgImage, rect: rightProbe)
    let roundedCornerLuminances = try roundedCornerProbes.map { try averageLuminance(in: cgImage, rect: $0) }
    let clippedCornerLuminance = try XCTUnwrap(roundedCornerLuminances.min())
    let outsideLuminance = try averageLuminance(in: cgImage, rect: outsideProbe)
    let diagnostic = "renderSize=\(renderSize) pipRect=\(pipRect) left=\(leftColor) right=\(rightColor) roundedCornerLumas=\(roundedCornerLuminances) outsideLuma=\(outsideLuminance)"

    XCTAssertGreaterThan(
      leftColor.green,
      leftColor.red + 80,
      "Mirrored PiP should place the source's green right half on the exported PiP left side. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      rightColor.red,
      rightColor.green + 80,
      "Mirrored PiP should place the source's red left half on the exported PiP right side. \(diagnostic)"
    )
    XCTAssertLessThan(
      outsideLuminance,
      18,
      "Pixels outside the PiP rect should keep the black main source. \(diagnostic)"
    )
    XCTAssertLessThan(
      clippedCornerLuminance,
      24,
      "Rounded PiP clipping should keep at least one extreme rect corner near black. \(diagnostic)"
    )
  }

  func testExporterRendersCameraPiPPlaybackFramesOverTime() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeCameraPiPTemporal")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_pip_temporal_main_in.mov")
    let cameraURL = root.appendingPathComponent("fixture_pip_temporal_camera_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_pip_temporal_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeTemporalCameraVideoMOV(to: cameraURL)

    let pipSegment = RecordingProject.CameraLayoutSegment(
      startSeconds: 0,
      endSeconds: 0.8,
      layout: .pip,
      originXN: 0.30,
      originYN: 0.25,
      widthN: 0.40,
      heightN: 0.30,
      cornerRadiusPts: 0,
      isMirrored: false,
      shrinkDuringZoom: false
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Camera PiP Temporal Playback",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      secondaryRecording: .init(
        mediaURL: cameraURL,
        originXN: pipSegment.originXN,
        originYN: pipSegment.originYN,
        widthN: pipSegment.widthN,
        heightN: pipSegment.heightN,
        cornerRadiusPts: pipSegment.cornerRadiusPts
      ),
      captionTrack: RecordingProject.CaptionTrack(isEnabled: false),
      cameraLayoutSegments: [pipSegment],
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Camera PiP temporal playback export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = CMTime.zero
    imageGenerator.requestedTimeToleranceAfter = CMTime.zero

    let earlyImage = try await imageGenerator.image(at: CMTime(value: 5, timescale: 30)).image
    let lateImage = try await imageGenerator.image(at: CMTime(value: 19, timescale: 30)).image
    let renderSize = CGSize(width: earlyImage.width, height: earlyImage.height)
    let pipRect = exportSmokeTopDownPiPRect(
      originXN: pipSegment.originXN,
      originYN: pipSegment.originYN,
      widthN: pipSegment.widthN,
      heightN: pipSegment.heightN,
      renderSize: renderSize
    )
    let probeSize = CGSize(width: 40, height: 40)
    let centerProbe = CGRect(
      x: pipRect.midX - probeSize.width / 2,
      y: pipRect.midY - probeSize.height / 2,
      width: probeSize.width,
      height: probeSize.height
    )

    let earlyColor = try averageRGB(in: earlyImage, rect: centerProbe)
    let lateColor = try averageRGB(in: lateImage, rect: centerProbe)
    let diagnostic = "renderSize=\(renderSize) pipRect=\(pipRect) centerProbe=\(centerProbe) early=\(earlyColor) late=\(lateColor)"

    XCTAssertGreaterThan(
      earlyColor.red,
      earlyColor.green + 80,
      "Early PiP frame should use the temporal camera source's red first-half frames. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      earlyColor.red,
      earlyColor.blue + 80,
      "Early PiP frame should be red-dominant rather than neutral or black. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      lateColor.green,
      lateColor.red + 80,
      "Late PiP frame should use the temporal camera source's green second-half frames. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      lateColor.green,
      lateColor.blue + 80,
      "Late PiP frame should be green-dominant rather than neutral or black. \(diagnostic)"
    )
  }

  func testExporterRendersCameraPiPTimelineSpeedMappedFramesOverTime() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeCameraPiPSpeedTemporal")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_pip_speed_temporal_main_in.mov")
    let cameraURL = root.appendingPathComponent("fixture_pip_speed_temporal_camera_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_pip_speed_temporal_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeTemporalCameraVideoMOV(to: cameraURL)

    let pipSegment = RecordingProject.CameraLayoutSegment(
      startSeconds: 0,
      endSeconds: 0.4,
      layout: .pip,
      originXN: 0.30,
      originYN: 0.25,
      widthN: 0.40,
      heightN: 0.30,
      cornerRadiusPts: 0,
      isMirrored: false,
      shrinkDuringZoom: false
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Camera PiP Timeline Speed Playback",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      secondaryRecording: .init(
        mediaURL: cameraURL,
        originXN: pipSegment.originXN,
        originYN: pipSegment.originYN,
        widthN: pipSegment.widthN,
        heightN: pipSegment.heightN,
        cornerRadiusPts: pipSegment.cornerRadiusPts
      ),
      timeline: RecordingProject.TimelineModel(
        clips: [
          .init(sourceURL: movURL, sourceStartSeconds: 0, timelineStartSeconds: 0, durationSeconds: 0.4),
        ],
        speedSegments: [
          .init(startSeconds: 0, endSeconds: 0.4, rate: 2),
        ]
      ),
      captionTrack: RecordingProject.CaptionTrack(isEnabled: false),
      cameraLayoutSegments: [pipSegment],
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Camera PiP timeline-speed playback export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = CMTime.zero
    imageGenerator.requestedTimeToleranceAfter = CMTime.zero

    let earlyImage = try await imageGenerator.image(at: CMTime(value: 3, timescale: 30)).image
    let lateImage = try await imageGenerator.image(at: CMTime(value: 9, timescale: 30)).image
    let renderSize = CGSize(width: earlyImage.width, height: earlyImage.height)
    let pipRect = exportSmokeTopDownPiPRect(
      originXN: pipSegment.originXN,
      originYN: pipSegment.originYN,
      widthN: pipSegment.widthN,
      heightN: pipSegment.heightN,
      renderSize: renderSize
    )
    let probeSize = CGSize(width: 40, height: 40)
    let centerProbe = CGRect(
      x: pipRect.midX - probeSize.width / 2,
      y: pipRect.midY - probeSize.height / 2,
      width: probeSize.width,
      height: probeSize.height
    )

    let earlyColor = try averageRGB(in: earlyImage, rect: centerProbe)
    let lateColor = try averageRGB(in: lateImage, rect: centerProbe)
    let diagnostic = "renderSize=\(renderSize) pipRect=\(pipRect) centerProbe=\(centerProbe) early=\(earlyColor) late=\(lateColor)"

    XCTAssertGreaterThan(
      earlyColor.red,
      earlyColor.green + 80,
      "Early speed-mapped PiP frame should still use the temporal camera source's red first-half frames. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      earlyColor.red,
      earlyColor.blue + 80,
      "Early speed-mapped PiP frame should be red-dominant rather than neutral or black. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      lateColor.green,
      lateColor.red + 80,
      "Late speed-mapped PiP frame should reach the temporal camera source's green second-half frames by 0.30s at 2x. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      lateColor.green,
      lateColor.blue + 80,
      "Late speed-mapped PiP frame should be green-dominant rather than neutral or black. \(diagnostic)"
    )
  }

  func testExporterRendersCameraPiPAspectFillCropPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeCameraPiPAspectFill")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_pip_aspect_fill_main_in.mov")
    let cameraURL = root.appendingPathComponent("fixture_pip_aspect_fill_camera_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_pip_aspect_fill_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeCameraAspectFillBandsVideoMOV(to: cameraURL)

    let pipSegment = RecordingProject.CameraLayoutSegment(
      startSeconds: 0,
      endSeconds: 0.72,
      layout: .pip,
      originXN: 0.25,
      originYN: 0.25,
      widthN: 0.40,
      heightN: 0.30,
      cornerRadiusPts: 0,
      isMirrored: false,
      shrinkDuringZoom: false
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Camera PiP Aspect Fill",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings(
        stageStyle: .none,
        backgroundKind: .solid,
        backgroundColorHex: "#000000",
        gradientEndColorHex: "#000000",
        backgroundBlur: 0,
        backgroundPadding: 0,
        contentCornerRadius: 0,
        contentInset: 0,
        dropShadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        enabledForDisplayCapture: true
      ),
      secondaryRecording: .init(
        mediaURL: cameraURL,
        originXN: pipSegment.originXN,
        originYN: pipSegment.originYN,
        widthN: pipSegment.widthN,
        heightN: pipSegment.heightN,
        cornerRadiusPts: pipSegment.cornerRadiusPts
      ),
      captionTrack: RecordingProject.CaptionTrack(isEnabled: false),
      cameraLayoutSegments: [pipSegment],
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Camera PiP aspect-fill export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = CMTime.zero
    imageGenerator.requestedTimeToleranceAfter = CMTime.zero

    let cgImage = try await imageGenerator.image(at: CMTime(value: 12, timescale: 30)).image
    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let pipRect = exportSmokeTopDownPiPRect(
      originXN: pipSegment.originXN,
      originYN: pipSegment.originYN,
      widthN: pipSegment.widthN,
      heightN: pipSegment.heightN,
      renderSize: renderSize
    )
    let probeSize = CGSize(width: 40, height: 24)
    let topProbe = CGRect(
      x: pipRect.midX - probeSize.width / 2,
      y: pipRect.minY + 24,
      width: probeSize.width,
      height: probeSize.height
    )
    let bottomProbe = CGRect(
      x: pipRect.midX - probeSize.width / 2,
      y: pipRect.maxY - 48,
      width: probeSize.width,
      height: probeSize.height
    )

    let topColor = try averageRGB(in: cgImage, rect: topProbe)
    let bottomColor = try averageRGB(in: cgImage, rect: bottomProbe)
    let diagnostic = "renderSize=\(renderSize) pipRect=\(pipRect) topProbe=\(topProbe) bottomProbe=\(bottomProbe) top=\(topColor) bottom=\(bottomColor)"

    XCTAssertGreaterThan(
      topColor.green,
      topColor.blue + 60,
      "Aspect-fill should crop away the camera source's blue top band near the exported PiP top edge. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      topColor.green,
      topColor.red + 60,
      "Aspect-fill should show the camera source's green middle band near the exported PiP top edge. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      bottomColor.green,
      bottomColor.red + 60,
      "Aspect-fill should crop away the camera source's red bottom band near the exported PiP bottom edge. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      bottomColor.green,
      bottomColor.blue + 60,
      "Aspect-fill should show the camera source's green middle band near the exported PiP bottom edge. \(diagnostic)"
    )
  }

  func testExporterRendersHighlightMaskPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeHighlightMask")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_highlight_mask_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_highlight_mask_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .none,
      backgroundKind: .solid,
      backgroundColorHex: "#000000",
      gradientEndColorHex: "#000000",
      backgroundBlur: 0,
      backgroundPadding: 0,
      contentCornerRadius: 0,
      contentInset: 0,
      dropShadowOpacity: 0,
      shadowRadius: 0,
      shadowYOffset: 0,
      enabledForDisplayCapture: true
    )
    let mask = RecordingProject.VisualMask(
      startSeconds: 0.05,
      endSeconds: 0.55,
      kind: .highlight,
      originXN: 0.24,
      originYN: 0.18,
      widthN: 0.52,
      heightN: 0.28,
      opacity: 1
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Highlight Mask",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings,
      visualMasks: [mask],
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Highlight mask export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.25, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let sourceSize = CGSize(
      width: ExportSmokeFixtureConstants.pixelWidth,
      height: ExportSmokeFixtureConstants.pixelHeight
    )
    let sourceTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )
    let maskRect = ExportVideoGeometry.maskRenderRect(
      originXN: mask.originXN,
      originYN: mask.originYN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize,
      sourceTransform: sourceTransform,
      renderSize: renderSize
    )
    let mirroredMaskRect = ExportVideoGeometry.maskRenderRect(
      originXN: mask.originXN,
      originYN: 1 - mask.originYN - mask.heightN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize,
      sourceTransform: sourceTransform,
      renderSize: renderSize
    )
    let fillProbeRect = maskRect.insetBy(dx: maskRect.width * 0.26, dy: maskRect.height * 0.34)
    let strokeProbeRect = CGRect(
      x: maskRect.minX + 18,
      y: maskRect.minY,
      width: max(1, maskRect.width - 36),
      height: 10
    )
    let mirroredProbeRect = mirroredMaskRect.insetBy(
      dx: mirroredMaskRect.width * 0.26,
      dy: mirroredMaskRect.height * 0.34
    )
    let referenceRect = CGRect(
      x: max(12, maskRect.minX - 120),
      y: maskRect.midY - 24,
      width: 72,
      height: 48
    )

    let fillRGB = try averageRGB(in: cgImage, rect: fillProbeRect)
    let referenceRGB = try averageRGB(in: cgImage, rect: referenceRect)
    let strokeLuminance = try maximumLuminance(in: cgImage, rect: strokeProbeRect)
    let fillLuminance = try maximumLuminance(in: cgImage, rect: fillProbeRect)
    let mirroredLuminance = try maximumLuminance(in: cgImage, rect: mirroredProbeRect)
    let referenceLuminance = try maximumLuminance(in: cgImage, rect: referenceRect)
    let diagnostic = "renderSize=\(renderSize) maskRect=\(maskRect) mirroredMaskRect=\(mirroredMaskRect) fillProbeRect=\(fillProbeRect) strokeProbeRect=\(strokeProbeRect) mirroredProbeRect=\(mirroredProbeRect) referenceRect=\(referenceRect) fillRGB=\(fillRGB) referenceRGB=\(referenceRGB) fillLuma=\(fillLuminance) strokeLuma=\(strokeLuminance) mirroredLuma=\(mirroredLuminance) referenceLuma=\(referenceLuminance)"

    XCTAssertLessThan(referenceRGB.luminance, 18, "Reference region should remain near black. \(diagnostic)")
    XCTAssertGreaterThan(
      fillRGB.luminance,
      referenceRGB.luminance + 8,
      "Highlight mask fill should brighten the exported frame. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      min(fillRGB.red, fillRGB.green),
      fillRGB.blue + 8,
      "Highlight mask fill should tint pixels yellow instead of neutral gray. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      strokeLuminance,
      fillLuminance + 80,
      "Highlight mask stroke should render brighter boundary pixels than the interior fill. \(diagnostic)"
    )
    XCTAssertLessThan(
      mirroredLuminance,
      referenceLuminance + 18,
      "Highlight mask should render at the top-left normalized position, not the vertically mirrored position. \(diagnostic)"
    )
  }

  func testExporterBlursMaskPixels() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeBlurMask")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_blur_mask_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_blur_mask_out.mp4")

    try ExportSmokeFixtureMaker.writeVerticalStripeVideoMOV(to: movURL, stripeWidth: 4)

    let visualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: .none,
      backgroundKind: .solid,
      backgroundColorHex: "#000000",
      gradientEndColorHex: "#000000",
      backgroundBlur: 0,
      backgroundPadding: 0,
      contentCornerRadius: 0,
      contentInset: 0,
      dropShadowOpacity: 0,
      shadowRadius: 0,
      shadowYOffset: 0,
      enabledForDisplayCapture: true
    )
    let mask = RecordingProject.VisualMask(
      startSeconds: 0.05,
      endSeconds: 0.55,
      kind: .blur,
      originXN: 0.16,
      originYN: 0.13,
      widthN: 0.37,
      heightN: 0.31,
      opacity: 1
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Blur Mask",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: visualSettings,
      visualMasks: [mask],
      cursorVisualSettings: .init(isVisible: false)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Blur mask export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let cgImage = try await imageGenerator.image(
      at: CMTime(seconds: 0.25, preferredTimescale: 600)
    ).image

    let renderSize = CGSize(width: cgImage.width, height: cgImage.height)
    let sourceSize = CGSize(
      width: ExportSmokeFixtureConstants.pixelWidth,
      height: ExportSmokeFixtureConstants.pixelHeight
    )
    let sourceTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )
    let maskRect = ExportVideoGeometry.maskRenderRect(
      originXN: mask.originXN,
      originYN: mask.originYN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize,
      sourceTransform: sourceTransform,
      renderSize: renderSize
    )
    let mirroredMaskRect = ExportVideoGeometry.maskRenderRect(
      originXN: mask.originXN,
      originYN: 1 - mask.originYN - mask.heightN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize,
      sourceTransform: sourceTransform,
      renderSize: renderSize
    )
    let blurProbeRect = maskRect.insetBy(dx: maskRect.width * 0.18, dy: maskRect.height * 0.24)
    let mirroredProbeRect = mirroredMaskRect.insetBy(
      dx: mirroredMaskRect.width * 0.18,
      dy: mirroredMaskRect.height * 0.24
    )
    let referenceRect = CGRect(
      x: min(maskRect.maxX + 80, renderSize.width - 240),
      y: maskRect.midY - blurProbeRect.height / 2,
      width: 180,
      height: blurProbeRect.height
    )

    let blurDelta = try averageAdjacentHorizontalLuminanceDelta(in: cgImage, rect: blurProbeRect)
    let referenceDelta = try averageAdjacentHorizontalLuminanceDelta(in: cgImage, rect: referenceRect)
    let mirroredDelta = try averageAdjacentHorizontalLuminanceDelta(in: cgImage, rect: mirroredProbeRect)
    let blurRGB = try averageRGB(in: cgImage, rect: blurProbeRect)
    let blurLeftRect = CGRect(
      x: blurProbeRect.minX,
      y: blurProbeRect.minY,
      width: blurProbeRect.width * 0.24,
      height: blurProbeRect.height
    )
    let blurRightRect = CGRect(
      x: blurProbeRect.maxX - blurProbeRect.width * 0.24,
      y: blurProbeRect.minY,
      width: blurProbeRect.width * 0.24,
      height: blurProbeRect.height
    )
    let blurLeftRGB = try averageRGB(in: cgImage, rect: blurLeftRect)
    let blurRightRGB = try averageRGB(in: cgImage, rect: blurRightRect)
    let diagnostic = "renderSize=\(renderSize) maskRect=\(maskRect) mirroredMaskRect=\(mirroredMaskRect) blurProbeRect=\(blurProbeRect) mirroredProbeRect=\(mirroredProbeRect) referenceRect=\(referenceRect) blurLeftRect=\(blurLeftRect) blurRightRect=\(blurRightRect) blurDelta=\(blurDelta) mirroredDelta=\(mirroredDelta) referenceDelta=\(referenceDelta) blurRGB=\(blurRGB) blurLeftRGB=\(blurLeftRGB) blurRightRGB=\(blurRightRGB)"

    XCTAssertGreaterThan(referenceDelta, 8, "Reference stripes should keep measurable local contrast. \(diagnostic)")
    XCTAssertGreaterThan(
      blurRGB.luminance,
      70,
      "Blurred region should preserve source stripe luminance instead of flattening to black. \(diagnostic)"
    )
    XCTAssertLessThan(
      blurRGB.luminance,
      180,
      "Blurred region should preserve source stripe luminance instead of flattening to white. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      blurRightRGB.luminance,
      blurLeftRGB.luminance + 8,
      "Blurred region should preserve the source gradient instead of becoming a flat fill. \(diagnostic)"
    )
    XCTAssertLessThan(
      blurDelta,
      referenceDelta * 0.45,
      "Blur mask should reduce local stripe contrast inside the masked region. \(diagnostic)"
    )
    XCTAssertGreaterThan(
      mirroredDelta,
      referenceDelta * 0.65,
      "Blur mask should render at the top-left normalized position, not the vertically mirrored position. \(diagnostic)"
    )
  }

  func testExporterProducesMp4WithBackgroundMusicAudioTrack() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeMusic")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_music_in.mov")
    let musicURL = root.appendingPathComponent("fixture_music.caf")
    let mp4URL = root.appendingPathComponent("fixture_music_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeSineAudioCAF(to: musicURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Music",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      audioTrackSettings: .init(
        backgroundMusic: .init(isEnabled: true, volume: 0.4),
        backgroundMusicURL: musicURL
      )
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Music export expected finished got \(describeExportState(terminalState))")
      return
    }

    let asset = AVURLAsset(url: out)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertFalse(audioTracks.isEmpty, "Background music export should contain an audio track.")
  }

  @MainActor
  func testPreviewAudioMixUsesExportRoleMapping() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotPreviewAudioMix")
    defer { ExportSmokeFixtureMaker.remove(at: root) }
    let audioURL = root.appendingPathComponent("source.caf")
    try ExportSmokeFixtureMaker.writeSineAudioCAF(to: audioURL)
    let asset = AVURLAsset(url: audioURL)
    let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
    let sourceTrack = try XCTUnwrap(sourceTracks.first)
    let settings = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: false, volume: 0.6),
      system: .init(isEnabled: true, volume: 0.8),
      recordedTrackRoles: [.microphone, .system]
    )

    let mix = try XCTUnwrap(EditorPlaybackController.previewAudioMix(
      for: [sourceTrack, sourceTrack],
      settings: settings,
      audioSegments: [],
      compositionDurationSeconds: 4
    ))

    XCTAssertEqual(mix.inputParameters.count, 2)
    XCTAssertEqual(try volume(at: 0, in: mix), 0, accuracy: 1e-6)
    XCTAssertEqual(try volume(at: 1, in: mix), 0.8, accuracy: 1e-6)
  }

  @MainActor
  func testSingleAssetPreviewCompositionAddsBackgroundMusicWhenEnabled() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotPreviewMusic")
    defer { ExportSmokeFixtureMaker.remove(at: root) }
    let movURL = root.appendingPathComponent("source.mov")
    let musicURL = root.appendingPathComponent("music.caf")
    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeSineAudioCAF(to: musicURL)
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Preview Music",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: movURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      audioTrackSettings: .init(
        backgroundMusic: .init(isEnabled: true, volume: 0.4),
        backgroundMusicURL: musicURL
      )
    )

    let previewComposition = try await EditorPlaybackController.makeSingleAssetPreviewComposition(project: project)
    let composition = try XCTUnwrap(previewComposition)
    let audioTracks = try await composition.loadTracks(withMediaType: .audio)

    XCTAssertFalse(audioTracks.isEmpty, "Preview composition should contain background music when enabled.")
  }

  func testExporterProducesMp4WithEditorOverlaysAndCameraSegments() async throws {
    let root = try ExportSmokeFixtureMaker.tempDirectory(prefix: "ArcShotSmokeOverlays")
    defer { ExportSmokeFixtureMaker.remove(at: root) }

    let movURL = root.appendingPathComponent("fixture_overlays_in.mov")
    let cameraURL = root.appendingPathComponent("fixture_camera_in.mov")
    let mp4URL = root.appendingPathComponent("fixture_overlays_out.mp4")

    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: movURL)
    try ExportSmokeFixtureMaker.writeSolidBlackVideoMOV(to: cameraURL)

    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(),
      title: "Fixture Overlays",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: movURL,
      cursorSamples: [
        .init(timeSeconds: 0.05, x: 0.20, y: 0.28),
        .init(timeSeconds: 0.18, x: 0.46, y: 0.36),
        .init(timeSeconds: 0.34, x: 0.62, y: 0.42),
        .init(timeSeconds: 0.62, x: 0.70, y: 0.48),
      ],
      exportPreset: .p720p30,
      stylePreset: .none,
      styleSettings: RecordingProject.StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: RecordingProject.ExportVisualSettings.defaulted(forSourceKind: .window),
      textOverlayAnnotations: [],
      cursorClickCues: [
        .init(timeSeconds: 0.18),
      ],
      secondaryRecording: .init(
        mediaURL: cameraURL,
        originXN: 0.72,
        originYN: 0.72,
        widthN: 0.22,
        heightN: 0.14,
        cornerRadiusPts: 24
      ),
      zoomSegments: [
        RecordingProject.ZoomSegment(startSeconds: 0.08, endSeconds: 0.46, scale: 1.35, anchorX: 0.55, anchorY: 0.45),
      ],
      inputEvents: [
        .init(timeSeconds: 0.22, kind: .keyDown, characters: "k", modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.command.rawValue)),
      ],
      captionTrack: .init(
        isEnabled: true,
        segments: [
          .init(startSeconds: 0.12, endSeconds: 0.52, text: "Local caption"),
        ],
        style: .init(fontPointSize: 28, bottomInsetN: 0.08, backgroundOpacity: 0.42)
      ),
      visualMasks: [
        .init(startSeconds: 0.10, endSeconds: 0.50, kind: .highlight, originXN: 0.18, originYN: 0.18, widthN: 0.32, heightN: 0.22, opacity: 0.65),
      ],
      cameraLayoutSegments: [
        .init(startSeconds: 0.00, endSeconds: 0.32, layout: .pip, originXN: 0.72, originYN: 0.72, widthN: 0.22, heightN: 0.14, cornerRadiusPts: 24, isMirrored: true, shrinkDuringZoom: true),
        .init(startSeconds: 0.32, endSeconds: 0.72, layout: .fullscreen),
      ],
      cursorVisualSettings: .init(isVisible: true, sizeScale: 1.2, hideWhenIdle: false, showClickEffects: true, showKeyboardShortcuts: true)
    )

    let exporter = await MainActor.run { () -> Exporter in
      let e = Exporter()
      e.export(project: project, to: mp4URL)
      return e
    }

    try await waitForTerminalExport(exporter)

    let terminalState = await MainActor.run { exporter.state }
    guard case let .finished(out) = terminalState else {
      XCTFail("Overlay export expected finished got \(describeExportState(terminalState))")
      return
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    let size = (
      try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64
    ) ?? 0
    XCTAssertGreaterThan(size, 2_048, "Overlay export MP4 unusually small.")
  }

  /// Poll `Exporter` state until finished/failed or timeout (~60s).
  private func waitForTerminalExport(_ exporter: Exporter) async throws {
    let deadline = Date().addingTimeInterval(60)

    while Date() < deadline {
      let done = await MainActor.run {
        switch exporter.state {
        case .finished, .failed: return true
        case .idle, .exporting: return false
        }
      }

      if done { return }

      try await Task.sleep(nanoseconds: 45_000_000)
    }

    let stateSnapshot = await MainActor.run { exporter.state }
    throw ExportSmokeFixtureMaker.MakerError(
      message: "Export timed out lastState=\(describeExportState(stateSnapshot))"
    )
  }

  private func encodedVideoSize(at url: URL) async throws -> CGSize {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    async let naturalSize = track.load(.naturalSize)
    async let preferredTransform = track.load(.preferredTransform)
    let loaded = try await (naturalSize, preferredTransform)
    let encodedSize = loaded.0.applying(loaded.1)
    return CGSize(width: abs(encodedSize.width), height: abs(encodedSize.height))
  }

  private func waitForNoTemporaryOutputs(in directory: URL, matching nameFragment: String) async throws -> [String] {
    let deadline = Date().addingTimeInterval(2)
    var leftovers: [String] = []
    repeat {
      leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains(nameFragment) && $0.contains(".tmp.") }
      if leftovers.isEmpty { return [] }
      try await Task.sleep(nanoseconds: 50_000_000)
    } while Date() < deadline
    return leftovers
  }

  private func describeExportState(_ state: Exporter.ExportState) -> String {
    switch state {
    case .idle: "idle"
    case .exporting: "exporting"
    case .finished(let url): "finished(\(url.lastPathComponent))"
    case .failed(let message): "failed(\(message))"
    }
  }
}
