import AVFoundation
import CoreMedia

enum ArcShotCompositionInstructionBuilder {

  struct Input {
    var mainVideoTrack: AVAssetTrack
    var pipVideoTrack: AVAssetTrack?
    var timeRange: CMTimeRange
    var mainBaseTransform: CGAffineTransform
    var mainSourceSize: CGSize
    var pipBaseTransform: CGAffineTransform?
    var pipAttachment: RecordingProject.SecondaryRecordingAttachment?
    var pipNaturalSize: CGSize?
    var pipPreferredTransform: CGAffineTransform?
    var renderSize: CGSize
    var zoomFrames: [RecordingProject.ZoomKeyframe]
    var motionPlan: AutoZoomMotionPlan?
    var cameraLayoutSegments: [RecordingProject.CameraLayoutSegment]
    var cursorSamples: [RecordingProject.CursorSample]
    var cursorClickCues: [RecordingProject.CursorClickCue]
    var cursorHighlightRegions: [RecordingProject.CursorHighlightRegion]
    var cursorVisualSettings: RecordingProject.CursorVisualSettings
    var textOverlays: [RecordingProject.TextOverlayAnnotation]
    var visualMasks: [RecordingProject.VisualMask]
    var styleSettings: RecordingProject.StyleSettings
    var exportVisualSettings: RecordingProject.ExportVisualSettings
    var sourceKind: RecordingProject.SourceKind
    var timedDataOffsetSeconds: Double
  }

