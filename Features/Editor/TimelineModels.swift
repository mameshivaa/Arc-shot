import SwiftUI

struct EditorTimelineCommandContext {
  var canDeleteSelection: Bool
  var canUseSingleClipTrim: Bool
  var snapEnabled: Bool
  var zoomDescription: String
  var togglePlayback: () -> Void
  var deleteSelection: () -> Void
  var zoomIn: () -> Void
  var zoomOut: () -> Void
  var zoomToFit: () -> Void
  var toggleSnap: () -> Void
  var setInAtPlayhead: () -> Void
  var setOutAtPlayhead: () -> Void
  var selectNext: () -> Void
  var selectPrevious: () -> Void
  var clearSelection: () -> Void
}

private struct EditorTimelineCommandContextKey: FocusedValueKey {
  typealias Value = EditorTimelineCommandContext
}

extension FocusedValues {
  var editorTimelineCommandContext: EditorTimelineCommandContext? {
    get { self[EditorTimelineCommandContextKey.self] }
    set { self[EditorTimelineCommandContextKey.self] = newValue }
  }
}

enum EditorSegmentRange {
  static func playheadBased(
    at rawStart: Double,
    preferredDuration: Double,
    totalDuration: Double,
    minimumDuration: Double
  ) -> (start: Double, end: Double)? {
    guard totalDuration.isFinite,
      preferredDuration.isFinite,
      minimumDuration > 0,
      totalDuration >= minimumDuration
    else { return nil }
    let segmentDuration = min(max(preferredDuration, minimumDuration), totalDuration)
    let latestStart = max(0, totalDuration - segmentDuration)
    let start = min(max(0, rawStart), latestStart)
    let end = min(totalDuration, start + segmentDuration)
    guard end - start >= minimumDuration else { return nil }
    return (start, end)
  }

  static func appendBased(
    after rawStart: Double,
    preferredDuration: Double,
    totalDuration: Double,
    minimumDuration: Double
  ) -> (start: Double, end: Double)? {
    guard totalDuration.isFinite,
      preferredDuration.isFinite,
      minimumDuration > 0,
      totalDuration >= minimumDuration
    else { return nil }
    let start = max(0, min(rawStart, totalDuration))
    let end = min(totalDuration, start + max(preferredDuration, minimumDuration))
    guard end - start >= minimumDuration else { return nil }
    return (start, end)
  }

  static func playheadBasedAvoidingZoomOverlaps(
    at rawStart: Double,
    preferredDuration: Double,
    totalDuration: Double,
    minimumDuration: Double,
    peers: [TimelineZoomOverlapPolicy.Interval]
  ) -> (start: Double, end: Double)? {
    let gaps = TimelineZoomOverlapPolicy.gaps(
      in: totalDuration,
      occupied: peers,
      minimumGap: minimumDuration
    )
    guard let gap = TimelineZoomOverlapPolicy.preferredGap(
      containing: rawStart,
      preferredDuration: preferredDuration,
      minimumDuration: minimumDuration,
      gaps: gaps
    ) else { return nil }
    let duration = min(max(preferredDuration, minimumDuration), gap.end - gap.start)
    let latestStart = max(gap.start, gap.end - duration)
    let start = min(max(gap.start, rawStart), latestStart)
    let end = start + duration
    guard end - start >= minimumDuration else { return nil }
    return (start, end)
  }
}

enum TimelineZoomOverlapPolicy {
  struct Interval: Equatable {
    var start: Double
    var end: Double
  }

  static func peerIntervals(
    excludingID: UUID,
    segments: [RecordingProject.ZoomSegment]
  ) -> [Interval] {
    segments
      .filter { $0.id != excludingID }
      .map { Interval(start: $0.startSeconds, end: $0.endSeconds) }
      .filter { $0.end > $0.start }
      .sorted { $0.start < $1.start }
  }

  static func gaps(
    in totalDuration: Double,
    occupied: [Interval],
    minimumGap: Double
  ) -> [Interval] {
    guard totalDuration >= minimumGap else { return [] }
    let sorted = occupied.sorted { $0.start < $1.start }
    var gaps: [Interval] = []
    var cursor = 0.0
    for interval in sorted {
      if interval.start - cursor >= minimumGap {
        gaps.append(Interval(start: cursor, end: interval.start))
      }
      cursor = max(cursor, interval.end)
    }
    if totalDuration - cursor >= minimumGap {
      gaps.append(Interval(start: cursor, end: totalDuration))
    }
    return gaps
  }

  static func preferredGap(
    containing playhead: Double,
    preferredDuration: Double,
    minimumDuration: Double,
    gaps: [Interval]
  ) -> Interval? {
    let minimum = max(minimumDuration, 0.001)
    let fitting = gaps.filter { $0.end - $0.start >= minimum }
    guard !fitting.isEmpty else { return nil }
    if let containing = fitting.first(where: { playhead >= $0.start && playhead <= $0.end }) {
      return containing
    }
    return fitting.min(by: { lhs, rhs in
      let lhsDistance = playhead < lhs.start
        ? lhs.start - playhead
        : (playhead > lhs.end ? playhead - lhs.end : 0)
      let rhsDistance = playhead < rhs.start
        ? rhs.start - playhead
        : (playhead > rhs.end ? playhead - rhs.end : 0)
      if abs(lhsDistance - rhsDistance) <= 1e-9 {
        let lhsStartsAfterPlayhead = lhs.start >= playhead
        let rhsStartsAfterPlayhead = rhs.start >= playhead
        if lhsStartsAfterPlayhead != rhsStartsAfterPlayhead {
          return lhsStartsAfterPlayhead
        }
        return lhs.start < rhs.start
      }
      return lhsDistance < rhsDistance
    })
  }

