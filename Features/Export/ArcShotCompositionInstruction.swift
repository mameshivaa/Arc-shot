import AVFoundation
import CoreMedia

final class ArcShotCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {

  struct ZoomState {
    var scale: Double
    var anchorX: Double
    var anchorY: Double
    var visibleX: Double
    var visibleY: Double
    var visibleWidth: Double
    var visibleHeight: Double

    static let identity = ZoomState(
      scale: 1,
      anchorX: 0.5,
      anchorY: 0.5,
      visibleX: 0,
      visibleY: 0,
      visibleWidth: 1,
      visibleHeight: 1
    )

    init(scale: Double, anchorX: Double, anchorY: Double) {
      let scale = RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(scale)
      let size = max(RecordingProject.ZoomSegment.minTargetRegionSize, min(1, 1 / scale))
      let centerX = max(0, min(1, anchorX))
      let centerY = max(0, min(1, anchorY))
      self.init(
        scale: scale,
        anchorX: centerX,
        anchorY: centerY,
        visibleX: max(0, min(1 - size, centerX - size / 2)),
        visibleY: max(0, min(1 - size, centerY - size / 2)),
        visibleWidth: size,
        visibleHeight: size
      )
    }

    init(
      scale: Double,
      anchorX: Double,
      anchorY: Double,
      visibleX: Double,
      visibleY: Double,
      visibleWidth: Double,
      visibleHeight: Double
    ) {
      let visibleWidth = max(RecordingProject.ZoomSegment.minTargetRegionSize, min(1, visibleWidth))
      let visibleHeight = max(RecordingProject.ZoomSegment.minTargetRegionSize, min(1, visibleHeight))
      self.scale = RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(scale)
      self.visibleX = max(0, min(1 - visibleWidth, visibleX))
      self.visibleY = max(0, min(1 - visibleHeight, visibleY))
      self.visibleWidth = visibleWidth
      self.visibleHeight = visibleHeight
      self.anchorX = max(0, min(1, anchorX))
      self.anchorY = max(0, min(1, anchorY))
    }

    static func targetRegion(_ frame: RecordingProject.ZoomKeyframe) -> ZoomState {
      let minSize = max(RecordingProject.ZoomSegment.minTargetRegionSize, 1 / RecordingProject.ZoomSegment.maxZoomLevel)
      let size = max(minSize, min(1, min(frame.targetWidth, frame.targetHeight)))
      let x = max(0, min(1 - size, frame.targetX))
      let y = max(0, min(1 - size, frame.targetY))
      return ZoomState(
        scale: RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(1 / size),
        anchorX: x + size / 2,
        anchorY: y + size / 2,
        visibleX: x,
        visibleY: y,
        visibleWidth: size,
        visibleHeight: size
      )
    }

    func zoomTransform(
      renderSize: CGSize,
      sourceSize: CGSize,
      baseTransform: CGAffineTransform
    ) -> CGAffineTransform {
      let sourceRect = aspectFitRect(sourceSize: sourceSize, in: renderSize)
      let origin = CGPoint(
        x: sourceRect.minX + visibleX * sourceRect.width,
        y: sourceRect.minY + visibleY * sourceRect.height
      )
      let zoom = CGAffineTransform(
        a: scale,
        b: 0,
        c: 0,
        d: scale,
        tx: sourceRect.minX - origin.x * scale,
        ty: sourceRect.minY - origin.y * scale
      )
      return baseTransform.concatenating(zoom)
    }

    private func aspectFitRect(sourceSize: CGSize, in containerSize: CGSize) -> CGRect {
      guard sourceSize.width > 0,
        sourceSize.height > 0,
        containerSize.width > 0,
        containerSize.height > 0
      else {
        return CGRect(origin: .zero, size: containerSize)
      }

      let scale = min(containerSize.width / sourceSize.width, containerSize.height / sourceSize.height)
      let width = sourceSize.width * scale
      let height = sourceSize.height * scale
      return CGRect(
        x: (containerSize.width - width) / 2,
        y: (containerSize.height - height) / 2,
        width: width,
        height: height
      )
    }
  }

