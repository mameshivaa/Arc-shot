import Foundation
import simd

enum UserActivity: Equatable {
  case idle
  case clicking(anchor: simd_double2)
  case typing(anchor: simd_double2)
  case dragging
  case navigating
  case scrolling(anchor: simd_double2)
}

struct ActivitySpan: Equatable {
  var activity: UserActivity
  var startSeconds: Double
  var endSeconds: Double
  var anchor: simd_double2

  var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

enum ActivityClassifier {
  struct Config {
    var idleSpeedThreshold: Double = 0.08
    var idleMinSeconds: Double = 0.4
    var clickWindowSeconds: Double = 0.15
    var typingBurstMaxGapSeconds: Double = 0.8
    var navigationSpeedThreshold: Double = 0.35
    var navigationMinSeconds: Double = 0.12
    var dragMinSeconds: Double = 0.25
    var scrollInferenceVerticalThreshold: Double = 0.6
  }

  static func classify(
    cursorSamples: [RecordingProject.CursorSample],
    inputEvents: [RecordingProject.InputEvent],
    durationSeconds: Double,
    config: Config = Config()
  ) -> [ActivitySpan] {
    let samples = cursorSamples.sorted { $0.timeSeconds < $1.timeSeconds }
    let events = inputEvents.sorted { $0.timeSeconds < $1.timeSeconds }
    guard !samples.isEmpty, durationSeconds > 0 else { return [] }

    let clickIntervals = extractClickIntervals(events: events, config: config)
    let typingIntervals = extractTypingIntervals(events: events, config: config)
    let dragIntervals = extractDragIntervals(events: events, samples: samples, config: config)

    var spans: [ActivitySpan] = []
    let stepSeconds = 1.0 / 60.0
    var t = 0.0

    while t < durationSeconds {
      if let click = clickIntervals.first(where: { t >= $0.start && t < $0.end }) {
        let anchor = interpolatedPosition(at: click.anchor, samples: samples)
        spans.append(ActivitySpan(
          activity: .clicking(anchor: anchor), startSeconds: click.start,
          endSeconds: click.end, anchor: anchor))
        t = click.end
        continue
      }

      if let typing = typingIntervals.first(where: { t >= $0.start && t < $0.end }) {
        let anchor = interpolatedPosition(at: typing.anchor, samples: samples)
        spans.append(ActivitySpan(
          activity: .typing(anchor: anchor), startSeconds: typing.start,
          endSeconds: typing.end, anchor: anchor))
        t = typing.end
        continue
      }

      if let drag = dragIntervals.first(where: { t >= $0.start && t < $0.end }) {
        let anchor = interpolatedPosition(at: (drag.start + drag.end) / 2, samples: samples)
        spans.append(ActivitySpan(
          activity: .dragging, startSeconds: drag.start,
          endSeconds: drag.end, anchor: anchor))
        t = drag.end
        continue
      }

      let speed = cursorSpeed(at: t, samples: samples)

      if speed > config.navigationSpeedThreshold {
        let navStart = t
        var navEnd = t
        let navCap = nextEventBoundary(
          after: t, clicks: clickIntervals, typing: typingIntervals, drags: dragIntervals)
        while navEnd < durationSeconds {
          if let cap = navCap, navEnd >= cap { break }
          let s = cursorSpeed(at: navEnd, samples: samples)
          if s < config.navigationSpeedThreshold * 0.6 { break }
          navEnd += stepSeconds
        }
        navEnd = min(navEnd, durationSeconds)
        if navEnd - navStart >= config.navigationMinSeconds {
          let midAnchor = interpolatedPosition(at: (navStart + navEnd) / 2, samples: samples)
          spans.append(ActivitySpan(
            activity: .navigating, startSeconds: navStart,
            endSeconds: navEnd, anchor: midAnchor))
          t = navEnd
          continue
        }
      }

      if speed < config.idleSpeedThreshold {
        let idleStart = t
        var idleEnd = t
        let idleCap = nextEventBoundary(
          after: t, clicks: clickIntervals, typing: typingIntervals, drags: dragIntervals)
        while idleEnd < durationSeconds {
          if let cap = idleCap, idleEnd >= cap { break }
          let s = cursorSpeed(at: idleEnd, samples: samples)
          if s >= config.idleSpeedThreshold { break }
          idleEnd += stepSeconds
        }
        idleEnd = min(idleEnd, durationSeconds)
        if idleEnd - idleStart >= config.idleMinSeconds {
          let direction = motionDirection(from: idleStart, to: idleEnd, samples: samples)
          let isVerticalScroll = abs(direction.y) > config.scrollInferenceVerticalThreshold
            && abs(direction.x) < 0.2
          let anchor = interpolatedPosition(at: (idleStart + idleEnd) / 2, samples: samples)
          let activity: UserActivity = isVerticalScroll
            ? .scrolling(anchor: anchor) : .idle
          spans.append(ActivitySpan(
            activity: activity, startSeconds: idleStart,
            endSeconds: idleEnd, anchor: anchor))
          t = idleEnd
          continue
        }
      }

      t += stepSeconds
    }

    return mergeAdjacentSpans(spans)
  }

  // MARK: - Interval extraction

  private struct TimeInterval: Equatable {
    var start: Double
    var end: Double
    var anchor: Double
  }

  private static func extractClickIntervals(
    events: [RecordingProject.InputEvent], config: Config
  ) -> [TimeInterval] {
    let downs = events.filter { $0.kind == .mouseDown }
    return downs.map { event in
      let t = event.timeSeconds
      return TimeInterval(
        start: max(0, t - config.clickWindowSeconds * 0.3),
        end: t + config.clickWindowSeconds * 0.7,
        anchor: t)
    }
  }

