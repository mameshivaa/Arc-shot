import Foundation
import CoreGraphics
import simd

struct FocusRegion: Codable, Equatable {
  enum Kind: String, Codable, Equatable {
    case clickTarget
    case typingTarget
    case resultChange
  }

  var startSeconds: Double
  var endSeconds: Double
  /// Normalized screen-space bounds, where (0, 0) is the top-left of the recorded frame.
  var bounds: CGRect
  var kind: Kind
  var confidence: Double

  var center: simd_double2 {
    simd_double2(Double(bounds.midX), Double(bounds.midY))
  }

  var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

struct ZoomIntent: Equatable {
  var startSeconds: Double
  var endSeconds: Double
  var targetScale: Double
  var targetAnchor: simd_double2
  var urgency: Double
  var targetKind: UserIntentTarget.Kind = .readingTarget

  var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

struct UserIntentTarget: Equatable {
  enum Kind: Equatable {
    case clickTarget
    case typingTarget
    case resultTarget
    case readingTarget
    case overview
  }

  var kind: Kind
  var startSeconds: Double
  var endSeconds: Double
  var anchor: simd_double2
  var bounds: CGRect
  var confidence: Double
  var priority: Double

  var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

struct ShotPlan: Equatable {
  struct Shot: Equatable {
    var target: UserIntentTarget
    var startSeconds: Double
    var endSeconds: Double

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
  }

  var shots: [Shot]
}

enum ZoomIntentPlanner {
  struct Config {
    var clickZoomScale: Double = 1.22
    var typingZoomScale: Double = 1.38
    var resultZoomScale: Double = 1.22
    var idleZoomScale: Double = 1.0
    var overviewZoomScale: Double = 1.0
    var navigationZoomScale: Double = 1.0
    var draggingZoomScale: Double = 1.0
    var scrollingZoomScale: Double = 1.0
    var clickUrgency: Double = 0.58
    var typingUrgency: Double = 0.52
    var resultUrgency: Double = 0.48
    var idleUrgency: Double = 0.0
    var overviewUrgency: Double = 0.0
    var navigationUrgency: Double = 0.0
    var draggingUrgency: Double = 0.0
    var scrollingUrgency: Double = 0.0
    var enableTypingZoom: Bool = false
    var enableResultChangePan: Bool = false
    var minIntentDurationSeconds: Double = 0.35
    var minClickIntentDurationSeconds: Double = 0.08
    var minIdleIntentDurationSeconds: Double = 0.85
    var anchorPadding: Double = 0.04
    var lowerEdgeAnchorPadding: Double = 0.035
    var maxZoomScale: Double = 1.9
    var preRollSeconds: Double = 0.12
    var postHoldSeconds: Double = 1.15
    var minVisibleSeconds: Double = 1.9
    var minShotDurationSeconds: Double = 1.9
    var mergeGapSeconds: Double = 1.7
    var shotMergeAnchorDistance: Double = 0.28
    var contextWidthFraction: Double = 0.38
    var contextHeightFraction: Double = 0.34
    var regionPadding: Double = 0.026
    var typingTargetY: Double = 0.50
    var typingTargetMinY: Double = 0.42
    var typingTargetMaxY: Double = 0.58
    var typingTopTargetY: Double = 0.82
    var typingBottomTargetY: Double = 0.18
    var typingTargetWidth: Double = 0.52
    var typingTargetHeight: Double = 0.14
    var clickHoldSeconds: Double = 1.45
    var resultDelaySeconds: Double = 0.4
    var resultHoldSeconds: Double = 1.8
  }

  static func plan(
    activities: [ActivitySpan],
    durationSeconds: Double,
    focusRegions: [FocusRegion] = [],
    config: Config = Config()
  ) -> [ZoomIntent] {
    guard !activities.isEmpty, durationSeconds > 0 else { return [] }

    return planShots(
      activities: activities,
      durationSeconds: durationSeconds,
      focusRegions: focusRegions,
      config: config
    ).shots.compactMap {
      zoomIntent(from: $0, config: config)
    }
  }

  static func planTargets(
    activities: [ActivitySpan],
    durationSeconds: Double,
    focusRegions: [FocusRegion] = [],
    config: Config = Config()
  ) -> [UserIntentTarget] {
    guard !activities.isEmpty, durationSeconds > 0 else { return [] }
    return activities.flatMap { span -> [UserIntentTarget] in
      guard span.durationSeconds >= minimumDuration(for: span.activity, config: config) else { return [] }
      return intentTargets(
        for: span,
        durationSeconds: durationSeconds,
        focusRegions: focusRegions,
        config: config)
    }
  }