  static func overlaps(_ start: Double, _ end: Double, with peer: Interval) -> Bool {
    start < peer.end - 1e-9 && end > peer.start + 1e-9
  }

  static func resolve(
    _ range: TimelineEditableRange,
    mode: EffectRangeEditMode,
    peers: [Interval],
    totalDuration: Double,
    moveReferenceStart: Double? = nil
  ) -> TimelineEditableRange {
    guard range.kind == .zoom, !peers.isEmpty else {
      return range.sanitized(durationSeconds: totalDuration)
    }

    var resolved = range.sanitized(durationSeconds: totalDuration)
    for _ in 0..<(peers.count + 1) {
      guard let conflict = peers.first(where: {
        overlaps(resolved.startSeconds, resolved.endSeconds, with: $0)
      }) else {
        return resolved
      }
      resolved = resolved.resolvingOverlap(
        with: conflict,
        mode: mode,
        totalDuration: totalDuration,
        moveReferenceStart: moveReferenceStart
      )
    }
    return nonOverlappingFallback(for: resolved, peers: peers, totalDuration: totalDuration)
  }

  private static func nonOverlappingFallback(
    for range: TimelineEditableRange,
    peers: [Interval],
    totalDuration: Double
  ) -> TimelineEditableRange {
    let availableGaps = gaps(
      in: totalDuration,
      occupied: peers,
      minimumGap: range.minDuration
    )
    let anchor = (range.startSeconds + range.endSeconds) / 2
    guard let gap = preferredGap(
      containing: anchor,
      preferredDuration: range.endSeconds - range.startSeconds,
      minimumDuration: range.minDuration,
      gaps: availableGaps
    ) else {
      return range.sanitized(durationSeconds: totalDuration)
    }

    let duration = min(max(range.minDuration, range.endSeconds - range.startSeconds), gap.end - gap.start)
    let latestStart = max(gap.start, gap.end - duration)
    let start = min(max(gap.start, range.startSeconds), latestStart)
    return range
      .movingStart(to: start, durationSeconds: totalDuration)
      .trimmingTrailing(to: start + duration, durationSeconds: totalDuration)
  }
}

enum TimelineEffectRowLayout {
  /// Assigns overlapping effect segments to separate sub-rows within a lane.
  static func assignments(
    for segments: [EditorTimelineEffectSegment],
    maxRows: Int = Int.max
  ) -> [String: Int] {
    let cappedMaxRows = max(1, maxRows)
    let sorted = segments.sorted { lhs, rhs in
      if lhs.startSeconds != rhs.startSeconds {
        return lhs.startSeconds < rhs.startSeconds
      }
      if lhs.endSeconds != rhs.endSeconds {
        return lhs.endSeconds < rhs.endSeconds
      }
      return lhs.id < rhs.id
    }

    var rowEndTimes: [Double] = []
    var result: [String: Int] = [:]
    for segment in sorted {
      var row = 0
      while row < rowEndTimes.count, segment.startSeconds < rowEndTimes[row] - 1e-9 {
        row += 1
      }
      if row >= cappedMaxRows {
        row = cappedMaxRows - 1
      }
      if row == rowEndTimes.count {
        rowEndTimes.append(segment.endSeconds)
      } else {
        rowEndTimes[row] = max(rowEndTimes[row], segment.endSeconds)
      }
      result[segment.id] = row
    }
    return result
  }

  static func rowCount(for segments: [EditorTimelineEffectSegment]) -> Int {
    guard !segments.isEmpty else { return 1 }
    let assignments = assignments(for: segments)
    return max(1, (assignments.values.max() ?? 0) + 1)
  }

  static func displayRowCount(
    for segments: [EditorTimelineEffectSegment],
    maxRows: Int
  ) -> Int {
    guard !segments.isEmpty else { return 1 }
    let assignments = assignments(for: segments, maxRows: maxRows)
    return max(1, (assignments.values.max() ?? 0) + 1)
  }
}

