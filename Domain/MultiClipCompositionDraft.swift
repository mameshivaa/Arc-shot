import Foundation

// MARK: — Multi-clip export draft (`AVMutableComposition` target architecture)

/// マルチクリップ編集向けの下書きモデル（現行 UI・保存形式は単一クリップの `RecordingProject` のみ）。
/// 実験用にシリアル化しやすい形で置いてあり、ランタイムではまだ読み込まれません。
enum MultiClipCompositionDraft {
  struct TimelineClipDraft: Codable, Equatable, Identifiable {
    var id: UUID
    /// Source media on disk (`file:` URL).
    var sourceURL: URL
    /// In-point inside `sourceURL` timeline (seconds).
    var clipStartSeconds: Double
    var clipDurationSeconds: Double
    /// Start time on master timeline after previous clips / transitions (seconds).
    var timelineStartSeconds: Double
  }

  struct SessionUndoCommandDraft: Codable, Equatable {
    enum Kind: String, Codable {
      case insertClip
      case removeClip
      case rippleTrimLeading
    }
    var kind: Kind
    /// Opaque undo payload version for future migrations.
    var revision: Int

    init(kind: Kind, revision: Int = 1) {
      self.kind = kind
      self.revision = revision
    }
  }
}