  static func planShots(
    activities: [ActivitySpan],
    durationSeconds: Double,
    focusRegions: [FocusRegion] = [],
    config: Config = Config()
  ) -> ShotPlan {
    let targets = planTargets(
      activities: activities,
      durationSeconds: durationSeconds,
      focusRegions: focusRegions,
      config: config)
    return ShotPlan(shots: resolveShots(targets, durationSeconds: durationSeconds, config: config))
  }

  private static func minimumDuration(
    for activity: UserActivity,
    config: Config
  ) -> Double {
    switch activity {
    case .clicking:
      return config.minClickIntentDurationSeconds
    case .idle:
      return config.minIdleIntentDurationSeconds
    case .typing, .dragging, .navigating, .scrolling:
      return config.minIntentDurationSeconds
    }
  }

  private static func scaleAndUrgency(
    for activity: UserActivity, config: Config
  ) -> (Double, Double) {
    switch activity {
    case .clicking:
      return (config.clickZoomScale, config.clickUrgency)
    case .typing:
      return (config.typingZoomScale, config.typingUrgency)
    case .idle:
      return (config.idleZoomScale, config.idleUrgency)
    case .navigating:
      return (config.navigationZoomScale, config.navigationUrgency)
    case .dragging:
      return (config.draggingZoomScale, config.draggingUrgency)
    case .scrolling:
      return (config.scrollingZoomScale, config.scrollingUrgency)
    }
  }

  private static func clampedAnchor(
    _ anchor: simd_double2, scale: Double, padding: Double
  ) -> simd_double2 {
    guard scale > 1.01 else { return anchor }
    let viewFraction = 1.0 / scale
    let halfView = viewFraction / 2.0
    let minA = halfView + padding * viewFraction
    let maxA = 1.0 - minA
    return simd_double2(
      max(min(minA, 0.5), min(max(maxA, 0.5), anchor.x)),
      max(min(minA, 0.5), min(max(maxA, 0.5), anchor.y)))
  }

  private static func intentTargets(
    for span: ActivitySpan,
    durationSeconds: Double,
    focusRegions: [FocusRegion],
    config: Config
  ) -> [UserIntentTarget] {
    if !config.enableTypingZoom, case .typing = span.activity {
      return []
    }

    let focusTargets = focusRegionTargets(
      for: span,
      focusRegions: focusRegions,
      config: config)
    let inferred = inferredTargets(for: span, durationSeconds: durationSeconds, config: config)
    let candidates = focusTargets + inferred
    guard !candidates.isEmpty else {
      switch span.activity {
      case .idle, .clicking, .typing:
        return [fallbackTarget(for: span)]
      case .dragging, .navigating, .scrolling:
        return []
      }
    }

    if !focusTargets.isEmpty {
      return candidates.sorted {
        score(target: $0, activityAnchor: span.anchor) > score(target: $1, activityAnchor: span.anchor)
      }
    }

    return inferred.sorted {
      score(target: $0, activityAnchor: span.anchor) > score(target: $1, activityAnchor: span.anchor)
    }
  }

  private static func focusRegionTargets(
    for span: ActivitySpan,
    focusRegions: [FocusRegion],
    config: Config
  ) -> [UserIntentTarget] {
    focusRegions.compactMap { region in
      guard config.enableResultChangePan || region.kind != .resultChange else { return nil }
      guard max(region.startSeconds, span.startSeconds - config.preRollSeconds)
        < min(region.endSeconds, span.endSeconds + config.postHoldSeconds)
      else { return nil }

      let kind: UserIntentTarget.Kind
      let priority: Double
      switch (span.activity, region.kind) {
      case (.clicking, .clickTarget):
        kind = .clickTarget
        priority = 0.96
      case (.clicking, .resultChange):
        kind = .resultTarget
        priority = 0.98
      case (.typing, .typingTarget):
        kind = .typingTarget
        priority = 0.94
      case (.typing, .resultChange), (.idle, .resultChange):
        kind = .resultTarget
        priority = 0.82
      default:
        return nil
      }

      return UserIntentTarget(
        kind: kind,
        startSeconds: region.startSeconds,
        endSeconds: region.endSeconds,
        anchor: region.center,
        bounds: region.bounds,
        confidence: region.confidence,
        priority: priority)
    }
  }