private extension TimelineEditableRange {
  func resolvingOverlap(
    with peer: TimelineZoomOverlapPolicy.Interval,
    mode: EffectRangeEditMode,
    totalDuration: Double,
    moveReferenceStart: Double? = nil
  ) -> TimelineEditableRange {
    var copy = self
    let span = max(minDuration, endSeconds - startSeconds)

    switch mode {
    case .leading:
      if copy.startSeconds < peer.end {
        copy = copy.trimmingLeading(to: peer.end, durationSeconds: totalDuration)
      }
    case .trailing:
      if copy.endSeconds > peer.start {
        copy = copy.trimmingTrailing(to: peer.start, durationSeconds: totalDuration)
      }
    case .move:
      let afterStart = peer.end
      let beforeStart = max(0, peer.start - span)
      let referenceStart = moveReferenceStart ?? copy.startSeconds
      let preferAfter: Bool
      if referenceStart >= peer.end - 1e-9 {
        preferAfter = true
      } else if referenceStart + span <= peer.start + 1e-9 {
        preferAfter = false
      } else {
        preferAfter = abs(referenceStart - afterStart) <= abs(referenceStart - beforeStart)
      }
      if preferAfter {
        copy = copy.movingStart(to: afterStart, durationSeconds: totalDuration)
        if copy.endSeconds - copy.startSeconds < minDuration {
          copy.endSeconds = min(totalDuration, copy.startSeconds + span)
        }
      } else {
        copy = copy.movingStart(to: beforeStart, durationSeconds: totalDuration)
      }
    case .rampIn, .rampOut:
      break
    }

    return copy.sanitized(durationSeconds: totalDuration)
  }
}

enum EditorTimelineEffectSelection: Equatable {
  case zoom(UUID)
  case caption(UUID)
  case mask(UUID)
  case camera(UUID)
  case audio(UUID)

  @discardableResult
  static func remove(
    _ selection: EditorTimelineEffectSelection,
    from project: inout RecordingProject,
    durationSeconds: Double
  ) -> Bool {
    switch selection {
    case .zoom(let id):
      let oldSegments = project.zoomSegments
      project.zoomSegments.removeAll { $0.id == id }
      project.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
        project.zoomSegments,
        durationSeconds: durationSeconds
      )
      return oldSegments != project.zoomSegments
    case .caption(let id):
      let oldSegments = project.captionTrack.segments
      project.captionTrack.segments.removeAll { $0.id == id }
      return oldSegments != project.captionTrack.segments
    case .mask(let id):
      let oldMasks = project.visualMasks
      project.visualMasks.removeAll { $0.id == id }
      project.visualMasks = RecordingProject.sanitizedVisualMasks(
        project.visualMasks,
        durationSeconds: durationSeconds
      )
      return oldMasks != project.visualMasks
    case .camera(let id):
      let oldSegments = project.cameraLayoutSegments
      project.cameraLayoutSegments.removeAll { $0.id == id }
      project.cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
        project.cameraLayoutSegments,
        durationSeconds: durationSeconds
      )
      return oldSegments != project.cameraLayoutSegments
    case .audio(let id):
      guard let segment = project.audioTimelineSegments.first(where: { $0.id == id }) else { return false }
      let oldSegments = project.audioTimelineSegments
      project.audioTimelineSegments = project.audioTimelineSegments.map { item in
        guard item.id == id else { return item }
        return RecordingProject.AudioTimelineSegment(
          id: item.id,
          role: item.role,
          startSeconds: 0,
          endSeconds: max(RecordingProject.TimelineMediaEditing.minAudioSpanSeconds, durationSeconds)
        )
      }
      project.audioTimelineSegments = RecordingProject.sanitizedAudioTimelineSegments(
        project.audioTimelineSegments,
        durationSeconds: durationSeconds,
        settings: project.audioTrackSettings
      )
      return oldSegments != project.audioTimelineSegments
        || segment.startSeconds > 0
        || abs(segment.endSeconds - durationSeconds) > 1e-6
    }
  }
}

enum TimelineEditableRangeKind: Equatable {
  case zoom
  case caption
  case mask
  case camera
  case audio
}

extension EditorTimelineEffectSelection {
  var id: UUID {
    switch self {
    case .zoom(let id), .caption(let id), .mask(let id), .camera(let id), .audio(let id):
      return id
    }
  }

  var rangeKind: TimelineEditableRangeKind {
    switch self {
    case .zoom:
      return .zoom
    case .caption:
      return .caption
    case .mask:
      return .mask
    case .camera:
      return .camera
    case .audio:
      return .audio
    }
  }
}

enum EffectRangeEditMode: Equatable {
  case leading
  case trailing
  case move
  /// ズームの寄り（イン）ランプ終端ハンドル。
  case rampIn
  /// ズームの引き（アウト）ランプ始端ハンドル。
  case rampOut

  static func modeForInteraction(startX: CGFloat, visualWidth: CGFloat, edgeHitWidth: CGFloat) -> EffectRangeEditMode {
    let edgeHitWidth = max(0, edgeHitWidth)
    if startX <= edgeHitWidth {
      return .leading
    }
    if startX >= max(0, visualWidth - edgeHitWidth) {
      return .trailing
    }
    return .move
  }
}

struct TimelineEditableRange: Identifiable, Equatable {
  var id: UUID
  var kind: TimelineEditableRangeKind
  var startSeconds: Double
  var inEndSeconds: Double?
  var outStartSeconds: Double?
  var endSeconds: Double
  var minDuration: Double
  var canTrim: Bool
  var canMove: Bool

