import Foundation
import simd

struct CameraTrack {
  let frames: [CameraFrame]
  let durationSeconds: Double

  init(frames: [CameraFrame], durationSeconds: Double) {
    self.frames = frames.sorted { $0.timeSeconds < $1.timeSeconds }
    self.durationSeconds = max(0, durationSeconds)
  }

  func frame(at t: Double) -> CameraFrame {
    guard !frames.isEmpty else {
      return CameraFrame(timeSeconds: t, position: simd_double2(0.5, 0.5), scale: 1)
    }
    guard frames.count > 1 else { return frames[0] }
    if t <= frames[0].timeSeconds { return frames[0] }
    if t >= frames[frames.count - 1].timeSeconds { return frames[frames.count - 1] }

    var lo = 0, hi = frames.count - 1
    while lo < hi - 1 {
      let mid = (lo + hi) / 2
      if frames[mid].timeSeconds <= t { lo = mid } else { hi = mid }
    }
    let f0 = frames[lo]
    let f1 = frames[hi]
    let dt = f1.timeSeconds - f0.timeSeconds
    guard dt > 1e-9 else { return f0 }
    let u = (t - f0.timeSeconds) / dt
    return CameraFrame(
      timeSeconds: t,
      position: simd_mix(f0.position, f1.position, simd_double2(repeating: u)),
      scale: f0.scale + (f1.scale - f0.scale) * u)
  }

  func toZoomKeyframes(
    sampleRate: Double = 10,
    scaleThreshold: Double = 1.01,
    positionThreshold: Double = 0.005,
    minSegmentSeconds: Double = 1.1
  ) -> [RecordingProject.ZoomKeyframe] {
    guard !frames.isEmpty, durationSeconds > 0 else { return [] }

    let step = 1.0 / max(1, sampleRate)
    var segments: [(start: Double, end: Double, scale: Double, ax: Double, ay: Double)] = []

    var segStart = 0.0
    var prevFrame = frame(at: 0)

    var t = step
    while t <= durationSeconds + 1e-6 {
      let current = frame(at: min(t, durationSeconds))
      let scaleChanged = abs(current.scale - prevFrame.scale) > scaleThreshold * 0.1
      let posChanged = simd_distance(current.position, prevFrame.position) > positionThreshold

      if scaleChanged || posChanged || t >= durationSeconds {
        let avgFrame = frame(at: (segStart + min(t, durationSeconds)) / 2)
        if avgFrame.scale > scaleThreshold {
          segments.append((
            start: segStart,
            end: min(t, durationSeconds),
            scale: avgFrame.scale,
            ax: avgFrame.position.x,
            ay: avgFrame.position.y))
        }
        segStart = t
        prevFrame = current
      }
      t += step
    }

    return mergeCloseSegments(segments).compactMap { seg in
      guard seg.end - seg.start >= minSegmentSeconds else { return nil }
      return RecordingProject.ZoomKeyframe(
        startSeconds: seg.start,
        endSeconds: seg.end,
        scale: max(1, min(3, seg.scale)),
        anchorX: max(0, min(1, seg.ax)),
        anchorY: max(0, min(1, seg.ay)))
    }
  }

  func toZoomSegments(
    sampleRate: Double = 10,
    scaleThreshold: Double = 1.01,
    positionThreshold: Double = 0.005,
    minSegmentSeconds: Double = 1.1
  ) -> [RecordingProject.ZoomSegment] {
    toZoomKeyframes(
      sampleRate: sampleRate,
      scaleThreshold: scaleThreshold,
      positionThreshold: positionThreshold,
      minSegmentSeconds: minSegmentSeconds
    ).map { kf in
      RecordingProject.ZoomSegment(
        id: kf.id,
        startSeconds: kf.startSeconds,
        endSeconds: kf.endSeconds,
        mode: .auto,
        scale: kf.scale,
        anchorX: kf.anchorX,
        anchorY: kf.anchorY,
        followsClick: false)
    }
  }

  private func mergeCloseSegments(
    _ segments: [(start: Double, end: Double, scale: Double, ax: Double, ay: Double)]
  ) -> [(start: Double, end: Double, scale: Double, ax: Double, ay: Double)] {
    guard !segments.isEmpty else { return [] }
    var merged = [segments[0]]
    for i in 1..<segments.count {
      let current = segments[i]
      var last = merged[merged.count - 1]
      let gap = current.start - last.end
      let scaleClose = abs(current.scale - last.scale) < 0.24
      let posClose = hypot(current.ax - last.ax, current.ay - last.ay) < 0.28
      if gap < 1.6 && scaleClose && posClose {
        let totalDur = current.end - last.start
        let lastWeight = (last.end - last.start) / totalDur
        let curWeight = (current.end - current.start) / totalDur
        last.end = current.end
        last.scale = last.scale * lastWeight + current.scale * curWeight
        last.ax = last.ax * lastWeight + current.ax * curWeight
        last.ay = last.ay * lastWeight + current.ay * curWeight
        merged[merged.count - 1] = last
      } else {
        merged.append(current)
      }
    }
    return merged
  }
}
