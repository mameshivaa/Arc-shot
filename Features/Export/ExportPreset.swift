import AVFoundation
import Foundation

/// Export encoding preset: resolution/fps/bitrate/`ExportPresetID` stay in sync with `RecordingProject.ExportPresetID`.
struct ExportPreset: Identifiable, Hashable {
  enum Resolution: String, Hashable {
    case p1080
    case p720
    case matchSource
  }

  /// AVC / HEVC selection mirrors `RecordingProject.ExportPresetID` suffixing (`*Hevc` → `.hevc`).
  enum VideoCodec: Hashable {
    case h264
    case hevc

    var avType: AVVideoCodecType {
      switch self {
      case .h264: AVVideoCodecType.h264
      case .hevc: AVVideoCodecType.hevc
      }
    }
  }

  var id: RecordingProject.ExportPresetID
  var title: String
  var resolution: Resolution
  var frameRate: Int
  var videoBitrateMbps: Int
  var codec: VideoCodec

  /// HEVC tiers use moderately lower nominal bitrates vs H.264 at similar visual tiers (hardware encoders vary by machine).
  ///
  /// INVARIANT (docs/INVARIANTS.md §5):
  /// - `.matchSource` presets: export at largest aspect-fit size inside source pixels (no upscale).
  /// - `VideoEncoding.scaledBitrateMbps` scales nominal Mbps by output pixel count.
  /// - New project default export preset: `matchSource60` (see RecordingProject factory).
  static let all: [ExportPreset] = [
    .init(id: .matchSource60, title: "ソース解像度 / 60fps / H.264", resolution: .matchSource, frameRate: 60, videoBitrateMbps: 22, codec: .h264),
    .init(id: .matchSource60Hevc, title: "ソース解像度 / 60fps / HEVC", resolution: .matchSource, frameRate: 60, videoBitrateMbps: 18, codec: .hevc),
    .init(id: .p1080p60, title: "1080p / 60fps / H.264", resolution: .p1080, frameRate: 60, videoBitrateMbps: 22, codec: .h264),
    .init(id: .p1080p60Hevc, title: "1080p / 60fps / HEVC", resolution: .p1080, frameRate: 60, videoBitrateMbps: 18, codec: .hevc),
    .init(id: .p1080p30, title: "1080p / 30fps / H.264", resolution: .p1080, frameRate: 30, videoBitrateMbps: 14, codec: .h264),
    .init(id: .p1080p30Hevc, title: "1080p / 30fps / HEVC", resolution: .p1080, frameRate: 30, videoBitrateMbps: 12, codec: .hevc),
    .init(id: .p720p30, title: "720p / 30fps / H.264", resolution: .p720, frameRate: 30, videoBitrateMbps: 8, codec: .h264),
    .init(id: .p720p30Hevc, title: "720p / 30fps / HEVC", resolution: .p720, frameRate: 30, videoBitrateMbps: 7, codec: .hevc),
  ]

  enum VideoEncoding {
    static let referencePixelCount: CGFloat = 1920 * 1080
    static let maximumBitrateMbps = 80

    static func scaledBitrateMbps(baseMbps: Int, renderSize: CGSize) -> Int {
      let pixels = max(1, renderSize.width * renderSize.height)
      let ratio = pixels / referencePixelCount
      return min(maximumBitrateMbps, max(baseMbps, Int((Double(baseMbps) * Double(ratio)).rounded())))
    }
  }

  static func byID(_ id: RecordingProject.ExportPresetID) -> ExportPreset {
    all.first(where: { $0.id == id }) ?? all[0]
  }
}