  init(
    id: UUID,
    kind: TimelineEditableRangeKind,
    startSeconds: Double,
    inEndSeconds: Double? = nil,
    outStartSeconds: Double? = nil,
    endSeconds: Double,
    minDuration: Double,
    canTrim: Bool,
    canMove: Bool
  ) {
    self.id = id
    self.kind = kind
    self.startSeconds = startSeconds
    self.inEndSeconds = inEndSeconds
    self.outStartSeconds = outStartSeconds
    self.endSeconds = endSeconds
    self.minDuration = minDuration
    self.canTrim = canTrim
    self.canMove = canMove
  }

  var durationSeconds: Double {
    max(0, endSeconds - startSeconds)
  }

  static func screenStudioTiming(startSeconds: Double, endSeconds: Double) -> (inEndSeconds: Double, outStartSeconds: Double) {
    let start = min(startSeconds, endSeconds)
    let end = max(startSeconds, endSeconds)
    let duration = max(0, end - start)
    let ramp = min(0.35, duration * 0.25, duration / 2)
    return (start + ramp, end - ramp)
  }

  func applyingScreenStudioZoomTiming() -> TimelineEditableRange {
    guard kind == .zoom else { return self }
    var copy = self
    let timing = Self.screenStudioTiming(startSeconds: startSeconds, endSeconds: endSeconds)
    copy.inEndSeconds = timing.inEndSeconds
    copy.outStartSeconds = timing.outStartSeconds
    return copy
  }

  func applyingTimelineDrag(
    mode: EffectRangeEditMode,
    translationX: CGFloat,
    timelineDurationSeconds: Double,
    activeWidth: CGFloat,
    durationSeconds totalDuration: Double
  ) -> TimelineEditableRange {
    let deltaSeconds = Double(translationX / max(activeWidth, 1)) * max(0, timelineDurationSeconds)
    switch mode {
    case .leading:
      guard canTrim else { return self }
      return trimmingLeading(to: startSeconds + deltaSeconds, durationSeconds: totalDuration)
    case .trailing:
      guard canTrim else { return self }
      return trimmingTrailing(to: endSeconds + deltaSeconds, durationSeconds: totalDuration)
    case .move:
      guard canMove else { return self }
      return moving(by: deltaSeconds, durationSeconds: totalDuration)
    case .rampIn:
      return movingInEnd(to: (inEndSeconds ?? startSeconds) + deltaSeconds, durationSeconds: totalDuration)
    case .rampOut:
      return movingOutStart(to: (outStartSeconds ?? endSeconds) + deltaSeconds, durationSeconds: totalDuration)
    }
  }

  func trimmingLeading(to proposedStart: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    var copy = self
    let duration = max(0, totalDuration)
    guard duration >= minDuration else {
      copy.startSeconds = 0
      copy.endSeconds = duration
      return copy
    }
    let maxStart = max(0, min(endSeconds - minDuration, duration))
    let previousStart = copy.startSeconds
    copy.startSeconds = Self.clamp(proposedStart, to: 0...maxStart)
    if kind == .zoom {
      let delta = copy.startSeconds - previousStart
      if abs(delta) > 1e-12 {
        if let inEndSeconds {
          copy.inEndSeconds = inEndSeconds + delta
        }
        if let outStartSeconds {
          copy.outStartSeconds = outStartSeconds + delta
        }
      }
    }
    if let shiftedInEndSeconds = copy.inEndSeconds {
      copy.inEndSeconds = max(copy.startSeconds, min(copy.endSeconds, shiftedInEndSeconds))
    }
    if let shiftedOutStartSeconds = copy.outStartSeconds {
      copy.outStartSeconds = max(copy.inEndSeconds ?? copy.startSeconds, min(copy.endSeconds, shiftedOutStartSeconds))
    }
    copy.endSeconds = max(copy.startSeconds + minDuration, min(endSeconds, duration))
    return copy
  }

  func trimmingTrailing(to proposedEnd: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    var copy = self
    let duration = max(0, totalDuration)
    guard duration >= minDuration else {
      copy.startSeconds = 0
      copy.endSeconds = duration
      return copy
    }
    let minEnd = min(duration, startSeconds + minDuration)
    let previousEnd = copy.endSeconds
    let previousStart = copy.startSeconds
    copy.endSeconds = Self.clamp(proposedEnd, to: minEnd...duration)
    if kind == .zoom {
      let endDelta = copy.endSeconds - previousEnd
      if abs(endDelta) > 1e-12, let outStartSeconds {
        copy.outStartSeconds = outStartSeconds + endDelta
      }
    }
    copy.startSeconds = max(0, min(startSeconds, copy.endSeconds - minDuration))
    if kind == .zoom {
      let startDelta = copy.startSeconds - previousStart
      if abs(startDelta) > 1e-12, let inEndSeconds {
        copy.inEndSeconds = inEndSeconds + startDelta
      }
    }
    if let shiftedInEndSeconds = copy.inEndSeconds {
      copy.inEndSeconds = max(copy.startSeconds, min(copy.endSeconds, shiftedInEndSeconds))
    }
    if let shiftedOutStartSeconds = copy.outStartSeconds {
      copy.outStartSeconds = max(copy.inEndSeconds ?? copy.startSeconds, min(copy.endSeconds, shiftedOutStartSeconds))
    }
    return copy
  }

