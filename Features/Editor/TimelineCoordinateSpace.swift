import CoreGraphics

struct TimelineViewport: Equatable {
  static let minZoomScale: Double = 1
  static let maxZoomScale: Double = 8

  let durationSeconds: Double
  let visibleWidth: CGFloat
  let zoomScale: Double
  let horizontalInset: CGFloat

  init(
    durationSeconds: Double,
    visibleWidth: CGFloat,
    zoomScale: Double,
    horizontalInset: CGFloat = EditorLayout.timelineLaneInsetX
  ) {
    self.durationSeconds = max(0, durationSeconds)
    self.visibleWidth = max(1, visibleWidth)
    self.zoomScale = Self.clampedZoomScale(zoomScale)
    self.horizontalInset = max(0, horizontalInset)
  }

  var contentWidth: CGFloat {
    max(1, visibleWidth * CGFloat(zoomScale))
  }

  var activeContentWidth: CGFloat {
    max(1, contentWidth - horizontalInset * 2)
  }

  var coordinateSpace: TimelineCoordinateSpace {
    TimelineCoordinateSpace(
      sourceDurationSeconds: durationSeconds,
      previewDurationSeconds: durationSeconds,
      timelineDurationSeconds: durationSeconds,
      width: activeContentWidth
    )
  }

  static func clampedZoomScale(_ value: Double) -> Double {
    min(max(value, minZoomScale), maxZoomScale)
  }

  func visibleRange(forOffsetX offsetX: CGFloat) -> TimelineVisibleRange {
    let maxOffset = max(0, contentWidth - visibleWidth)
    let offset = offsetX.clamped(to: 0...maxOffset)
    let startX = max(0, offset - horizontalInset)
    let endX = min(activeContentWidth, offset + visibleWidth - horizontalInset)
    return TimelineVisibleRange(
      startSeconds: coordinateSpace.timelineSeconds(forX: startX),
      endSeconds: coordinateSpace.timelineSeconds(forX: endX)
    )
  }

  func offsetX(centeredOn seconds: Double) -> CGFloat {
    let x = horizontalInset + coordinateSpace.timelineX(for: seconds)
    return (x - visibleWidth / 2).clamped(to: 0...max(0, contentWidth - visibleWidth))
  }

  func zoomed(_ nextZoomScale: Double, anchorSeconds: Double) -> TimelineViewport {
    TimelineViewport(
      durationSeconds: durationSeconds,
      visibleWidth: visibleWidth,
      zoomScale: nextZoomScale,
      horizontalInset: horizontalInset
    )
  }
}

struct TimelineVisibleRange: Equatable {
  var startSeconds: Double
  var endSeconds: Double

  var durationSeconds: Double {
    max(0, endSeconds - startSeconds)
  }
}

struct TimelineScrollState: Equatable {
  var contentOffsetX: CGFloat = 0
  var visibleWidth: CGFloat = 1
  var contentWidth: CGFloat = 1
  var isUserScrolling = false
  var followPlayhead = true
}

struct TimelineSnapTarget: Equatable {
  var seconds: Double
  var label: String = ""

  init(seconds: Double, label: String = "") {
    self.seconds = seconds
    self.label = label
  }
}

struct TimelineSnapResult: Equatable {
  var seconds: Double
  var target: TimelineSnapTarget?

  var didSnap: Bool {
    target != nil
  }
}

struct TimelineSnapPolicy: Equatable {
  var enabled: Bool
  var targets: [TimelineSnapTarget]
  var thresholdSeconds: Double
  var validRange: ClosedRange<Double>

  func snappedResult(for candidateSeconds: Double) -> TimelineSnapResult {
    let clampedCandidate = candidateSeconds.clamped(to: validRange)
    guard enabled, thresholdSeconds > 0 else {
      return TimelineSnapResult(seconds: clampedCandidate, target: nil)
    }

    let validTargets = targets
      .map { target in
        TimelineSnapTarget(seconds: target.seconds.clamped(to: validRange), label: target.label)
      }
      .filter { abs($0.seconds - clampedCandidate) <= thresholdSeconds }

    guard let nearest = validTargets.min(by: { lhs, rhs in
      let lhsDistance = abs(lhs.seconds - clampedCandidate)
      let rhsDistance = abs(rhs.seconds - clampedCandidate)
      if abs(lhsDistance - rhsDistance) > 1e-9 {
        return lhsDistance < rhsDistance
      }
      return lhs.seconds < rhs.seconds
    }) else {
      return TimelineSnapResult(seconds: clampedCandidate, target: nil)
    }

    return TimelineSnapResult(seconds: nearest.seconds.clamped(to: validRange), target: nearest)
  }

  func snappedSeconds(for candidateSeconds: Double) -> Double {
    snappedResult(for: candidateSeconds).seconds
  }
}

struct TimelineSnapFeedback: Equatable {
  var seconds: Double
  var label: String
}

struct TimelineThumbnailStripModel: Equatable {
  enum State: Equatable {
    case empty
    case loading
    case ready([TimelineThumbnail])
    case failed(String)
  }

  var visibleRange: TimelineVisibleRange
  var requestedTimes: [Double]
  var state: State

  static func plannedTimes(
    visibleRange: TimelineVisibleRange,
    durationSeconds: Double,
    targetPixelWidth: CGFloat,
    thumbnailWidth: CGFloat = 96
  ) -> [Double] {
    let duration = max(0, durationSeconds)
    let start = min(max(0, visibleRange.startSeconds), duration)
    let end = min(max(start, visibleRange.endSeconds), duration)
    guard end > start, targetPixelWidth > 0, thumbnailWidth > 0 else { return [] }
    let count = max(1, min(80, Int(ceil(targetPixelWidth / thumbnailWidth)) + 2))
    if count == 1 { return [(start + end) / 2] }
    return (0..<count).map { index in
      start + (end - start) * Double(index) / Double(count - 1)
    }
  }
}