  static func build(input: Input) -> [AVVideoCompositionInstructionProtocol] {
    let ramp = CMTime(seconds: 0.12, preferredTimescale: 600)
    let start = input.timeRange.start
    let end = CMTimeAdd(input.timeRange.start, input.timeRange.duration)
    guard end > start else { return [] }

    let frames = input.zoomFrames
      .filter { $0.endSeconds > $0.startSeconds }
      .sorted { $0.startSeconds < $1.startSeconds }

    let segments = buildTimelineSegments(
      start: start, end: end,
      zoomFrames: frames,
      cameraLayoutSegments: input.cameraLayoutSegments,
      timedDataOffsetSeconds: input.timedDataOffsetSeconds
    )

    let mainTrackID = input.mainVideoTrack.trackID
    let pipTrackID = input.pipVideoTrack?.trackID
    let exportDuration = input.timeRange.duration.seconds
    let timedDataOffsetSeconds = input.timedDataOffsetSeconds

    let useStage: Bool = {
      guard input.exportVisualSettings.stageStyle != .none else { return false }
      switch input.sourceKind {
      case .window: return true
      case .display, .area: return input.exportVisualSettings.enabledForDisplayCapture
      }
    }()

    let stageConfig = ArcShotCompositionInstruction.StageConfig(
      useStage: useStage,
      padding: max(0, CGFloat(input.exportVisualSettings.backgroundPadding)),
      cornerRadius: CGFloat(input.exportVisualSettings.contentCornerRadius),
      contentInset: 0,
      shadowOpacity: CGFloat(input.exportVisualSettings.dropShadowOpacity),
      shadowRadius: CGFloat(input.exportVisualSettings.shadowRadius),
      shadowYOffset: CGFloat(input.exportVisualSettings.shadowYOffset),
      backgroundSettings: input.exportVisualSettings,
      sourceKind: input.sourceKind
    )

    let fadeConfig = ArcShotCompositionInstruction.FadeConfig(
      introFadeSeconds: input.styleSettings.introFadeSeconds,
      outroFadeSeconds: input.styleSettings.outroFadeSeconds,
      totalDurationSeconds: exportDuration
    )

    let sortedSamples = input.cursorSamples
      .filter { $0.timeSeconds >= 0 && $0.timeSeconds <= exportDuration }
      .sorted { $0.timeSeconds < $1.timeSeconds }

    let shiftedClickCues = input.cursorClickCues
    let shiftedHighlights = input.cursorHighlightRegions

    var instructions: [AVVideoCompositionInstructionProtocol] = []
    var previousZoomState: ArcShotCompositionInstruction.ZoomState? = nil

    for seg in segments {
      let mid = CMTimeAdd(seg.start,
        CMTimeMultiplyByFloat64(CMTimeSubtract(seg.end, seg.start), multiplier: 0.5))
      let localMidSeconds = mid.seconds - timedDataOffsetSeconds
      let activeZoom = activeKeyframe(atSeconds: localMidSeconds, frames: frames)
      let zoomState: ArcShotCompositionInstruction.ZoomState
      if let kf = activeZoom {
        zoomState = .targetRegion(kf)
      } else {
        zoomState = .identity
      }

      let activeCameraSegment = activeCameraSegment(atSeconds: localMidSeconds, segments: input.cameraLayoutSegments)
      let activePIPAttachment: RecordingProject.SecondaryRecordingAttachment? = {
        guard input.pipBaseTransform != nil else { return nil }
        if let activeCameraSegment {
          return cameraAttachment(
            for: activeCameraSegment, activeZoom: activeZoom,
            pipAttachment: input.pipAttachment, renderSize: input.renderSize
          )
        }
        return input.pipAttachment?.clampedForExport()
      }()
      let pipTransform: CGAffineTransform? = {
        guard let pipBT = input.pipBaseTransform,
          let activePIPAttachment
        else { return nil }
        if let activeCameraSegment {
          return pipAspectFillTransform(
            pipNaturalSize: input.pipNaturalSize ?? input.renderSize,
            pipPreferredTransform: input.pipPreferredTransform ?? .identity,
            attachment: activePIPAttachment,
            renderSize: input.renderSize,
            isMirrored: activeCameraSegment.isMirrored
          )
        }
        return pipBT
      }()
      let pipClip: ArcShotCompositionInstruction.PIPClip?
      if let activePIPAttachment {
        pipClip = Self.pipClip(attachment: activePIPAttachment, renderSize: input.renderSize)
      } else {
        pipClip = nil
      }

      let segRange = CMTimeRange(start: seg.start, end: seg.end)
      let segStartSec = seg.start.seconds - timedDataOffsetSeconds
      let segEndSec = seg.end.seconds - timedDataOffsetSeconds

      let segSamples = sortedSamples.filter {
        $0.timeSeconds >= segStartSec - 0.02 && $0.timeSeconds <= segEndSec + 0.02
      }
      let segClickCues = shiftedClickCues.filter {
        $0.timeSeconds >= segStartSec - 0.5 && $0.timeSeconds <= segEndSec + 0.5
      }
      let segHighlights = shiftedHighlights.filter {
        $0.endSeconds > segStartSec && $0.startSeconds < segEndSec
      }
      let segTextOverlays = input.textOverlays.filter {
        $0.endSeconds > segStartSec && $0.startSeconds < segEndSec
      }
      let segMasks = input.visualMasks.filter {
        $0.endSeconds > segStartSec && $0.startSeconds < segEndSec
      }
      let segMotionPlan = input.motionPlan.map { plan in
        AutoZoomMotionPlan(frames: plan.frames.filter {
          $0.timeSeconds >= segStartSec - 0.05 && $0.timeSeconds <= segEndSec + 0.05
        })
      }

      let cursorState = ArcShotCompositionInstruction.CursorState(
        samples: segSamples,
        clickCues: segClickCues,
        highlightRegions: segHighlights,
        settings: input.cursorVisualSettings
      )

      let segDuration = CMTimeSubtract(seg.end, seg.start)
      let effectiveRamp = min(ramp, segDuration)

      let needsRamp = previousZoomState != nil &&
        (previousZoomState!.scale != zoomState.scale ||
         previousZoomState!.anchorX != zoomState.anchorX ||
         previousZoomState!.anchorY != zoomState.anchorY ||
         previousZoomState!.visibleX != zoomState.visibleX ||
         previousZoomState!.visibleY != zoomState.visibleY ||
         previousZoomState!.visibleWidth != zoomState.visibleWidth ||
         previousZoomState!.visibleHeight != zoomState.visibleHeight)

      let instruction = ArcShotCompositionInstruction(
        timeRange: segRange,
        mainTrackID: mainTrackID,
        pipTrackID: pipTrackID,
        pipTransform: pipTransform,
        pipClip: pipClip,
        mainBaseTransform: input.mainBaseTransform,
        mainSourceSize: input.mainSourceSize,
        renderSize: input.renderSize,
        zoomState: zoomState,
        zoomFrame: activeZoom,
        zoomKeyframes: frames,
        previousZoomState: needsRamp ? previousZoomState : nil,
        rampDuration: needsRamp ? effectiveRamp : .zero,
        cursor: cursorState,
        stage: stageConfig,
        fade: fadeConfig,
        textOverlays: segTextOverlays,
        visualMasks: segMasks,
        motionPlan: segMotionPlan,
        timedDataOffsetSeconds: timedDataOffsetSeconds
      )

      instructions.append(instruction)
      previousZoomState = zoomState
    }

    return instructions
  }

  // MARK: - Timeline segmentation

  private struct TimeSegment {
    var start: CMTime
    var end: CMTime
  }

