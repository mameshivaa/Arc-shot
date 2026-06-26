import Foundation

struct ExportPIPTimelineSourceSlice: Equatable {
  var sourceStartSeconds: Double
  var sourceDurationSeconds: Double
  var timelineStartSeconds: Double
  var timelineDurationSeconds: Double
  var rate: Double
}

/// Maps timeline clip windows onto a camera sidecar so PiP stays aligned with edited main clips.
enum ExportPIPTimelineSourceMapper {
  static func slices(
    clips: [RecordingProject.TimelineModel.Clip],
    timeline: RecordingProject.TimelineModel,
    pipDurationSeconds: Double
  ) -> [ExportPIPTimelineSourceSlice] {
    let safePIPDurationSeconds = max(0, pipDurationSeconds)
    guard safePIPDurationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds else {
      return []
    }

    return clips.compactMap { clip in
      let rate = timeline.speedRate(
        forTimelineRangeStart: clip.timelineStartSeconds,
        end: clip.timelineStartSeconds + clip.durationSeconds
      )
      let sourceStartSeconds = max(0, min(clip.sourceStartSeconds, safePIPDurationSeconds))
      let requestedSourceDuration = max(
        RecordingProject.TimelineEditing.minClipDurationSeconds,
        clip.durationSeconds * rate
      )
      let sourceDuration = min(requestedSourceDuration, max(0, safePIPDurationSeconds - sourceStartSeconds))
      guard sourceDuration > RecordingProject.TimelineEditing.minClipDurationSeconds else { return nil }

      return ExportPIPTimelineSourceSlice(
        sourceStartSeconds: sourceStartSeconds,
        sourceDurationSeconds: sourceDuration,
        timelineStartSeconds: clip.timelineStartSeconds,
        timelineDurationSeconds: clip.durationSeconds,
        rate: rate
      )
    }
  }
}
