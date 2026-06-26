import Foundation

/// Heuristic zoom keyframe suggestions from recorded `CursorSample` motion (dwell + low speed).
enum CursorZoomHeuristics {
  enum Defaults {
    static let minDwellSeconds: Double = 1.6
    static let minSegmentSeconds: Double = 0.55
    static let clickSegmentSeconds: Double = 2.0
    static let mergeGapSeconds: Double = 1.8
    static let mergeAnchorDistance: Double = 0.28
    static let maxSpeedPerSecond: Double = 0.22
    static let suggestionScale: Double = 1.42
  }

  /// Proposes zoom segments from click cues first, then slow cursor dwell spans.
  static func suggestZoomKeyframes(
    samples: [RecordingProject.CursorSample],
    clickCues: [RecordingProject.CursorClickCue] = [],
    assetDurationSeconds: Double,
    minDwellSeconds: Double = Defaults.minDwellSeconds,
    minSegmentSeconds: Double = Defaults.minSegmentSeconds,
    clickSegmentSeconds: Double = Defaults.clickSegmentSeconds,
    maxSpeedPerSecond: Double = Defaults.maxSpeedPerSecond,
    scale: Double = Defaults.suggestionScale,
    existingKeyframes: [RecordingProject.ZoomKeyframe]
  ) -> [RecordingProject.ZoomKeyframe] {
    let duration = max(0, assetDurationSeconds)
    guard duration > 0 else { return [] }

    let sorted = samples.sorted { $0.timeSeconds < $1.timeSeconds }
    let clampedScale = max(1, min(3, scale))
    var proposed = clickZooms(
      from: clickCues,
      samples: sorted,
      duration: duration,
      segmentSeconds: max(minSegmentSeconds, clickSegmentSeconds),
      scale: clampedScale,
      existingKeyframes: existingKeyframes
    )
    guard sorted.count >= 2 else { return proposed }

    var dwSegs: [(start: Double, end: Double, ax: Double, ay: Double)] = []
    var segStartIdx = 0

    for i in 1 ..< sorted.count {
      let p0 = sorted[i - 1]
      let p1 = sorted[i]
      let dt = p1.timeSeconds - p0.timeSeconds
      guard dt > 1e-6 else { continue }
      let speed = hypot(p1.x - p0.x, p1.y - p0.y) / dt
      if speed > maxSpeedPerSecond {
        let segStartT = sorted[segStartIdx].timeSeconds
        let segEndT = p0.timeSeconds
        if let span = spanAnchor(from: sorted, startIndex: segStartIdx, endIndex: i - 1, segStartT: segStartT, segEndT: segEndT, minDwell: minDwellSeconds, minSeg: minSegmentSeconds) {
          dwSegs.append(span)
        }
        segStartIdx = i
      }
    }

    let lastStartT = sorted[segStartIdx].timeSeconds
    let lastEndT = sorted[sorted.count - 1].timeSeconds
    if let span = spanAnchor(from: sorted, startIndex: segStartIdx, endIndex: sorted.count - 1, segStartT: lastStartT, segEndT: lastEndT, minDwell: minDwellSeconds, minSeg: minSegmentSeconds) {
      dwSegs.append(span)
    }

    for seg in dwSegs {
      let kf = RecordingProject.ZoomKeyframe(
        startSeconds: max(0, seg.start),
        endSeconds: min(duration, seg.end),
        scale: clampedScale,
        anchorX: seg.ax,
        anchorY: seg.ay
      )
      guard kf.endSeconds - kf.startSeconds >= minSegmentSeconds else { continue }
      if !existingKeyframes.contains(where: { rangesOverlap($0.startSeconds, $0.endSeconds, kf.startSeconds, kf.endSeconds) }),
        !proposed.contains(where: { rangesOverlap($0.startSeconds, $0.endSeconds, kf.startSeconds, kf.endSeconds) }) {
        proposed.append(kf)
      }
    }

    return mergedNearbyZooms(
      proposed,
      maxGapSeconds: Defaults.mergeGapSeconds,
      maxAnchorDistance: Defaults.mergeAnchorDistance
    )
  }