  func moving(by deltaSeconds: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    movingStart(to: startSeconds + deltaSeconds, durationSeconds: totalDuration)
  }

  func movingStart(to proposedStart: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    var copy = self
    let totalDuration = max(0, totalDuration)
    guard totalDuration >= minDuration else {
      copy.startSeconds = 0
      copy.endSeconds = totalDuration
      return copy
    }
    let duration = max(minDuration, durationSeconds)
    let maxStart = max(0, totalDuration - duration)
    let start = Self.clamp(proposedStart, to: 0...maxStart)
    let delta = start - copy.startSeconds
    copy.startSeconds = start
    copy.endSeconds = min(totalDuration, start + duration)
    if let inEndSeconds {
      copy.inEndSeconds = inEndSeconds + delta
    }
    if let outStartSeconds {
      copy.outStartSeconds = outStartSeconds + delta
    }
    return copy
  }

  func movingInEnd(to proposedInEnd: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    var copy = sanitized(durationSeconds: totalDuration)
    guard copy.inEndSeconds != nil else { return copy }
    let lower = copy.startSeconds
    let upper = copy.outStartSeconds ?? copy.endSeconds
    copy.inEndSeconds = Self.clamp(proposedInEnd, to: lower...upper)
    return copy
  }

  func movingOutStart(to proposedOutStart: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    var copy = sanitized(durationSeconds: totalDuration)
    guard copy.outStartSeconds != nil else { return copy }
    let lower = copy.inEndSeconds ?? copy.startSeconds
    let upper = copy.endSeconds
    copy.outStartSeconds = Self.clamp(proposedOutStart, to: lower...upper)
    return copy
  }

  func resizingDuration(to proposedDuration: Double, durationSeconds totalDuration: Double) -> TimelineEditableRange {
    let duration = max(minDuration, proposedDuration)
    return trimmingTrailing(to: startSeconds + duration, durationSeconds: totalDuration)
  }

  func sanitized(durationSeconds totalDuration: Double) -> TimelineEditableRange {
    var copy = self
    let duration = max(0, totalDuration)
    guard duration >= minDuration else {
      copy.startSeconds = 0
      copy.endSeconds = duration
      return copy
    }
    copy.startSeconds = Self.clamp(copy.startSeconds, to: 0...duration)
    copy.endSeconds = Self.clamp(copy.endSeconds, to: 0...duration)
    if copy.endSeconds < copy.startSeconds {
      swap(&copy.startSeconds, &copy.endSeconds)
    }
    if copy.endSeconds - copy.startSeconds < minDuration {
      copy.endSeconds = min(duration, copy.startSeconds + minDuration)
      copy.startSeconds = min(copy.startSeconds, max(0, copy.endSeconds - minDuration))
    }
    if let inEndSeconds = copy.inEndSeconds {
      copy.inEndSeconds = Self.clamp(inEndSeconds, to: copy.startSeconds...copy.endSeconds)
    }
    if let outStartSeconds = copy.outStartSeconds {
      let lower = copy.inEndSeconds ?? copy.startSeconds
      copy.outStartSeconds = Self.clamp(outStartSeconds, to: lower...copy.endSeconds)
    }
    return copy
  }

  private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }
}

struct TimelineEffectRangeEditSession: Equatable {
  var id: UUID
  var kind: TimelineEditableRangeKind
  var mode: EffectRangeEditMode
  var original: TimelineEditableRange
  var live: TimelineEditableRange

  var hasLiveChanges: Bool {
    abs(live.startSeconds - original.startSeconds) > 1e-6
      || abs(live.endSeconds - original.endSeconds) > 1e-6
      || abs((live.inEndSeconds ?? live.startSeconds) - (original.inEndSeconds ?? original.startSeconds)) > 1e-6
      || abs((live.outStartSeconds ?? live.endSeconds) - (original.outStartSeconds ?? original.endSeconds)) > 1e-6
  }

  func matches(selection: EditorTimelineEffectSelection?) -> Bool {
    guard let selection else { return false }
    return id == selection.id && kind == selection.rangeKind
  }

  static func update(
    current: TimelineEffectRangeEditSession?,
    range: TimelineEditableRange,
    startX: CGFloat,
    visualWidth: CGFloat,
    edgeHitWidth: CGFloat,
    translationX: CGFloat,
    timelineDurationSeconds: Double,
    activeWidth: CGFloat,
    durationSeconds totalDuration: Double
  ) -> (session: TimelineEffectRangeEditSession, didBegin: Bool) {
    let isSameSession = current?.id == range.id && current?.kind == range.kind
    let mode = isSameSession
      ? (current?.mode ?? .move)
      : EffectRangeEditMode.modeForInteraction(
        startX: startX,
        visualWidth: visualWidth,
        edgeHitWidth: edgeHitWidth
      )
    let original = isSameSession ? (current?.original ?? range) : range
    let live = original.applyingTimelineDrag(
      mode: mode,
      translationX: translationX,
      timelineDurationSeconds: timelineDurationSeconds,
      activeWidth: activeWidth,
      durationSeconds: totalDuration
    )
    return (
      TimelineEffectRangeEditSession(
        id: range.id,
        kind: range.kind,
        mode: mode,
        original: original,
        live: live
      ),
      !isSameSession
    )
  }

