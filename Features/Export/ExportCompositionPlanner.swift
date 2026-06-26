@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct ExportCompositionPlan {
  var readerAsset: AVAsset
  var mainVideoTrack: AVAssetTrack
  var pipVideoTrack: AVAssetTrack?
  var pipAttachment: RecordingProject.SecondaryRecordingAttachment?
  var compositionInstructionsTimeRange: CMTimeRange
  var readerTimeRange: CMTimeRange?
  var readerProgressBase: CMTime
  var effectiveExportDurationSeconds: Double
  var usesTimelineComposition: Bool
  var timedDataOffsetSeconds: Double
}

/// Chooses the AVAsset/track plan for MP4 export without mapping compositor timed metadata.
enum ExportCompositionPlanner {
  struct PlannerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  struct Input {
    var project: RecordingProject
    var mainAsset: AVURLAsset
    var mainLoadedDuration: CMTime
    var timeRange: CMTimeRange?
    var exportStartSeconds: Double
    var trimmedExportDurationSeconds: Double
  }

  static func plan(input: Input) throws -> ExportCompositionPlan {
    let pipAttachment = effectivePIPAttachment(project: input.project)
    let pipPathReady = pipAttachment.map { FileManager.default.fileExists(atPath: $0.mediaURL.path) } ?? false
    let timelineComposition = try buildTimelineCompositionIfNeeded(
      project: input.project,
      pipAttachment: pipAttachment
    )

    if let timelineComposition {
      try addBackgroundMusicIfNeeded(
        to: timelineComposition.composition,
        duration: timelineComposition.videoTimeRange.duration,
        project: input.project
      )
      return ExportCompositionPlan(
        readerAsset: timelineComposition.composition,
        mainVideoTrack: timelineComposition.mainVideoTrack,
        pipVideoTrack: timelineComposition.pipVideoTrack,
        pipAttachment: timelineComposition.pipVideoTrack == nil ? nil : pipAttachment,
        compositionInstructionsTimeRange: timelineComposition.videoTimeRange,
        readerTimeRange: nil,
        readerProgressBase: .zero,
        effectiveExportDurationSeconds: max(0.001, timelineComposition.durationSeconds),
        usesTimelineComposition: true,
        timedDataOffsetSeconds: 0
      )
    }

    if let pipAttachment, pipPathReady {
      let pipAsset = AVURLAsset(url: pipAttachment.mediaURL)
      let mix = try ExportAsyncBridge.runSync {
        try await ExportMixedCompositionBuilder.build(
          mainAsset: input.mainAsset,
          pipAsset: pipAsset,
          mainTrim: input.timeRange
        )
      }
      try addBackgroundMusicIfNeeded(
        to: mix.composition,
        duration: mix.compositionVideoTimeRange.duration,
        project: input.project
      )
      return ExportCompositionPlan(
        readerAsset: mix.composition,
        mainVideoTrack: mix.mainVideoTrack,
        pipVideoTrack: mix.pipVideoTrack,
        pipAttachment: pipAttachment,
        compositionInstructionsTimeRange: CMTimeRange(start: .zero, duration: mix.compositionVideoTimeRange.duration),
        readerTimeRange: nil,
        readerProgressBase: .zero,
        effectiveExportDurationSeconds: input.trimmedExportDurationSeconds,
        usesTimelineComposition: false,
        timedDataOffsetSeconds: 0
      )
    }

    let videoTracks = try ExportAsyncBridge.runSync { try await input.mainAsset.loadTracks(withMediaType: .video) }
    guard let mainTrack = videoTracks.first else {
      throw PlannerError("動画トラックが見つかりません。")
    }

    if shouldAddBackgroundMusic(project: input.project) {
      let single = try buildSingleAssetComposition(
        mainAsset: input.mainAsset,
        mainVideoTrack: mainTrack,
        mainTrim: input.timeRange,
        fallbackDuration: input.mainLoadedDuration,
        project: input.project
      )
      return ExportCompositionPlan(
        readerAsset: single.composition,
        mainVideoTrack: single.mainVideoTrack,
        pipVideoTrack: nil,
        pipAttachment: nil,
        compositionInstructionsTimeRange: single.videoTimeRange,
        readerTimeRange: nil,
        readerProgressBase: .zero,
        effectiveExportDurationSeconds: input.trimmedExportDurationSeconds,
        usesTimelineComposition: false,
        timedDataOffsetSeconds: 0
      )
    }

    return ExportCompositionPlan(
      readerAsset: input.mainAsset,
      mainVideoTrack: mainTrack,
      pipVideoTrack: nil,
      pipAttachment: nil,
      compositionInstructionsTimeRange: input.timeRange
        ?? CMTimeRange(
          start: .zero,
          duration: input.mainLoadedDuration.isNumeric
            ? input.mainLoadedDuration
            : CMTime(seconds: 10, preferredTimescale: 600)
        ),
      readerTimeRange: input.timeRange,
      readerProgressBase: input.timeRange?.start ?? .zero,
      effectiveExportDurationSeconds: input.trimmedExportDurationSeconds,
      usesTimelineComposition: false,
      timedDataOffsetSeconds: input.exportStartSeconds
    )
  }