struct TimelineThumbnail: Equatable, Identifiable {
  var id: Double { seconds }
  var seconds: Double
}

struct TimelineWaveformModel: Equatable {
  enum State: Equatable {
    case empty
    case loading
    case ready([Float])
    case failed(String)
  }

  var visibleRange: TimelineVisibleRange
  var state: State

  static func downsample(_ samples: [Float], targetCount: Int) -> [Float] {
    let count = max(0, targetCount)
    guard count > 0, !samples.isEmpty else { return [] }
    if samples.count <= count {
      return samples.map { min(max($0, 0), 1) }
    }
    return (0..<count).map { index in
      let start = Int(Double(index) / Double(count) * Double(samples.count))
      let end = max(start + 1, Int(Double(index + 1) / Double(count) * Double(samples.count)))
      let window = samples[start..<min(end, samples.count)]
      return window.reduce(Float(0)) { max($0, min(max($1, 0), 1)) }
    }
  }
}

struct TimelineCoordinateSpace {
  let sourceDurationSeconds: Double
  let previewDurationSeconds: Double
  let timelineDurationSeconds: Double
  let width: CGFloat

  init(
    sourceDurationSeconds: Double,
    previewDurationSeconds: Double,
    timelineDurationSeconds: Double? = nil,
    width: CGFloat
  ) {
    self.sourceDurationSeconds = sourceDurationSeconds
    self.previewDurationSeconds = previewDurationSeconds
    self.timelineDurationSeconds = timelineDurationSeconds ?? previewDurationSeconds
    self.width = width
  }

  func sourceX(for sourceSeconds: Double) -> CGFloat {
    x(for: sourceSeconds, durationSeconds: sourceDurationSeconds)
  }

  func sourceSeconds(forX x: CGFloat) -> Double {
    seconds(forX: x, durationSeconds: sourceDurationSeconds)
  }

  func previewX(for previewSeconds: Double) -> CGFloat {
    x(for: previewSeconds, durationSeconds: previewDurationSeconds)
  }

  func previewSeconds(forX x: CGFloat) -> Double {
    seconds(forX: x, durationSeconds: previewDurationSeconds)
  }

  func timelineX(for timelineSeconds: Double) -> CGFloat {
    x(for: timelineSeconds, durationSeconds: timelineDurationSeconds)
  }

  func timelineSeconds(forX x: CGFloat) -> Double {
    seconds(forX: x, durationSeconds: timelineDurationSeconds)
  }

  func timelineSpanWidth(
    startSeconds: Double,
    endSeconds: Double,
    minimumWidth: CGFloat = 0
  ) -> CGFloat {
    spanWidth(
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      durationSeconds: timelineDurationSeconds,
      minimumWidth: minimumWidth
    )
  }

  func frameX(for timelineSeconds: Double, itemWidth: CGFloat) -> CGFloat {
    timelineX(for: timelineSeconds)
      .clamped(to: 0...max(0, width - itemWidth))
  }

  func sourceSeconds(
    forPreviewSeconds previewSeconds: Double,
    sourceStartSeconds: Double,
    sourceEndSeconds: Double,
    playbackRate: Double = 1
  ) -> Double {
    let range = normalizedSourceRange(start: sourceStartSeconds, end: sourceEndSeconds)
    let rate = normalizedPlaybackRate(playbackRate)
    let sourceOffset = max(0, previewSeconds) * rate
    return min(range.end, range.start + sourceOffset)
  }

  func previewSeconds(
    forSourceSeconds sourceSeconds: Double,
    sourceStartSeconds: Double,
    sourceEndSeconds: Double,
    playbackRate: Double = 1
  ) -> Double {
    let range = normalizedSourceRange(start: sourceStartSeconds, end: sourceEndSeconds)
    let rate = normalizedPlaybackRate(playbackRate)
    let clamped = min(max(sourceSeconds, range.start), range.end)
    return (clamped - range.start) / rate
  }

  static func previewDurationSeconds(
    sourceStartSeconds: Double,
    sourceEndSeconds: Double,
    playbackRate: Double = 1
  ) -> Double {
    let rangeDuration = max(0, sourceEndSeconds - sourceStartSeconds)
    let rate = max(playbackRate, 1e-9)
    return rangeDuration / rate
  }

  private func x(for seconds: Double, durationSeconds: Double) -> CGFloat {
    guard durationSeconds > 0, width > 0 else { return 0 }
    let clamped = min(max(seconds, 0), durationSeconds)
    return CGFloat(clamped / durationSeconds) * width
  }

  private func seconds(forX x: CGFloat, durationSeconds: Double) -> Double {
    guard durationSeconds > 0, width > 0 else { return 0 }
    let ratio = min(max(x / width, 0), 1)
    return Double(ratio) * durationSeconds
  }

  private func spanWidth(
    startSeconds: Double,
    endSeconds: Double,
    durationSeconds: Double,
    minimumWidth: CGFloat
  ) -> CGFloat {
    guard durationSeconds > 0, width > 0 else { return minimumWidth }
    let start = max(0, min(durationSeconds, startSeconds))
    let end = max(start, min(durationSeconds, endSeconds))
    return max(minimumWidth, CGFloat((end - start) / durationSeconds) * width)
  }

  private func normalizedSourceRange(start: Double, end: Double) -> (start: Double, end: Double) {
    let safeStart = max(0, min(sourceDurationSeconds, start))
    let safeEnd = max(safeStart, min(sourceDurationSeconds, end))
    return (safeStart, safeEnd)
  }

  private func normalizedPlaybackRate(_ playbackRate: Double) -> Double {
    max(playbackRate, 1e-9)
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