  func applyingFinalDrag(
    translationX: CGFloat,
    timelineDurationSeconds: Double,
    activeWidth: CGFloat,
    durationSeconds totalDuration: Double
  ) -> TimelineEffectRangeEditSession {
    var copy = self
    copy.live = original.applyingTimelineDrag(
      mode: mode,
      translationX: translationX,
      timelineDurationSeconds: timelineDurationSeconds,
      activeWidth: activeWidth,
      durationSeconds: totalDuration
    )
    return copy
  }
}

struct TimelineAudioRoleStatus: Identifiable, Equatable {
  var id: RecordingProject.AudioTrackSettings.Role
  var title: String
  var shortTitle: String
  var isAvailable: Bool
  var isEnabled: Bool
  var volume: Double

  var displayValue: String {
    guard isAvailable else { return "未接続" }
    guard isEnabled else { return "Mute" }
    return "\(Int((volume * 100).rounded()))%"
  }

  var accessibilityValue: String {
    guard isAvailable else { return "\(title) Disconnected" }
    guard isEnabled else { return "\(title) Muted" }
    return "\(title) Volume \(Int((volume * 100).rounded()))%"
  }

  static func statuses(for settings: RecordingProject.AudioTrackSettings) -> [TimelineAudioRoleStatus] {
    let recordedRoles = settings.recordedTrackRoles
    return [
      TimelineAudioRoleStatus(
        id: .microphone,
        title: "Microphone",
        shortTitle: "Mic",
        isAvailable: recordedRoles?.contains(.microphone) ?? true,
        isEnabled: settings.microphone.isEnabled,
        volume: settings.microphone.volume
      ),
      TimelineAudioRoleStatus(
        id: .system,
        title: "System audio",
        shortTitle: "Sys",
        isAvailable: recordedRoles?.contains(.system) ?? true,
        isEnabled: settings.system.isEnabled,
        volume: settings.system.volume
      ),
      TimelineAudioRoleStatus(
        id: .backgroundMusic,
        title: "Background music",
        shortTitle: "BGM",
        isAvailable: settings.backgroundMusicURL != nil,
        isEnabled: settings.backgroundMusic.isEnabled,
        volume: settings.backgroundMusic.volume
      )
    ]
  }
}

struct EditorTimelineEffectSegment: Identifiable, Equatable {
  enum Kind: Equatable {
    case zoom
    case caption
    case mask
    case camera
    case audio
  }

  var id: String
  var startSeconds: Double
  var endSeconds: Double
  var kind: Kind
  var selection: EditorTimelineEffectSelection?

  var minimumTimelineWidth: CGFloat {
    kind == .zoom
      ? EditorLayout.timelineMinimumZoomEffectSegmentWidth
      : EditorLayout.timelineMinimumEffectSegmentWidth
  }