  struct CursorState {
    var samples: [RecordingProject.CursorSample]
    var clickCues: [RecordingProject.CursorClickCue]
    var highlightRegions: [RecordingProject.CursorHighlightRegion]
    var settings: RecordingProject.CursorVisualSettings
  }

  struct StageConfig {
    var useStage: Bool
    var padding: CGFloat
    var cornerRadius: CGFloat
    var contentInset: CGFloat
    var shadowOpacity: CGFloat
    var shadowRadius: CGFloat
    var shadowYOffset: CGFloat
    var backgroundSettings: RecordingProject.ExportVisualSettings
    var sourceKind: RecordingProject.SourceKind
  }

  struct FadeConfig {
    var introFadeSeconds: Double
    var outroFadeSeconds: Double
    var totalDurationSeconds: Double
  }

  struct PIPClip {
    var rect: CGRect
    var cornerRadius: CGFloat
  }

  let _timeRange: CMTimeRange
  var timeRange: CMTimeRange { _timeRange }
  var enablePostProcessing: Bool { false }
  var containsTweening: Bool { true }
  let _requiredSourceTrackIDs: [NSValue]?
  var requiredSourceTrackIDs: [NSValue]? { _requiredSourceTrackIDs }
  var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

  let zoomState: ZoomState
  let zoomFrame: RecordingProject.ZoomKeyframe?
  let zoomKeyframes: [RecordingProject.ZoomKeyframe]
  let previousZoomState: ZoomState?
  let rampDuration: CMTime
  let mainTrackID: CMPersistentTrackID
  let pipTrackID: CMPersistentTrackID?
  let pipTransform: CGAffineTransform?
  let pipClip: PIPClip?
  let mainBaseTransform: CGAffineTransform
  let mainSourceSize: CGSize
  let renderSize: CGSize

  let cursor: CursorState
  let stage: StageConfig
  let fade: FadeConfig
  let textOverlays: [RecordingProject.TextOverlayAnnotation]
  let visualMasks: [RecordingProject.VisualMask]
  let motionPlan: AutoZoomMotionPlan?
  let timedDataOffsetSeconds: Double

  init(
    timeRange: CMTimeRange,
    mainTrackID: CMPersistentTrackID,
    pipTrackID: CMPersistentTrackID?,
    pipTransform: CGAffineTransform?,
    pipClip: PIPClip?,
    mainBaseTransform: CGAffineTransform,
    mainSourceSize: CGSize,
    renderSize: CGSize,
    zoomState: ZoomState,
    zoomFrame: RecordingProject.ZoomKeyframe?,
    zoomKeyframes: [RecordingProject.ZoomKeyframe] = [],
    previousZoomState: ZoomState?,
    rampDuration: CMTime,
    cursor: CursorState,
    stage: StageConfig,
    fade: FadeConfig,
    textOverlays: [RecordingProject.TextOverlayAnnotation],
    visualMasks: [RecordingProject.VisualMask],
    motionPlan: AutoZoomMotionPlan?,
    timedDataOffsetSeconds: Double
  ) {
    self._timeRange = timeRange
    self.mainTrackID = mainTrackID
    self.pipTrackID = pipTrackID
    self.pipTransform = pipTransform
    self.pipClip = pipClip
    self.mainBaseTransform = mainBaseTransform
    self.mainSourceSize = mainSourceSize
    self.renderSize = renderSize
    self.zoomState = zoomState
    self.zoomFrame = zoomFrame
    self.zoomKeyframes = zoomKeyframes
    self.previousZoomState = previousZoomState
    self.rampDuration = rampDuration
    self.cursor = cursor
    self.stage = stage
    self.fade = fade
    self.textOverlays = textOverlays
    self.visualMasks = visualMasks
    self.motionPlan = motionPlan
    self.timedDataOffsetSeconds = timedDataOffsetSeconds

    var trackIDs: [NSValue] = [NSNumber(value: mainTrackID)]
    if let pipTrackID {
      trackIDs.append(NSNumber(value: pipTrackID))
    }
    self._requiredSourceTrackIDs = trackIDs
  }