  private static func inferredTargets(
    for span: ActivitySpan,
    durationSeconds: Double,
    config: Config
  ) -> [UserIntentTarget] {
    switch span.activity {
    case .clicking:
      let click = UserIntentTarget(
        kind: .clickTarget,
        startSeconds: span.startSeconds,
        endSeconds: max(span.endSeconds, span.startSeconds + 0.35),
        anchor: span.anchor,
        bounds: bounds(center: span.anchor, width: 0.12, height: 0.10),
        confidence: 0.86,
        priority: 0.96)
      let result = UserIntentTarget(
        kind: .resultTarget,
        startSeconds: min(durationSeconds, span.endSeconds + config.resultDelaySeconds),
        endSeconds: min(durationSeconds, span.endSeconds + config.resultHoldSeconds),
        anchor: span.anchor,
        bounds: bounds(center: span.anchor, width: 0.22, height: 0.18),
        confidence: 0.58,
        priority: 0.82)
      return [click, result]
    case .typing:
      let anchorX = max(0.34, min(0.82, span.anchor.x))
      let anchorY: Double
      let targetHeight: Double
      if span.anchor.y >= 0.65 {
        anchorY = max(0.74, min(0.90, max(span.anchor.y, config.typingTopTargetY)))
        targetHeight = 0.12
      } else if span.anchor.y <= 0.35 {
        anchorY = min(0.26, max(0.10, min(span.anchor.y, config.typingBottomTargetY)))
        targetHeight = 0.16
      } else {
        anchorY = max(config.typingTargetMinY, min(config.typingTargetMaxY, span.anchor.y))
        targetHeight = config.typingTargetHeight
      }
      let anchor = simd_double2(anchorX, anchorY)
      return [UserIntentTarget(
        kind: .typingTarget,
        startSeconds: span.startSeconds,
        endSeconds: span.endSeconds,
        anchor: anchor,
        bounds: bounds(
          center: anchor,
          width: config.typingTargetWidth,
          height: targetHeight),
        confidence: 0.82,
        priority: 0.94)]
    case .idle:
      let anchor = simd_mix(span.anchor, simd_double2(0.5, 0.5), simd_double2(repeating: 0.65))
      return [UserIntentTarget(
        kind: .readingTarget,
        startSeconds: span.startSeconds,
        endSeconds: span.endSeconds,
        anchor: anchor,
        bounds: bounds(center: anchor, width: 0.46, height: 0.36),
        confidence: 0.45,
        priority: 0.20)]
    case .dragging, .navigating, .scrolling:
      return []
    }
  }

  private static func fallbackTarget(for span: ActivitySpan) -> UserIntentTarget {
    UserIntentTarget(
      kind: .readingTarget,
      startSeconds: span.startSeconds,
      endSeconds: span.endSeconds,
      anchor: span.anchor,
      bounds: bounds(center: span.anchor, width: 0.36, height: 0.28),
      confidence: 0.35,
      priority: 0.1)
  }

  private static func score(target: UserIntentTarget, activityAnchor: simd_double2) -> Double {
    let distance = simd_distance(target.anchor, activityAnchor)
    let distanceScore = max(0, 1.0 - distance * 2.4)
    let area = max(0.0001, Double(target.bounds.width * target.bounds.height))
    let sizeScore = 1.0 / (1.0 + area * 8.0)
    return target.priority * 0.45 + target.confidence * 0.30 + distanceScore * 0.18 + sizeScore * 0.07
  }

  private static func targetScale(
    target: UserIntentTarget,
    config: Config
  ) -> Double {
    let baseScale = scaleAndUrgency(for: target.kind, config: config).scale
    guard baseScale > 1.001 else { return 1.0 }
    let padded = paddedBounds(target.bounds, padding: config.regionPadding)
    let widthScale = config.contextWidthFraction / max(0.04, Double(padded.width))
    let heightScale = config.contextHeightFraction / max(0.035, Double(padded.height))
    let regionScale = min(widthScale, heightScale)
    let confidenceBlend = 0.58 + max(0, min(1, target.confidence)) * 0.42
    let computed = max(baseScale, regionScale * confidenceBlend)
    let band = scaleBand(for: target.kind)
    return max(band.min, min(min(config.maxZoomScale, band.max), computed))
  }