  private struct TimelineCompositionResult {
    var composition: AVMutableComposition
    var mainVideoTrack: AVAssetTrack
    var pipVideoTrack: AVAssetTrack?
    var videoTimeRange: CMTimeRange
    var durationSeconds: Double
  }

  private struct SingleAssetCompositionResult {
    var composition: AVMutableComposition
    var mainVideoTrack: AVAssetTrack
    var videoTimeRange: CMTimeRange
  }

  private static func effectivePIPAttachment(project: RecordingProject) -> RecordingProject.SecondaryRecordingAttachment? {
    guard var attachment = project.secondaryRecording else { return nil }
    let segment = project.cameraLayoutSegments
      .sorted { $0.startSeconds < $1.startSeconds }
      .first { $0.layout != .hidden }
    guard let segment else {
      return attachment.clampedForExport()
    }

    switch segment.layout {
    case .hidden:
      return nil
    case .pip:
      attachment.originXN = segment.originXN
      attachment.originYN = segment.originYN
      attachment.widthN = segment.widthN
      attachment.heightN = segment.heightN
      attachment.cornerRadiusPts = segment.cornerRadiusPts
    case .fullscreen:
      attachment.originXN = 0
      attachment.originYN = 0
      attachment.widthN = 1
      attachment.heightN = 1
      attachment.cornerRadiusPts = 0
    }
    return attachment.clampedForExport()
  }

  private static func buildTimelineCompositionIfNeeded(
    project: RecordingProject,
    pipAttachment: RecordingProject.SecondaryRecordingAttachment?
  ) throws -> TimelineCompositionResult? {
    let clips = project.timeline.activeClips
    guard !clips.isEmpty else { return nil }

    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw PlannerError("タイムライン用ビデオトラックを作成できませんでした。")
    }

    var audioTracksByIndex: [Int: AVMutableCompositionTrack] = [:]
    var firstPreferredTransform: CGAffineTransform?
    var exportDurationSeconds = 0.0