  func timelineFrame(duration: Double, activeWidth: CGFloat) -> TimelineEffectSegmentFrame {
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: duration,
      previewDurationSeconds: duration,
      timelineDurationSeconds: duration,
      width: activeWidth
    )
    let width = space.timelineSpanWidth(
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      minimumWidth: minimumTimelineWidth
    )
    return TimelineEffectSegmentFrame(
      x: EditorLayout.timelineLaneInsetX + space.frameX(for: startSeconds, itemWidth: width),
      width: width
    )
  }

  static func displayedSegments(
    _ segments: [EditorTimelineEffectSegment],
    liveRange: TimelineEditableRange?
  ) -> [EditorTimelineEffectSegment] {
    guard let liveRange else { return segments }
    return segments.map { segment in
      guard segment.selection?.id == liveRange.id,
        segment.selection?.rangeKind == liveRange.kind
      else {
        return segment
      }
      var copy = segment
      copy.startSeconds = liveRange.startSeconds
      copy.endSeconds = liveRange.endSeconds
      return copy
    }
  }

  static func segments(project: RecordingProject, duration: Double) -> [EditorTimelineEffectSegment] {
    let mappings = project.timeline.singleEditableClip == nil
      ? project.timeline.timeMappings()
      : []
    var segments: [EditorTimelineEffectSegment] = []
    let zoomRanges = project.zoomSegments.flatMap { zoom in
      displayedRanges(
        id: zoom.id,
        startSeconds: zoom.startSeconds,
        endSeconds: zoom.endSeconds,
        minimumDuration: RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds,
        mappings: mappings
      )
    }

    for range in zoomRanges {
      segments.append(
        EditorTimelineEffectSegment(
          id: "zoom-\(range.id.uuidString)-\(range.index)",
          startSeconds: max(0, range.startSeconds),
          endSeconds: min(duration, range.endSeconds),
          kind: .zoom,
          selection: .zoom(range.id)
        )
      )
    }

    if project.captionTrack.isEnabled {
      for caption in project.captionTrack.segments where caption.endSeconds > caption.startSeconds {
        for range in displayedRanges(
          id: caption.id,
          startSeconds: caption.startSeconds,
          endSeconds: caption.endSeconds,
          minimumDuration: 0,
          mappings: mappings
        ) {
          segments.append(
            EditorTimelineEffectSegment(
              id: "caption-\(range.id.uuidString)-\(range.index)",
              startSeconds: max(0, range.startSeconds),
              endSeconds: min(duration, range.endSeconds),
              kind: .caption,
              selection: .caption(range.id)
            )
          )
        }
      }
    }

    for mask in project.visualMasks where mask.endSeconds > mask.startSeconds {
      for range in displayedRanges(
        id: mask.id,
        startSeconds: mask.startSeconds,
        endSeconds: mask.endSeconds,
        minimumDuration: RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds,
        mappings: mappings
      ) {
        segments.append(
          EditorTimelineEffectSegment(
            id: "mask-\(range.id.uuidString)-\(range.index)",
            startSeconds: max(0, range.startSeconds),
            endSeconds: min(duration, range.endSeconds),
            kind: .mask,
            selection: .mask(range.id)
          )
        )
      }
    }

    if project.secondaryRecording != nil {
      for camera in project.cameraLayoutSegments where camera.endSeconds > camera.startSeconds {
        for range in displayedRanges(
          id: camera.id,
          startSeconds: camera.startSeconds,
          endSeconds: camera.endSeconds,
          minimumDuration: RecordingProject.TimelineMediaEditing.minCameraSpanSeconds,
          mappings: mappings
        ) {
          segments.append(
            EditorTimelineEffectSegment(
              id: "camera-\(range.id.uuidString)-\(range.index)",
              startSeconds: max(0, range.startSeconds),
              endSeconds: min(duration, range.endSeconds),
              kind: .camera,
              selection: .camera(range.id)
            )
          )
        }
      }
    }

    for audio in project.audioTimelineSegments where audio.endSeconds > audio.startSeconds {
      for range in displayedRanges(
        id: audio.id,
        startSeconds: audio.startSeconds,
        endSeconds: audio.endSeconds,
        minimumDuration: RecordingProject.TimelineMediaEditing.minAudioSpanSeconds,
        mappings: mappings
      ) {
        segments.append(
          EditorTimelineEffectSegment(
            id: "audio-\(range.id.uuidString)-\(range.index)",
            startSeconds: max(0, range.startSeconds),
            endSeconds: min(duration, range.endSeconds),
            kind: .audio,
            selection: .audio(range.id)
          )
        )
      }
    }

    return segments
      .filter { $0.endSeconds > $0.startSeconds }
      .sorted { lhs, rhs in
        if lhs.startSeconds != rhs.startSeconds {
          return lhs.startSeconds < rhs.startSeconds
        }
        if lhs.endSeconds != rhs.endSeconds {
          return lhs.endSeconds < rhs.endSeconds
        }
        if lhs.kind.sortRank != rhs.kind.sortRank {
          return lhs.kind.sortRank < rhs.kind.sortRank
        }
        return lhs.id < rhs.id
      }
  }

  private struct DisplayedRange {
    var id: UUID
    var index: Int
    var startSeconds: Double
    var endSeconds: Double
  }

  private static func displayedRanges(
    id: UUID,
    startSeconds: Double,
    endSeconds: Double,
    minimumDuration: Double,
    mappings: [RecordingProject.TimelineTimeMapping]
  ) -> [DisplayedRange] {
    guard endSeconds > startSeconds else { return [] }
    guard !mappings.isEmpty else {
      return [
        DisplayedRange(
          id: id,
          index: 0,
          startSeconds: startSeconds,
          endSeconds: endSeconds
        ),
      ]
    }

    return mappings.enumerated().compactMap { index, mapping in
      let sourceStart = max(startSeconds, mapping.sourceStartSeconds)
      let sourceEnd = min(endSeconds, mapping.sourceEndSeconds)
      guard sourceEnd - sourceStart >= minimumDuration,
        let timelineStart = mapping.timelineSeconds(forSourceSeconds: sourceStart),
        let timelineEnd = mapping.timelineSeconds(forSourceSeconds: sourceEnd)
      else { return nil }
      return DisplayedRange(
        id: id,
        index: index,
        startSeconds: timelineStart,
        endSeconds: timelineEnd
      )
    }
  }
}

private extension EditorTimelineEffectSegment.Kind {
  var sortRank: Int {
    switch self {
    case .zoom:
      return 0
    case .caption:
      return 1
    case .mask:
      return 2
    case .camera:
      return 3
    case .audio:
      return 4
    }
  }
}

struct TimelineEffectSegmentFrame: Equatable {
  var x: CGFloat
  var width: CGFloat

  var isDrawable: Bool {
    width > 0
  }
}