  private static func scaleAndUrgency(
    for kind: UserIntentTarget.Kind,
    config: Config
  ) -> (scale: Double, urgency: Double) {
    switch kind {
    case .clickTarget:
      return (config.clickZoomScale, config.clickUrgency)
    case .typingTarget:
      return (config.typingZoomScale, config.typingUrgency)
    case .resultTarget:
      return (config.resultZoomScale, config.resultUrgency)
    case .readingTarget:
      return (config.idleZoomScale, config.idleUrgency)
    case .overview:
      return (config.overviewZoomScale, config.overviewUrgency)
    }
  }

  private static func scaleBand(for kind: UserIntentTarget.Kind) -> (min: Double, max: Double) {
    switch kind {
    case .clickTarget:
      return (1.10, 1.35)
    case .typingTarget:
      return (1.25, 1.55)
    case .resultTarget:
      return (1.08, 1.35)
    case .readingTarget:
      return (1.0, 1.0)
    case .overview:
      return (1.0, 1.0)
    }
  }

  private static func paddedBounds(_ bounds: CGRect, padding: Double) -> CGRect {
    let dx = CGFloat(padding)
    let dy = CGFloat(padding)
    return bounds.insetBy(dx: -dx, dy: -dy).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  private static func expandedTimeRange(
    for span: ActivitySpan,
    target: UserIntentTarget,
    durationSeconds: Double,
    config: Config
  ) -> (start: Double, end: Double) {
    let rawStart = min(span.startSeconds, target.startSeconds)
    let rawEnd = max(span.endSeconds, target.endSeconds)
    var start = max(0, rawStart - config.preRollSeconds)
    var end = min(durationSeconds, rawEnd + config.postHoldSeconds)
    if end - start < config.minVisibleSeconds {
      let deficit = config.minVisibleSeconds - (end - start)
      end = min(durationSeconds, end + deficit * 0.7)
      start = max(0, start - deficit * 0.3)
    }
    return (start, max(start, end))
  }

  private static func anchorPadding(
    for target: UserIntentTarget,
    config: Config
  ) -> Double {
    switch target.kind {
    case .typingTarget where target.anchor.y >= 0.78:
      return config.lowerEdgeAnchorPadding
    case .resultTarget where target.anchor.y >= 0.78:
      return config.lowerEdgeAnchorPadding
    default:
      return config.anchorPadding
    }
  }

  private static func bounds(
    center: simd_double2,
    width: Double,
    height: Double
  ) -> CGRect {
    let x = max(0, min(1 - width, center.x - width / 2))
    let y = max(0, min(1 - height, center.y - height / 2))
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private static func zoomIntent(from shot: ShotPlan.Shot, config: Config) -> ZoomIntent? {
    guard isZoomableTarget(shot.target.kind) else { return nil }
    let scale = targetScale(target: shot.target, config: config)
    guard scale > 1.001 else { return nil }
    let anchor = clampedAnchor(
      shot.target.anchor,
      scale: scale,
      padding: anchorPadding(for: shot.target, config: config))
    let urgency = max(scaleAndUrgency(for: shot.target.kind, config: config).urgency, shot.target.priority)

    return ZoomIntent(
      startSeconds: shot.startSeconds,
      endSeconds: shot.endSeconds,
      targetScale: scale,
      targetAnchor: anchor,
      urgency: urgency,
      targetKind: shot.target.kind)
  }

  private static func isZoomableTarget(_ kind: UserIntentTarget.Kind) -> Bool {
    switch kind {
    case .clickTarget, .typingTarget, .resultTarget:
      return true
    case .readingTarget, .overview:
      return false
    }
  }

  private static func resolveShots(
    _ targets: [UserIntentTarget],
    durationSeconds: Double,
    config: Config
  ) -> [ShotPlan.Shot] {
    let sorted = targets
      .filter { $0.endSeconds > $0.startSeconds }
      .sorted {
        if abs($0.startSeconds - $1.startSeconds) > 1e-6 {
          return $0.startSeconds < $1.startSeconds
        }
        return $0.priority > $1.priority
      }

    var resolved: [ShotPlan.Shot] = []
    for target in sorted {
      var shot = makeShot(target: target, durationSeconds: durationSeconds, config: config)
      guard shot.durationSeconds > 0.05 else { continue }

      if let lastIdx = resolved.indices.last {
        let last = resolved[lastIdx]
        if canMerge(last.target, shot.target, config: config),
           shot.startSeconds - last.endSeconds <= config.mergeGapSeconds {
          resolved[lastIdx] = mergedShot(last, shot)
          continue
        }

        if shot.startSeconds < last.endSeconds {
          if canMerge(last.target, shot.target, config: config) {
            resolved[lastIdx] = mergedShot(last, shot)
          } else if shouldReplaceOverlappingShot(shot.target, previous: last.target)
            || shot.target.priority > last.target.priority + 0.08 {
            resolved[lastIdx].endSeconds = shot.startSeconds
            if resolved[lastIdx].durationSeconds < 0.2 {
              resolved.removeLast()
            }
            shot.startSeconds = max(0, shot.startSeconds)
            resolved.append(shot)
          }
          continue
        }
      }

      resolved.append(shot)
    }

    return resolved.filter { $0.durationSeconds >= 0.2 }
  }

  private static func makeShot(
    target: UserIntentTarget,
    durationSeconds: Double,
    config: Config
  ) -> ShotPlan.Shot {
    var start = max(0, target.startSeconds - preRoll(for: target, config: config))
    var end = min(durationSeconds, target.endSeconds + postHold(for: target, config: config))
    if end - start < config.minShotDurationSeconds {
      let deficit = config.minShotDurationSeconds - (end - start)
      end = min(durationSeconds, end + deficit * 0.72)
      start = max(0, start - deficit * 0.28)
    }
    return ShotPlan.Shot(target: target, startSeconds: start, endSeconds: max(start, end))
  }

  private static func preRoll(for target: UserIntentTarget, config: Config) -> Double {
    switch target.kind {
    case .clickTarget:
      return min(config.preRollSeconds, 0.08)
    case .resultTarget:
      return 0.04
    case .typingTarget, .readingTarget, .overview:
      return config.preRollSeconds
    }
  }

  private static func postHold(for target: UserIntentTarget, config: Config) -> Double {
    switch target.kind {
    case .clickTarget:
      return 0.6
    case .resultTarget:
      return 0.9
    case .typingTarget:
      return 0.7
    case .readingTarget, .overview:
      return 0.2
    }
  }

  private static func canMerge(
    _ lhs: UserIntentTarget,
    _ rhs: UserIntentTarget,
    config: Config
  ) -> Bool {
    let sameKind = lhs.kind == rhs.kind
    let clickResultPair = (lhs.kind == .clickTarget && rhs.kind == .resultTarget)
      || (lhs.kind == .resultTarget && rhs.kind == .clickTarget)
    guard sameKind || clickResultPair else { return false }
    return simd_distance(lhs.anchor, rhs.anchor) <= config.shotMergeAnchorDistance
  }

  private static func mergedShot(
    _ lhs: ShotPlan.Shot,
    _ rhs: ShotPlan.Shot
  ) -> ShotPlan.Shot {
    let lhsDuration = max(0.001, lhs.durationSeconds)
    let rhsDuration = max(0.001, rhs.durationSeconds)
    let total = lhsDuration + rhsDuration
    var target = lhs.target
    target.startSeconds = min(lhs.target.startSeconds, rhs.target.startSeconds)
    target.endSeconds = max(lhs.target.endSeconds, rhs.target.endSeconds)
    target.anchor = (lhs.target.anchor * lhsDuration + rhs.target.anchor * rhsDuration) / total
    target.bounds = lhs.target.bounds.union(rhs.target.bounds).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    target.confidence = max(lhs.target.confidence, rhs.target.confidence)
    target.priority = max(lhs.target.priority, rhs.target.priority)
    return ShotPlan.Shot(
      target: target,
      startSeconds: min(lhs.startSeconds, rhs.startSeconds),
      endSeconds: max(lhs.endSeconds, rhs.endSeconds))
  }

  private static func targetPriorityRank(_ kind: UserIntentTarget.Kind) -> Int {
    switch kind {
    case .clickTarget:
      return 5
    case .typingTarget:
      return 4
    case .resultTarget:
      return 3
    case .readingTarget:
      return 2
    case .overview:
      return 1
    }
  }

  private static func shouldReplaceOverlappingShot(
    _ target: UserIntentTarget,
    previous: UserIntentTarget
  ) -> Bool {
    if target.kind == .resultTarget, previous.kind == .clickTarget {
      return target.startSeconds >= previous.startSeconds
    }
    return targetPriorityRank(target.kind) > targetPriorityRank(previous.kind)
  }
}