  private static func buildTimelineSegments(
    start: CMTime, end: CMTime,
    zoomFrames: [RecordingProject.ZoomKeyframe],
    cameraLayoutSegments: [RecordingProject.CameraLayoutSegment],
    timedDataOffsetSeconds: Double
  ) -> [TimeSegment] {
    var boundaries: [CMTime] = [start, end]
    boundaries.append(contentsOf: zoomFrames.flatMap { kf in
      [
        CMTime(seconds: kf.startSeconds + timedDataOffsetSeconds, preferredTimescale: 600),
        CMTime(seconds: kf.inEndSeconds + timedDataOffsetSeconds, preferredTimescale: 600),
        CMTime(seconds: kf.outStartSeconds + timedDataOffsetSeconds, preferredTimescale: 600),
        CMTime(seconds: kf.endSeconds + timedDataOffsetSeconds, preferredTimescale: 600),
      ]
    })
    boundaries.append(contentsOf: cameraLayoutSegments.flatMap { seg in
      [
        CMTime(seconds: seg.startSeconds + timedDataOffsetSeconds, preferredTimescale: 600),
        CMTime(seconds: seg.endSeconds + timedDataOffsetSeconds, preferredTimescale: 600),
      ]
    })
    boundaries = boundaries
      .filter { $0.isNumeric && $0 >= start && $0 <= end }
      .sorted()

    var unique: [CMTime] = []
    for t in boundaries {
      if unique.last.map({ CMTimeCompare($0, t) == 0 }) == true { continue }
      unique.append(t)
    }

    return zip(unique, unique.dropFirst())
      .map { TimeSegment(start: $0.0, end: $0.1) }
      .filter { $0.end > $0.start }
  }

  private static func activeKeyframe(
    atSeconds seconds: Double,
    frames: [RecordingProject.ZoomKeyframe]
  ) -> RecordingProject.ZoomKeyframe? {
    let active = frames.filter { kf in seconds >= kf.startSeconds && seconds < kf.endSeconds }
    return active.max { a, b in a.startSeconds < b.startSeconds }
  }

  private static func activeCameraSegment(
    atSeconds seconds: Double,
    segments: [RecordingProject.CameraLayoutSegment]
  ) -> RecordingProject.CameraLayoutSegment? {
    guard !segments.isEmpty else { return nil }
    return segments
      .filter { seconds >= $0.startSeconds && seconds < $0.endSeconds }
      .max { a, b in a.startSeconds < b.startSeconds }
  }

  private static func cameraAttachment(
    for segment: RecordingProject.CameraLayoutSegment,
    activeZoom: RecordingProject.ZoomKeyframe?,
    pipAttachment: RecordingProject.SecondaryRecordingAttachment?,
    renderSize: CGSize
  ) -> RecordingProject.SecondaryRecordingAttachment? {
    guard var attachment = pipAttachment else { return nil }
    switch segment.layout {
    case .hidden:
      return nil
    case .pip:
      attachment.originXN = segment.originXN
      attachment.originYN = segment.originYN
      attachment.widthN = segment.widthN
      attachment.heightN = segment.heightN
      attachment.cornerRadiusPts = segment.cornerRadiusPts
      return attachment.clampedForExport()
    case .fullscreen:
      attachment.originXN = 0
      attachment.originYN = 0
      attachment.widthN = 1
      attachment.heightN = 1
      attachment.cornerRadiusPts = 0
      return attachment.clampedForExport()
    }
  }

  private static func pipAspectFillTransform(
    pipNaturalSize: CGSize,
    pipPreferredTransform: CGAffineTransform,
    attachment: RecordingProject.SecondaryRecordingAttachment,
    renderSize: CGSize,
    isMirrored: Bool
  ) -> CGAffineTransform {
    let pipRect = ExportVideoGeometry.pipCompositorRect(
      originXN: attachment.originXN,
      originYN: attachment.originYN,
      widthN: attachment.widthN,
      heightN: attachment.heightN,
      renderSize: renderSize
    )
    let pipSrc = pipNaturalSize.applying(pipPreferredTransform)
    let srcW = abs(pipSrc.width)
    let srcH = abs(pipSrc.height)
    let scale = max(pipRect.width / max(1, srcW), pipRect.height / max(1, srcH))
    let scaledW = srcW * scale
    let scaledH = srcH * scale
    let tx = pipRect.midX - scaledW / 2
    let ty = pipRect.midY - scaledH / 2
    var t = pipPreferredTransform
    if isMirrored {
      t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
      t = t.concatenating(CGAffineTransform(translationX: srcW, y: 0))
    }
    t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
    return t
  }

  static func pipClip(
    attachment: RecordingProject.SecondaryRecordingAttachment,
    renderSize: CGSize
  ) -> ArcShotCompositionInstruction.PIPClip {
    let radius = attachment.widthN >= 1 && attachment.heightN >= 1
      ? 0
      : min(28, max(0, CGFloat(attachment.cornerRadiusPts) * 0.55))
    let rect = ExportVideoGeometry.pipCompositorRect(
      originXN: attachment.originXN,
      originYN: attachment.originYN,
      widthN: attachment.widthN,
      heightN: attachment.heightN,
      renderSize: renderSize
    )
    return ArcShotCompositionInstruction.PIPClip(
      rect: rect,
      cornerRadius: radius
    )
  }
}