    for clip in clips {
      let rate = project.timeline.speedRate(
        forTimelineRangeStart: clip.timelineStartSeconds,
        end: clip.timelineStartSeconds + clip.durationSeconds
      )
      let sourceDurationSeconds = max(
        RecordingProject.TimelineEditing.minClipDurationSeconds,
        clip.durationSeconds * rate
      )
      let asset = AVURLAsset(url: clip.sourceURL)
      let loaded = try ExportAsyncBridge.runSync { () async throws -> (AVAssetTrack, [AVAssetTrack], CMTime, CGAffineTransform) in
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else {
          throw PlannerError("タイムラインクリップに動画トラックが見つかりません。")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let transform = try await video.load(.preferredTransform)
        return (video, audioTracks, duration, transform)
      }

      let assetDurationSeconds = loaded.2.isNumeric ? max(0, loaded.2.seconds) : sourceDurationSeconds
      let sourceStartSeconds = max(0, min(clip.sourceStartSeconds, assetDurationSeconds))
      let availableSourceDuration = max(0, assetDurationSeconds - sourceStartSeconds)
      let sourceDuration = min(sourceDurationSeconds, availableSourceDuration)
      guard sourceDuration > RecordingProject.TimelineEditing.minClipDurationSeconds else { continue }

      let sourceRange = CMTimeRange(
        start: CMTime(seconds: sourceStartSeconds, preferredTimescale: 600),
        duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)
      )
      let insertAt = CMTime(seconds: clip.timelineStartSeconds, preferredTimescale: 600)
      try videoTrack.insertTimeRange(sourceRange, of: loaded.0, at: insertAt)
      if abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 {
        videoTrack.scaleTimeRange(
          CMTimeRange(start: insertAt, duration: sourceRange.duration),
          toDuration: CMTime(seconds: clip.durationSeconds, preferredTimescale: 600)
        )
      }
      if firstPreferredTransform == nil {
        firstPreferredTransform = loaded.3
      }

      let clipTimelineDuration = CMTime(seconds: clip.durationSeconds, preferredTimescale: 600)
      let clipTimelineRange = CMTimeRange(start: insertAt, duration: clipTimelineDuration)
      for (audioIndex, audioTrack) in loaded.1.enumerated() {
        if audioTracksByIndex[audioIndex] == nil {
          guard let newTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          ) else { continue }
          if insertAt > .zero {
            newTrack.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: insertAt))
          }
          audioTracksByIndex[audioIndex] = newTrack
        }
        guard let compAudio = audioTracksByIndex[audioIndex] else { continue }
        try compAudio.insertTimeRange(sourceRange, of: audioTrack, at: insertAt)
        if abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 {
          compAudio.scaleTimeRange(
            CMTimeRange(start: insertAt, duration: sourceRange.duration),
            toDuration: clipTimelineDuration
          )
        }
      }
      for (existingIndex, existingTrack) in audioTracksByIndex where existingIndex >= loaded.1.count {
        existingTrack.insertEmptyTimeRange(clipTimelineRange)
      }
      exportDurationSeconds = max(exportDurationSeconds, clip.timelineStartSeconds + clip.durationSeconds)
    }

    guard exportDurationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds else {
      return nil
    }
    if let firstPreferredTransform {
      videoTrack.preferredTransform = firstPreferredTransform
    }

    let timeRange = CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: exportDurationSeconds, preferredTimescale: 600)
    )
    let pipTrack: AVAssetTrack?
    if let pipAttachment,
      FileManager.default.fileExists(atPath: pipAttachment.mediaURL.path) {
      pipTrack = try addPIPVideoTrack(
        to: composition,
        attachment: pipAttachment,
        clips: clips,
        timeline: project.timeline
      )
    } else {
      pipTrack = nil
    }

    return TimelineCompositionResult(
      composition: composition,
      mainVideoTrack: videoTrack,
      pipVideoTrack: pipTrack,
      videoTimeRange: timeRange,
      durationSeconds: exportDurationSeconds
    )
  }

  private static func addPIPVideoTrack(
    to composition: AVMutableComposition,
    attachment: RecordingProject.SecondaryRecordingAttachment,
    clips: [RecordingProject.TimelineModel.Clip],
    timeline: RecordingProject.TimelineModel
  ) throws -> AVAssetTrack? {
    let pipAsset = AVURLAsset(url: attachment.mediaURL)
    let loaded = try ExportAsyncBridge.runSync { () async throws -> (AVAssetTrack, CMTime) in
      let tracks = try await pipAsset.loadTracks(withMediaType: .video)
      guard let track = tracks.first else {
        throw PlannerError("カメラ動画トラックが見つかりません。")
      }
      let assetDuration = try await pipAsset.load(.duration)
      return (track, assetDuration)
    }
    let pipDurationSeconds = loaded.1.isNumeric ? max(0, loaded.1.seconds) : 0
    guard pipDurationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds,
      let pipTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      return nil
    }

    let slices = ExportPIPTimelineSourceMapper.slices(
      clips: clips,
      timeline: timeline,
      pipDurationSeconds: pipDurationSeconds
    )
    guard !slices.isEmpty else { return nil }

    for slice in slices {
      let sourceRange = CMTimeRange(
        start: CMTime(seconds: slice.sourceStartSeconds, preferredTimescale: 600),
        duration: CMTime(seconds: slice.sourceDurationSeconds, preferredTimescale: 600)
      )
      let insertAt = CMTime(seconds: slice.timelineStartSeconds, preferredTimescale: 600)
      try pipTrack.insertTimeRange(sourceRange, of: loaded.0, at: insertAt)
      if abs(slice.rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 {
        pipTrack.scaleTimeRange(
          CMTimeRange(start: insertAt, duration: sourceRange.duration),
          toDuration: CMTime(seconds: slice.timelineDurationSeconds, preferredTimescale: 600)
        )
      }
    }

    return pipTrack
  }

  private static func buildSingleAssetComposition(
    mainAsset: AVURLAsset,
    mainVideoTrack sourceVideoTrack: AVAssetTrack,
    mainTrim: CMTimeRange?,
    fallbackDuration: CMTime,
    project: RecordingProject
  ) throws -> SingleAssetCompositionResult {
    let sourceRange: CMTimeRange = {
      if let mainTrim, mainTrim.duration > .zero {
        return mainTrim
      }
      let duration = fallbackDuration.isNumeric ? fallbackDuration : CMTime(seconds: 10, preferredTimescale: 600)
      return CMTimeRange(start: .zero, duration: duration)
    }()

    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw PlannerError("合成用ビデオトラックを作成できませんでした。")
    }
    try videoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: .zero)
    let preferredTransform = try ExportAsyncBridge.runSync { try await sourceVideoTrack.load(.preferredTransform) }
    videoTrack.preferredTransform = preferredTransform

    let audioTracks = try ExportAsyncBridge.runSync { try await mainAsset.loadTracks(withMediaType: .audio) }
    for audioTrack in audioTracks {
      guard let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        continue
      }
      try compositionAudio.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
    }

    try addBackgroundMusicIfNeeded(to: composition, duration: sourceRange.duration, project: project)

    return SingleAssetCompositionResult(
      composition: composition,
      mainVideoTrack: videoTrack,
      videoTimeRange: CMTimeRange(start: .zero, duration: sourceRange.duration)
    )
  }

  private static func addBackgroundMusicIfNeeded(
    to composition: AVMutableComposition,
    duration: CMTime,
    project: RecordingProject
  ) throws {
    guard shouldAddBackgroundMusic(project: project),
      let musicURL = project.audioTrackSettings.backgroundMusicURL,
      duration > .zero
    else { return }

    let musicAsset = AVURLAsset(url: musicURL)
    let musicData = try ExportAsyncBridge.runSync { () async throws -> (AVAssetTrack, CMTime) in
      let tracks = try await musicAsset.loadTracks(withMediaType: .audio)
      guard let track = tracks.first else {
        throw PlannerError("背景音楽に音声トラックが見つかりません。")
      }
      let loadedDuration = try await musicAsset.load(.duration)
      return (track, loadedDuration)
    }
    let musicDuration = musicData.1.isNumeric ? musicData.1 : duration
    guard musicDuration > .zero else { return }
    guard let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw PlannerError("背景音楽トラックを作成できませんでした。")
    }

    var cursor = CMTime.zero
    while cursor < duration {
      let remaining = CMTimeSubtract(duration, cursor)
      let sliceDuration = min(remaining, musicDuration)
      let range = CMTimeRange(start: .zero, duration: sliceDuration)
      try musicTrack.insertTimeRange(range, of: musicData.0, at: cursor)
      cursor = CMTimeAdd(cursor, sliceDuration)
    }
  }

  private static func shouldAddBackgroundMusic(project: RecordingProject) -> Bool {
    guard project.audioTrackSettings.backgroundMusic.isEnabled,
      let url = project.audioTrackSettings.backgroundMusicURL
    else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

}