  func interpolatedZoomTransform(at compositionTime: CMTime) -> CGAffineTransform {
    let seconds = timedDataSeconds(at: compositionTime)
    if let previewState = EditorPreviewZoomResolver.resolvedState(keyframes: zoomKeyframes, at: seconds) {
      return previewState.compositionZoomState.zoomTransform(
        renderSize: renderSize,
        sourceSize: mainSourceSize,
        baseTransform: mainBaseTransform
      )
    }

    if let state = zoomFrameState(at: seconds) {
      return state.zoomTransform(renderSize: renderSize, sourceSize: mainSourceSize, baseTransform: mainBaseTransform)
    }

    if zoomState == .identity, let motionState = motionPlan?.state(at: seconds) {
      return ZoomState(scale: motionState.scale, anchorX: motionState.anchorX, anchorY: motionState.anchorY)
        .zoomTransform(renderSize: renderSize, sourceSize: mainSourceSize, baseTransform: mainBaseTransform)
    }

    let target = zoomState.zoomTransform(renderSize: renderSize, sourceSize: mainSourceSize, baseTransform: mainBaseTransform)

    guard let prev = previousZoomState, rampDuration > .zero else {
      return target
    }

    let elapsed = CMTimeSubtract(compositionTime, _timeRange.start)
    guard elapsed < rampDuration else { return target }

    let t = elapsed.seconds / rampDuration.seconds
    let smoothT = t * t * (3 - 2 * t)

    let from = prev.zoomTransform(renderSize: renderSize, sourceSize: mainSourceSize, baseTransform: mainBaseTransform)
    return CGAffineTransform(
      a: from.a + (target.a - from.a) * smoothT,
      b: from.b + (target.b - from.b) * smoothT,
      c: from.c + (target.c - from.c) * smoothT,
      d: from.d + (target.d - from.d) * smoothT,
      tx: from.tx + (target.tx - from.tx) * smoothT,
      ty: from.ty + (target.ty - from.ty) * smoothT
    )
  }

  func timedDataSeconds(at compositionTime: CMTime) -> Double {
    compositionTime.seconds - timedDataOffsetSeconds
  }

  private func zoomFrameState(at seconds: Double) -> ZoomState? {
    guard let frame = zoomFrame,
      seconds >= frame.startSeconds,
      seconds <= frame.endSeconds
    else {
      return nil
    }

    let target = ZoomState.targetRegion(frame)

    if frame.inEndSeconds <= frame.startSeconds + 1e-6, seconds <= frame.outStartSeconds {
      return target
    }

    if seconds < frame.inEndSeconds {
      let u = normalized(seconds, start: frame.startSeconds, end: frame.inEndSeconds)
      return blend(from: .identity, to: target, progress: easeOut(u))
    }

    if seconds <= frame.outStartSeconds {
      return target
    }

    let u = normalized(seconds, start: frame.outStartSeconds, end: frame.endSeconds)
    return blend(from: target, to: .identity, progress: easeIn(u))
  }

  private func normalized(_ value: Double, start: Double, end: Double) -> Double {
    guard end > start + 1e-9 else { return 1 }
    return max(0, min(1, (value - start) / (end - start)))
  }

  private func easeOut(_ t: Double) -> Double {
    1 - pow(1 - max(0, min(1, t)), 3)
  }

  private func easeIn(_ t: Double) -> Double {
    pow(max(0, min(1, t)), 3)
  }

  private func blend(from: ZoomState, to: ZoomState, progress: Double) -> ZoomState {
    ZoomState(
      scale: from.scale + (to.scale - from.scale) * progress,
      anchorX: from.anchorX + (to.anchorX - from.anchorX) * progress,
      anchorY: from.anchorY + (to.anchorY - from.anchorY) * progress,
      visibleX: from.visibleX + (to.visibleX - from.visibleX) * progress,
      visibleY: from.visibleY + (to.visibleY - from.visibleY) * progress,
      visibleWidth: from.visibleWidth + (to.visibleWidth - from.visibleWidth) * progress,
      visibleHeight: from.visibleHeight + (to.visibleHeight - from.visibleHeight) * progress
    )
  }

}

extension ArcShotCompositionInstruction.ZoomState: Equatable {}