extension RecordingProject.TimelineModel {
  mutating func moveClip(id: UUID, toIndex rawIndex: Int) -> Bool {
    var ordered = activeClips
    guard let currentIndex = ordered.firstIndex(where: { $0.id == id }) else { return false }
    let clip = ordered.remove(at: currentIndex)
    let targetIndex = max(0, min(rawIndex, ordered.count))
    guard targetIndex != currentIndex else { return false }

    let ratesByID = Dictionary(
      uniqueKeysWithValues: ordered.map { ($0.id, speedRate(for: $0)) } + [(clip.id, speedRate(for: clip))]
    )
    ordered.insert(clip, at: targetIndex)
    clips = Self.reflowedForUserOrder(ordered)
    speedSegments = clips.compactMap { clip in
      let rate = ratesByID[clip.id] ?? RecordingProject.TimelineEditing.defaultSpeedRate
      guard abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 else { return nil }
      return SpeedSegment(
        startSeconds: clip.timelineStartSeconds,
        endSeconds: clip.timelineStartSeconds + clip.durationSeconds,
        rate: rate
      )
    }
    .sorted { $0.startSeconds < $1.startSeconds }
    return true
  }

  private static func reflowedForUserOrder(_ clips: [Clip]) -> [Clip] {
    var cursor = 0.0
    return clips
      .filter { $0.durationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds }
      .map { clip in
        var c = clip
        c.timelineStartSeconds = cursor
        cursor += c.durationSeconds
        return c
      }
  }
}

enum RecordingProjectEditorZoomSanitizer {
  static func hasOverlappingSegments(_ segments: [RecordingProject.ZoomSegment]) -> Bool {
    let intervals = segments
      .map { TimelineZoomOverlapPolicy.Interval(start: $0.startSeconds, end: $0.endSeconds) }
      .filter { $0.end > $0.start }
      .sorted { $0.start < $1.start }
    guard intervals.count > 1 else { return false }
    for index in intervals.indices.dropLast() {
      let current = intervals[index]
      let next = intervals[index + 1]
      if TimelineZoomOverlapPolicy.overlaps(current.start, current.end, with: next) {
        return true
      }
    }
    return false
  }

  static func sanitizedSegments(
    _ segments: [RecordingProject.ZoomSegment],
    durationSeconds: Double
  ) -> [RecordingProject.ZoomSegment] {
    let duration = max(0, durationSeconds)
    let baseline = RecordingProject.sanitizedZoomSegments(segments, durationSeconds: duration)
    var resolved: [RecordingProject.ZoomSegment] = []
    for var segment in baseline {
      let peers = TimelineZoomOverlapPolicy.peerIntervals(excludingID: segment.id, segments: resolved)
      if !peers.isEmpty {
        let range = TimelineEditableRange(
          id: segment.id,
          kind: .zoom,
          startSeconds: segment.startSeconds,
          inEndSeconds: segment.inEndSeconds,
          outStartSeconds: segment.outStartSeconds,
          endSeconds: segment.endSeconds,
          minDuration: RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds,
          canTrim: true,
          canMove: true
        )
        let adjusted = TimelineZoomOverlapPolicy.resolve(
          range,
          mode: .move,
          peers: peers,
          totalDuration: duration,
          moveReferenceStart: segment.startSeconds
        )
        segment.startSeconds = adjusted.startSeconds
        segment.inEndSeconds = adjusted.inEndSeconds ?? adjusted.startSeconds
        segment.outStartSeconds = adjusted.outStartSeconds ?? adjusted.endSeconds
        segment.endSeconds = adjusted.endSeconds
      }
      resolved.append(segment)
    }
    return RecordingProject.sanitizedZoomSegments(resolved, durationSeconds: duration)
  }

  static func sanitizedSegments(
    _ segments: [RecordingProject.ZoomSegment],
    durationSeconds: Double,
    resolvingSegmentID: UUID,
    mode: EffectRangeEditMode,
    moveReferenceStart: Double
  ) -> [RecordingProject.ZoomSegment] {
    let duration = max(0, durationSeconds)
    var output = RecordingProject.sanitizedZoomSegments(segments, durationSeconds: duration)
    guard let index = output.firstIndex(where: { $0.id == resolvingSegmentID }) else {
      return output
    }
    let peers = TimelineZoomOverlapPolicy.peerIntervals(excludingID: resolvingSegmentID, segments: output)
    guard !peers.isEmpty else { return output }
    let segment = output[index]
    let range = TimelineEditableRange(
      id: segment.id,
      kind: .zoom,
      startSeconds: segment.startSeconds,
      inEndSeconds: segment.inEndSeconds,
      outStartSeconds: segment.outStartSeconds,
      endSeconds: segment.endSeconds,
      minDuration: RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds,
      canTrim: true,
      canMove: true
    )
    let adjusted = TimelineZoomOverlapPolicy.resolve(
      range,
      mode: mode,
      peers: peers,
      totalDuration: duration,
      moveReferenceStart: moveReferenceStart
    )
    output[index].startSeconds = adjusted.startSeconds
    output[index].inEndSeconds = adjusted.inEndSeconds ?? adjusted.startSeconds
    output[index].outStartSeconds = adjusted.outStartSeconds ?? adjusted.endSeconds
    output[index].endSeconds = adjusted.endSeconds
    return RecordingProject.sanitizedZoomSegments(output, durationSeconds: duration)
  }
}