  private static func clickZooms(
    from clickCues: [RecordingProject.CursorClickCue],
    samples: [RecordingProject.CursorSample],
    duration: Double,
    segmentSeconds: Double,
    scale: Double,
    existingKeyframes: [RecordingProject.ZoomKeyframe]
  ) -> [RecordingProject.ZoomKeyframe] {
    guard !clickCues.isEmpty, !samples.isEmpty else { return [] }
    var proposed: [RecordingProject.ZoomKeyframe] = []
    let sortedCues = clickCues.sorted { $0.timeSeconds < $1.timeSeconds }
    for cue in sortedCues {
      let desiredDuration = min(segmentSeconds, duration)
      var start = max(0, min(duration, cue.timeSeconds - desiredDuration * 0.28))
      var end = start + desiredDuration
      if end > duration {
        end = duration
        start = max(0, end - desiredDuration)
      }
      if start < 0 {
        start = 0
        end = min(duration, desiredDuration)
      }
      guard end - start >= Defaults.minSegmentSeconds else { continue }
      let anchor = nearestSampleAnchor(to: cue.timeSeconds, samples: samples)
      let kf = RecordingProject.ZoomKeyframe(
        startSeconds: start,
        endSeconds: end,
        scale: scale,
        anchorX: anchor.x,
        anchorY: anchor.y
      )
      guard !existingKeyframes.contains(where: { rangesOverlap($0.startSeconds, $0.endSeconds, kf.startSeconds, kf.endSeconds) }),
        !proposed.contains(where: { rangesOverlap($0.startSeconds, $0.endSeconds, kf.startSeconds, kf.endSeconds) })
      else { continue }
      proposed.append(kf)
    }
    return proposed
  }

  private static func nearestSampleAnchor(
    to timeSeconds: Double,
    samples: [RecordingProject.CursorSample]
  ) -> (x: Double, y: Double) {
    guard let nearest = samples.min(by: {
      abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
    }) else {
      return (0.5, 0.5)
    }
    return (max(0, min(1, nearest.x)), max(0, min(1, nearest.y)))
  }

  private static func spanAnchor(
    from sorted: [RecordingProject.CursorSample],
    startIndex: Int,
    endIndex: Int,
    segStartT: Double,
    segEndT: Double,
    minDwell: Double,
    minSeg: Double
  ) -> (start: Double, end: Double, ax: Double, ay: Double)? {
    guard segEndT - segStartT >= minDwell, segEndT > segStartT else { return nil }
    guard segEndT - segStartT >= minSeg else { return nil }
    var sx = 0.0
    var sy = 0.0
    var n = 0
    for j in startIndex ... endIndex {
      sx += sorted[j].x
      sy += sorted[j].y
      n += 1
    }
    guard n > 0 else { return nil }
    return (segStartT, segEndT, sx / Double(n), sy / Double(n))
  }

  private static func rangesOverlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
    max(a0, b0) < min(a1, b1)
  }

  private static func mergedNearbyZooms(
    _ keyframes: [RecordingProject.ZoomKeyframe],
    maxGapSeconds: Double,
    maxAnchorDistance: Double
  ) -> [RecordingProject.ZoomKeyframe] {
    let sorted = keyframes.sorted { $0.startSeconds < $1.startSeconds }
    guard !sorted.isEmpty else { return [] }

    var merged: [RecordingProject.ZoomKeyframe] = []
    for keyframe in sorted {
      guard var last = merged.popLast() else {
        merged.append(keyframe)
        continue
      }

      let gap = keyframe.startSeconds - last.endSeconds
      let anchorDistance = hypot(keyframe.anchorX - last.anchorX, keyframe.anchorY - last.anchorY)
      guard gap <= maxGapSeconds, anchorDistance <= maxAnchorDistance else {
        merged.append(last)
        merged.append(keyframe)
        continue
      }

      let lastDuration = max(0.001, last.endSeconds - last.startSeconds)
      let keyframeDuration = max(0.001, keyframe.endSeconds - keyframe.startSeconds)
      let totalDuration = lastDuration + keyframeDuration
      last.endSeconds = max(last.endSeconds, keyframe.endSeconds)
      last.inEndSeconds = min(last.inEndSeconds, last.startSeconds + (last.endSeconds - last.startSeconds) * 0.22)
      last.outStartSeconds = max(last.inEndSeconds, last.endSeconds - (last.endSeconds - last.startSeconds) * 0.22)
      last.scale = max(last.scale, keyframe.scale)
      last.anchorX = (last.anchorX * lastDuration + keyframe.anchorX * keyframeDuration) / totalDuration
      last.anchorY = (last.anchorY * lastDuration + keyframe.anchorY * keyframeDuration) / totalDuration
      let region = RecordingProject.ZoomSegment.targetRegion(
        scale: last.scale,
        anchorX: last.anchorX,
        anchorY: last.anchorY
      )
      last.targetX = region.x
      last.targetY = region.y
      last.targetWidth = region.width
      last.targetHeight = region.height
      merged.append(last)
    }
    return merged
  }
}