  private static func extractTypingIntervals(
    events: [RecordingProject.InputEvent], config: Config
  ) -> [TimeInterval] {
    let keyDowns = events
      .filter { $0.kind == .keyDown }
      .sorted { $0.timeSeconds < $1.timeSeconds }
    guard !keyDowns.isEmpty else { return [] }

    var intervals: [TimeInterval] = []
    var burstStart = keyDowns[0].timeSeconds
    var burstEnd = burstStart
    var count = 1

    for i in 1..<keyDowns.count {
      let t = keyDowns[i].timeSeconds
      if t - burstEnd <= config.typingBurstMaxGapSeconds {
        burstEnd = t
        count += 1
      } else {
        if count >= 3 {
          intervals.append(TimeInterval(
            start: burstStart, end: burstEnd + 0.3,
            anchor: (burstStart + burstEnd) / 2))
        }
        burstStart = t
        burstEnd = t
        count = 1
      }
    }
    if count >= 3 {
      intervals.append(TimeInterval(
        start: burstStart, end: burstEnd + 0.3,
        anchor: (burstStart + burstEnd) / 2))
    }
    return intervals
  }

  private static func extractDragIntervals(
    events: [RecordingProject.InputEvent],
    samples: [RecordingProject.CursorSample],
    config: Config
  ) -> [TimeInterval] {
    let mouseDowns = events.filter { $0.kind == .mouseDown }
      .sorted { $0.timeSeconds < $1.timeSeconds }
    let mouseUps = events.filter { $0.kind == .mouseUp }
      .sorted { $0.timeSeconds < $1.timeSeconds }

    var intervals: [TimeInterval] = []
    for down in mouseDowns {
      guard let up = mouseUps.first(where: { $0.timeSeconds > down.timeSeconds }) else { continue }
      let duration = up.timeSeconds - down.timeSeconds
      guard duration >= config.dragMinSeconds else { continue }
      let startPos = interpolatedPosition(at: down.timeSeconds, samples: samples)
      let endPos = interpolatedPosition(at: up.timeSeconds, samples: samples)
      let distance = simd_distance(startPos, endPos)
      guard distance > 0.03 else { continue }
      intervals.append(TimeInterval(
        start: down.timeSeconds, end: up.timeSeconds,
        anchor: (down.timeSeconds + up.timeSeconds) / 2))
    }
    return intervals
  }

  // MARK: - Cursor math

  static func interpolatedPosition(
    at t: Double, samples: [RecordingProject.CursorSample]
  ) -> simd_double2 {
    guard !samples.isEmpty else { return simd_double2(0.5, 0.5) }
    guard samples.count > 1 else {
      return simd_double2(samples[0].x, samples[0].y)
    }
    if t <= samples[0].timeSeconds {
      return simd_double2(samples[0].x, samples[0].y)
    }
    if t >= samples[samples.count - 1].timeSeconds {
      let last = samples[samples.count - 1]
      return simd_double2(last.x, last.y)
    }
    var lo = 0, hi = samples.count - 1
    while lo < hi - 1 {
      let mid = (lo + hi) / 2
      if samples[mid].timeSeconds <= t { lo = mid } else { hi = mid }
    }
    let s0 = samples[lo]
    let s1 = samples[hi]
    let dt = s1.timeSeconds - s0.timeSeconds
    guard dt > 1e-9 else { return simd_double2(s0.x, s0.y) }
    let u = (t - s0.timeSeconds) / dt
    return simd_double2(
      s0.x + (s1.x - s0.x) * u,
      s0.y + (s1.y - s0.y) * u)
  }

  private static func cursorSpeed(
    at t: Double, samples: [RecordingProject.CursorSample]
  ) -> Double {
    let dt = 1.0 / 30.0
    let p0 = interpolatedPosition(at: t - dt, samples: samples)
    let p1 = interpolatedPosition(at: t + dt, samples: samples)
    return simd_distance(p0, p1) / (2 * dt)
  }

  private static func motionDirection(
    from start: Double, to end: Double,
    samples: [RecordingProject.CursorSample]
  ) -> simd_double2 {
    let p0 = interpolatedPosition(at: start, samples: samples)
    let p1 = interpolatedPosition(at: end, samples: samples)
    let d = p1 - p0
    let len = simd_length(d)
    guard len > 1e-9 else { return .zero }
    return d / len
  }

  private static func nextEventBoundary(
    after t: Double,
    clicks: [TimeInterval],
    typing: [TimeInterval],
    drags: [TimeInterval]
  ) -> Double? {
    var earliest: Double?
    for interval in clicks + typing + drags {
      guard interval.start > t else { continue }
      if earliest == nil || interval.start < earliest! {
        earliest = interval.start
      }
    }
    return earliest
  }

  private static func mergeAdjacentSpans(_ spans: [ActivitySpan]) -> [ActivitySpan] {
    guard !spans.isEmpty else { return [] }
    var merged: [ActivitySpan] = [spans[0]]
    for i in 1..<spans.count {
      let current = spans[i]
      var last = merged[merged.count - 1]
      if last.activity == current.activity && current.startSeconds - last.endSeconds < 0.08 {
        last.endSeconds = current.endSeconds
        last.anchor = (last.anchor + current.anchor) / 2
        merged[merged.count - 1] = last
      } else {
        merged.append(current)
      }
    }
    return merged
  }
}
