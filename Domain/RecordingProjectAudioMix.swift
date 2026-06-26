import AVFoundation

enum RecordingProjectAudioMix {
  static func makeInputParameters(
    for tracks: [AVAssetTrack],
    settings: RecordingProject.AudioTrackSettings,
    audioSegments: [RecordingProject.AudioTimelineSegment],
    compositionDurationSeconds: Double
  ) -> [AVAudioMixInputParameters] {
    guard !tracks.isEmpty else { return [] }
    let duration = max(RecordingProject.TimelineMediaEditing.minAudioSpanSeconds, compositionDurationSeconds)
    return tracks.enumerated().map { index, track in
      let params = AVMutableAudioMixInputParameters(track: track)
      let role = settings.compositionRole(forTrackIndex: index, totalCount: tracks.count)
      let volume = settings.volumeForCompositionTrack(index: index, totalCount: tracks.count)
      if let role, let segment = audioSegments.first(where: { $0.role == role }) {
        applyTrimmedVolume(
          params: params,
          volume: volume,
          startSeconds: segment.startSeconds,
          endSeconds: segment.endSeconds,
          durationSeconds: duration
        )
      } else {
        params.setVolume(Float(volume), at: .zero)
      }
      return params
    }
  }

  private static func applyTrimmedVolume(
    params: AVMutableAudioMixInputParameters,
    volume: Double,
    startSeconds: Double,
    endSeconds: Double,
    durationSeconds: Double
  ) {
    let start = max(0, min(durationSeconds, startSeconds))
    let end = max(start + RecordingProject.TimelineMediaEditing.minAudioSpanSeconds, min(durationSeconds, endSeconds))
    let floatVolume = Float(max(0, volume))
    let timescale: CMTimeScale = 600
    let epsilon = 0.001

    if start > epsilon {
      params.setVolume(0, at: .zero)
      params.setVolume(0, at: CMTime(seconds: max(0, start - epsilon), preferredTimescale: timescale))
    } else {
      params.setVolume(floatVolume, at: .zero)
    }
    params.setVolume(floatVolume, at: CMTime(seconds: start, preferredTimescale: timescale))
    params.setVolume(floatVolume, at: CMTime(seconds: max(start, end - epsilon), preferredTimescale: timescale))
    if end < durationSeconds - epsilon {
      params.setVolume(0, at: CMTime(seconds: end, preferredTimescale: timescale))
    }
  }
}
