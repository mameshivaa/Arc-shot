@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

struct ExportManifest {
  var renderSize: CGSize
  var frameRate: Int
  var expectedDurationSeconds: Double
  var expectedFrameCount: Int
  var codec: ExportPreset.VideoCodec
  var bitrateTarget: Int
  var usesTimelineComposition: Bool
  var motionSource: AutoZoomMotionResolution.Source
}

/// Owns temp export files, MP4 validation, and final promotion into the user-selected URL.
enum ExportOutputPromotion {
  static func temporaryOutputURL(for outputURL: URL) -> URL {
    let directory = FileManager.default.temporaryDirectory
    let baseName = outputURL.deletingPathExtension().lastPathComponent
    let pathExtension = outputURL.pathExtension.isEmpty ? "mp4" : outputURL.pathExtension
    return directory.appendingPathComponent("ArcShot-\(baseName)-\(UUID().uuidString).\(pathExtension)")
  }

  static func removeTemporaryOutputArtifacts(for url: URL) {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    let temporaryName = url.lastPathComponent
    if fileManager.fileExists(atPath: url.path) {
      try? fileManager.removeItem(at: url)
    }
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names where name.hasPrefix("\(temporaryName).sb-") {
      try? fileManager.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  static func promoteTemporaryOutput(
    _ temporaryURL: URL,
    to outputURL: URL,
    manifest: ExportManifest
  ) throws {
    try validate(outputURL: temporaryURL, manifest: manifest)

    // INVARIANT (docs/INVARIANTS.md §4): only replace the user's existing output
    // after the temp MP4 has passed validation.
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: outputURL)
  }

  private static func validate(outputURL: URL, manifest: ExportManifest) throws {
    let asset = AVURLAsset(url: outputURL)
    let loaded = try ExportAsyncBridge.runSync { () async throws -> (CMTime, [AVAssetTrack]) in
      async let duration = asset.load(.duration)
      async let tracks = asset.loadTracks(withMediaType: .video)
      return try await (duration, tracks)
    }
    let duration = loaded.0
    let tracks = loaded.1
    guard let track = tracks.first else {
      throw ExportError("書き出し検証に失敗しました: ビデオトラックがありません。")
    }

    let trackInfo = try ExportAsyncBridge.runSync { () async throws -> (CGSize, CGAffineTransform, Float, [CMFormatDescription]) in
      async let naturalSize = track.load(.naturalSize)
      async let preferredTransform = track.load(.preferredTransform)
      async let nominalFrameRate = track.load(.nominalFrameRate)
      async let formatDescriptions = track.load(.formatDescriptions)
      return try await (naturalSize, preferredTransform, nominalFrameRate, formatDescriptions)
    }
    let encodedSize = trackInfo.0.applying(trackInfo.1)
    guard abs(abs(encodedSize.width) - manifest.renderSize.width) <= 1,
      abs(abs(encodedSize.height) - manifest.renderSize.height) <= 1
    else {
      throw ExportError("書き出し検証に失敗しました: 解像度が期待値と異なります。")
    }

    if duration.isNumeric {
      let tolerance = max(0.08, 2.0 / Double(max(1, manifest.frameRate)))
      guard abs(duration.seconds - manifest.expectedDurationSeconds) <= tolerance else {
        throw ExportError("書き出し検証に失敗しました: 尺が期待値と異なります。")
      }

      // Nominal frame count implied by muxed duration — avoids re-reading/decoding the entire MP4.
      let impliedFrameCount = Int((duration.seconds * Double(manifest.frameRate)).rounded(.toNearestOrAwayFromZero))
      guard abs(impliedFrameCount - manifest.expectedFrameCount) <= 1 else {
        throw ExportError("書き出し検証に失敗しました: フレーム数が期待値と異なります。")
      }
    }

    let nominalFrameRate = Double(trackInfo.2)
    if nominalFrameRate > 0 {
      guard abs(nominalFrameRate - Double(manifest.frameRate)) <= 0.5 else {
        throw ExportError("書き出し検証に失敗しました: フレームレートが期待値と異なります。")
      }
    }

    if let subtype = trackInfo.3.first.map({ CMFormatDescriptionGetMediaSubType($0) }) {
      switch manifest.codec {
      case .h264:
        guard subtype == kCMVideoCodecType_H264 else {
          throw ExportError("書き出し検証に失敗しました: H.264 で出力されていません。")
        }
      case .hevc:
        guard subtype == kCMVideoCodecType_HEVC else {
          throw ExportError("書き出し検証に失敗しました: HEVC で出力されていません。")
        }
      }
    }
  }
}
