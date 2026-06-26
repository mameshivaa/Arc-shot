import SwiftUI

enum EditorPalette {
  static let windowBackground = Color(nsColor: .windowBackgroundColor)
  static let panelBackground = Color(nsColor: .controlBackgroundColor)
  static let separator = Color.primary.opacity(0.10)
  static let brand = Color(red: 0.35, green: 0.82, blue: 0.78)
  static let brandStrong = Color(red: 0.19, green: 0.70, blue: 0.66)
  static let clip = Color(red: 0.78, green: 0.58, blue: 0.20)
}

enum EditorLayout {
  static let workspaceMargin: CGFloat = 20
  static let workspaceBottomMargin: CGFloat = 20
  static let workspaceGap: CGFloat = 14
  static let panelInset: CGFloat = 16
  static let panelCornerRadius: CGFloat = 18
  static let controlCornerRadius: CGFloat = 12

  /// Height required to show the full timeline grid without clipping embedded split chrome.
  static func timelinePaneHeight(
    waveformRoleCount: Int = 1,
    maskRowCount: Int = 1,
    includesCameraLane: Bool = false
  ) -> CGFloat {
    let trackHeight = timelineRulerHeight
      + timelineClipLaneHeight
      + (includesCameraLane ? timelineClipLaneHeight + timelineLaneGap : 0)
      + timelineClipLaneHeight
      + timelineEffectLaneHeight
      + timelineMaskLaneHeight(rowCount: maskRowCount)
      + timelineLaneGap * (includesCameraLane ? 5 : 4)
    let gridHeight = timelineControlHeight + timelineControlBottomGap + trackHeight
    return gridHeight + timelineCardTopPadding / 2 + timelineCardBottomPadding
  }

  static var minimumTimelinePaneHeight: CGFloat {
    timelinePaneHeight(maskRowCount: 1)
  }

  static let timelineHeight: CGFloat = minimumTimelinePaneHeight
  static let defaultTimelinePaneHeight: CGFloat = minimumTimelinePaneHeight
  static let minTimelinePaneHeight: CGFloat = minimumTimelinePaneHeight
  /// タイムライン拡大の絶対上限（マスク多段表示まで余裕を持たせる）
  static let maxTimelinePaneHeight: CGFloat = 560
  /// スプリット領域に対するタイムラインの最大比率（編集作業向けに広め）
  static let maxTimelinePaneShareOfSplit: CGFloat = 0.72
  /// プレビューは最低限の確認サイズを確保しつつ、タイムライン拡大を優先
  static let previewMinHeight: CGFloat = 180
  static let previewTimelineResizeHandleHeight: CGFloat = 8
  static let previewTimelineResizeHitSlop: CGFloat = 8
  static let previewTimelineResizeGripWidth: CGFloat = 44
  static let previewTimelineResizeGripHeight: CGFloat = 3
  static let previewTimelineResizeHeightChangeEpsilon: CGFloat = 0.25
  static let timelineCardHorizontalPadding: CGFloat = 16
  static let timelineCardTopPadding: CGFloat = 10
  static let timelineCardBottomPadding: CGFloat = 12
  static let timelineLabelWidth: CGFloat = 72
  static let timelineLabelGap: CGFloat = 12
  static let timelineLaneInsetX: CGFloat = 8
  static let timelineControlHeight: CGFloat = 32
  static let timelineControlBottomGap: CGFloat = 8
  static let timelineRulerHeight: CGFloat = 26
  static let timelineWaveformLaneHeight: CGFloat = 40
  static let timelineWaveformRoleHeight: CGFloat = 32
  static let timelineWaveformRoleGap: CGFloat = 3
  static let timelineClipLaneHeight: CGFloat = 44
  static let timelineCameraLaneHeight: CGFloat = 40
  static let timelineEffectLaneHeight: CGFloat = 34
  static let timelineMaskLaneMinHeight: CGFloat = 34
  static let timelineMaskLaneMaxRows: Int = 4
  static let timelineMaskRowGap: CGFloat = 3
  static let timelineMaskLaneVerticalPadding: CGFloat = 4
  static let inspectorMaskListMaxHeight: CGFloat = 168
  static let timelineLaneGap: CGFloat = 8
  static let timelineLabelTopPadding: CGFloat = 4
  static let timelineLabelDetailOpacity: Double = 0.24

  static func timelineWaveformLaneHeight(roleCount: Int) -> CGFloat {
    guard roleCount > 1 else {
      return timelineWaveformLaneHeight
    }

    return timelineWaveformRoleHeight * CGFloat(roleCount) + timelineWaveformRoleGap * CGFloat(roleCount - 1)
  }

  static func timelineMaskLaneHeight(rowCount: Int) -> CGFloat {
    let rows = max(1, min(timelineMaskLaneMaxRows, rowCount))
    let stack = CGFloat(rows) * timelineEffectSegmentHeight
      + CGFloat(max(0, rows - 1)) * timelineMaskRowGap
    return max(timelineMaskLaneMinHeight, stack + timelineMaskLaneVerticalPadding * 2)
  }

  static func timelineMaskRowYOffset(row: Int, rowCount: Int, laneHeight: CGFloat) -> CGFloat {
    let rows = max(1, min(timelineMaskLaneMaxRows, rowCount))
    let stack = CGFloat(rows) * timelineEffectSegmentHeight
      + CGFloat(max(0, rows - 1)) * timelineMaskRowGap
    let topPadding = max(timelineMaskLaneVerticalPadding, (laneHeight - stack) / 2)
    return topPadding + CGFloat(max(0, row)) * (timelineEffectSegmentHeight + timelineMaskRowGap)
  }

  static var timelineTrackHeight: CGFloat {
    timelineRulerHeight
      + timelineWaveformLaneHeight
      + timelineClipLaneHeight
      + timelineEffectLaneHeight
      + timelineMaskLaneHeight(rowCount: 1)
      + timelineLaneGap * 4
  }
  static var timelineGridHeight: CGFloat {
    timelineControlHeight + timelineControlBottomGap + timelineTrackHeight
  }
  static let timelineRulerMajorTickHeight: CGFloat = 12
  static let timelineRulerMinorTickHeight: CGFloat = 6
  static let timelineRowCornerRadius: CGFloat = 8
  static let timelineHeaderRowOpacity: Double = 0.006
  static let timelineClipHeight: CGFloat = 32
  static let timelineMinimumClipWidth: CGFloat = 16
  static let timelineClipTextLeadingPadding: CGFloat = 24
  static let timelineTrimHandleWidth: CGFloat = 12
  static let timelineTrimHandleHitWidth: CGFloat = 32
  static let timelineTrimHandleHeight: CGFloat = 40
  static let timelineTrimSeekMinInterval: TimeInterval = 1.0 / 12.0
  static let timelineEffectSegmentHeight: CGFloat = 14
  static let timelineZoomPillHeight: CGFloat = 18
  static let timelineZoomSegmentHeight: CGFloat = 28
  static let timelineZoomMotionBoundaryHitWidth: CGFloat = 24
  static let timelineMinimumEffectSegmentWidth: CGFloat = 16
  static let timelineMinimumZoomEffectSegmentWidth: CGFloat = 64
  static let timelineHeaderItemGap: CGFloat = 8
  static let timelineHeaderSideGap: CGFloat = 12
  static let timelineHeaderContentHeight: CGFloat = 30
  static let timelineHeaderControlSize: CGFloat = 28
  static let timelineHeaderGroupGap: CGFloat = 4
  static let timelineHeaderDividerWidth: CGFloat = 1
  static let timelineHeaderDividerHeight: CGFloat = 16
  static let timelineHeaderDividerOpacity: Double = 0.10
  static let timelineTimePillWidth: CGFloat = 148
  static let timelineHeaderSummaryMaxWidth: CGFloat = 360
  static let timelinePlayheadLabelWidth: CGFloat = 64
  static let timelinePlayheadGhostHitWidth: CGFloat = 30
  static let timelinePlayheadGhostTopHitHeight: CGFloat = 34
  static let timelinePlayheadGhostLabelHeight: CGFloat = 17
  static let timelinePlayheadKnobWidth: CGFloat = 8
  static let timelinePlayheadKnobHeight: CGFloat = 6
  static let timelinePlayheadLineWidth: CGFloat = 2
  static let inspectorWidth: CGFloat = 368
  static let inspectorRailWidth: CGFloat = 66
  static let inspectorRailButtonWidth: CGFloat = 52
  static let inspectorRailButtonHeight: CGFloat = 46

  static func clampedTimelinePaneHeight(
    _ proposed: CGFloat,
    availableHeight: CGFloat
  ) -> CGFloat {
    let handleHeight = previewTimelineResizeHandleHeight
    let ratioCap = floor(availableHeight * maxTimelinePaneShareOfSplit)
    let upperBound = min(
      maxTimelinePaneHeight,
      ratioCap,
      max(minTimelinePaneHeight, availableHeight - previewMinHeight - handleHeight)
    )
    let lowerBound = min(minTimelinePaneHeight, upperBound)
    return min(max(proposed, lowerBound), upperBound)
  }

  static func previewPaneHeight(
    timelinePaneHeight: CGFloat,
    availableHeight: CGFloat
  ) -> CGFloat {
    previewTimelineSplitMetrics(
      timelinePaneHeight: timelinePaneHeight,
      availableHeight: availableHeight
    ).previewHeight
  }

  static func previewTimelineSplitMetrics(
    timelinePaneHeight: CGFloat,
    availableHeight: CGFloat
  ) -> PreviewTimelineSplitMetrics {
    let available = max(1, availableHeight)
    let handleHeight = previewTimelineResizeHandleHeight
    let clampedTimelineHeight = clampedTimelinePaneHeight(
      timelinePaneHeight,
      availableHeight: available
    )
    let previewHeight = available - clampedTimelineHeight - handleHeight
    let resizeBandHeight = handleHeight + previewTimelineResizeHitSlop * 2
    return PreviewTimelineSplitMetrics(
      availableHeight: available,
      handleHeight: handleHeight,
      clampedTimelineHeight: clampedTimelineHeight,
      previewHeight: previewHeight,
      resizeBandHeight: resizeBandHeight,
      resizeBandOffsetY: max(0, previewHeight - previewTimelineResizeHitSlop)
    )
  }

  static func resolvedTimelinePaneHeight(
    proposed: CGFloat,
    availableHeight: CGFloat
  ) -> CGFloat {
    clampedTimelinePaneHeight(proposed, availableHeight: availableHeight)
  }

  struct PreviewTimelineSplitMetrics: Equatable {
    let availableHeight: CGFloat
    let handleHeight: CGFloat
    let clampedTimelineHeight: CGFloat
    let previewHeight: CGFloat
    let resizeBandHeight: CGFloat
    let resizeBandOffsetY: CGFloat
  }

  static func splitHeights(
    proposedPreviewHeight: CGFloat,
    availableHeight: CGFloat
  ) -> (preview: CGFloat, timeline: CGFloat) {
    let handleHeight = previewTimelineResizeHandleHeight
    let maxPreview = max(
      previewMinHeight,
      availableHeight - handleHeight - minTimelinePaneHeight
    )
    let preview = min(max(proposedPreviewHeight, previewMinHeight), maxPreview)
    let timeline = clampedTimelinePaneHeight(
      availableHeight - preview - handleHeight,
      availableHeight: availableHeight
    )
    return (preview, timeline)
  }

  static func loadStoredTimelinePaneHeight(defaults: UserDefaults = .standard) -> CGFloat {
    let stored = defaults.double(forKey: AppIdentifiers.UserDefaultsKeys.editorTimelinePaneHeight)
    guard stored > 0 else { return defaultTimelinePaneHeight }
    return max(minTimelinePaneHeight, CGFloat(stored))
  }

  static func saveTimelinePaneHeight(_ height: CGFloat, defaults: UserDefaults = .standard) {
    let key = AppIdentifiers.UserDefaultsKeys.editorTimelinePaneHeight
    let stored = defaults.double(forKey: key)
    guard abs(stored - Double(height)) > 0.5 else { return }
    defaults.set(Double(height), forKey: key)
  }
}

enum EditorPreviewLayout {
  static func stageSize(container: CGSize, aspectRatio: CGFloat, horizontalInset: CGFloat, verticalInset: CGFloat) -> CGSize {
    let availableWidth = max(1, container.width - horizontalInset)
    let availableHeight = max(1, container.height - verticalInset)
    let aspect = max(0.1, aspectRatio)
    let width = min(availableWidth, availableHeight * aspect)
    return CGSize(width: width, height: width / aspect)
  }

  static func visualScale(stageSize: CGSize) -> CGFloat {
    max(0.35, min(1.15, min(stageSize.width / 1280, stageSize.height / 720)))
  }

  static func cardRect(stageSize: CGSize, cardAspectRatio: CGFloat, padding: CGFloat) -> CGRect {
    ArcShotRenderGeometry.make(
      stageSize: stageSize,
      contentAspectRatio: cardAspectRatio,
      padding: padding,
      contentInset: 0,
      cornerRadius: 0,
      sourceKind: .display
    ).cardRect
  }

  static func cursorPoint(sample: RecordingProject.CursorSample, in size: CGSize) -> CGPoint {
    CGPoint(
      x: sample.x * size.width,
      y: (1 - sample.y) * size.height
    )
  }

  static func stageContentAspectRatio(
    outputAspectRatio: CGFloat,
    sourceKind: RecordingProject.SourceKind,
    sourceVideoSize: CGSize
  ) -> CGFloat {
    if sourceKind == .window,
       sourceVideoSize.width > 1,
       sourceVideoSize.height > 1 {
      return sourceVideoSize.width / sourceVideoSize.height
    }
    return max(0.1, outputAspectRatio)
  }

  static func aspectFitRect(sourceSize: CGSize, in containerSize: CGSize) -> CGRect {
    guard sourceSize.width > 0, sourceSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
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

  static func cursorPoint(
    sample: RecordingProject.CursorSample,
    in containerSize: CGSize,
    sourceSize: CGSize
  ) -> CGPoint {
    let videoRect = aspectFitRect(sourceSize: sourceSize, in: containerSize)
    return CGPoint(
      x: videoRect.minX + sample.x * videoRect.width,
      y: videoRect.minY + (1 - sample.y) * videoRect.height
    )
  }

  /// Visual masks use top-left normalized coordinates within the source video frame.
  static func maskRect(
    mask: RecordingProject.VisualMask,
    in containerSize: CGSize,
    sourceSize: CGSize,
    previewTransform: (scale: CGFloat, offset: CGSize) = (1, .zero)
  ) -> CGRect {
    let videoRect = aspectFitRect(sourceSize: sourceSize, in: containerSize)
    let base = CGRect(
      x: videoRect.minX + CGFloat(mask.originXN) * videoRect.width,
      y: videoRect.minY + CGFloat(mask.originYN) * videoRect.height,
      width: CGFloat(mask.widthN) * videoRect.width,
      height: CGFloat(mask.heightN) * videoRect.height
    )
    guard previewTransform.scale != 1 || previewTransform.offset != .zero else { return base }
    return CGRect(
      x: base.minX * previewTransform.scale + previewTransform.offset.width,
      y: base.minY * previewTransform.scale + previewTransform.offset.height,
      width: base.width * previewTransform.scale,
      height: base.height * previewTransform.scale
    )
  }

  static func maskRect(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double,
    in containerSize: CGSize,
    sourceSize: CGSize
  ) -> CGRect {
    maskRect(
      mask: RecordingProject.VisualMask(
        startSeconds: 0,
        endSeconds: 1,
        kind: .highlight,
        originXN: originXN,
        originYN: originYN,
        widthN: widthN,
        heightN: heightN
      ),
      in: containerSize,
      sourceSize: sourceSize
    )
  }

  static func zoomAnchorPoint(for keyframe: RecordingProject.ZoomKeyframe, in size: CGSize) -> CGPoint {
    zoomAnchorPoint(anchorX: keyframe.anchorX, anchorY: keyframe.anchorY, in: size)
  }

  static func zoomAnchorPoint(anchorX: Double, anchorY: Double, in size: CGSize) -> CGPoint {
    CGPoint(
      x: max(0, min(1, anchorX)) * size.width,
      y: (1 - max(0, min(1, anchorY))) * size.height
    )
  }

  static func zoomAnchorPoint(
    anchorX: Double,
    anchorY: Double,
    in containerSize: CGSize,
    sourceSize: CGSize
  ) -> CGPoint {
    let videoRect = aspectFitRect(sourceSize: sourceSize, in: containerSize)
    return CGPoint(
      x: videoRect.minX + max(0, min(1, anchorX)) * videoRect.width,
      y: videoRect.minY + (1 - max(0, min(1, anchorY))) * videoRect.height
    )
  }

  static func applyingPreviewZoom(
    to point: CGPoint,
    in size: CGSize,
    keyframe: RecordingProject.ZoomKeyframe?
  ) -> CGPoint {
    guard let keyframe else { return point }
    return applyingPreviewZoom(
      to: point,
      in: size,
      scale: keyframe.scale,
      anchorX: keyframe.anchorX,
      anchorY: keyframe.anchorY
    )
  }

  static func applyingPreviewZoom(
    to point: CGPoint,
    in size: CGSize,
    keyframe: RecordingProject.ZoomKeyframe?,
    motionFrame: RecordingProject.AutoZoomMotionFrame?
  ) -> CGPoint {
    if let keyframe {
      return applyingPreviewZoom(to: point, in: size, keyframe: keyframe)
    }
    guard let motionFrame else { return point }
    return applyingPreviewZoom(
      to: point,
      in: size,
      scale: motionFrame.scale,
      anchorX: motionFrame.anchorX,
      anchorY: motionFrame.anchorY
    )
  }

  static func applyingPreviewZoom(
    to point: CGPoint,
    in size: CGSize,
    scale: Double,
    anchorX: Double,
    anchorY: Double
  ) -> CGPoint {
    let scale = CGFloat(max(1, min(3, scale)))
    let anchor = zoomAnchorPoint(anchorX: anchorX, anchorY: anchorY, in: size)
    return CGPoint(
      x: anchor.x + (point.x - anchor.x) * scale,
      y: anchor.y + (point.y - anchor.y) * scale
    )
  }

  static func applyingPreviewZoom(
    to point: CGPoint,
    in containerSize: CGSize,
    sourceSize: CGSize,
    keyframe: RecordingProject.ZoomKeyframe?,
    motionFrame: RecordingProject.AutoZoomMotionFrame?
  ) -> CGPoint {
    if let keyframe {
      return applyingPreviewZoom(
        to: point,
        in: containerSize,
        sourceSize: sourceSize,
        scale: keyframe.scale,
        anchorX: keyframe.anchorX,
        anchorY: keyframe.anchorY
      )
    }
    guard let motionFrame else { return point }
    return applyingPreviewZoom(
      to: point,
      in: containerSize,
      sourceSize: sourceSize,
      scale: motionFrame.scale,
      anchorX: motionFrame.anchorX,
      anchorY: motionFrame.anchorY
    )
  }

  static func applyingPreviewZoom(
    to point: CGPoint,
    in containerSize: CGSize,
    sourceSize: CGSize,
    scale: Double,
    anchorX: Double,
    anchorY: Double
  ) -> CGPoint {
    let scale = CGFloat(max(1, min(3, scale)))
    let anchor = zoomAnchorPoint(anchorX: anchorX, anchorY: anchorY, in: containerSize, sourceSize: sourceSize)
    return CGPoint(
      x: anchor.x + (point.x - anchor.x) * scale,
      y: anchor.y + (point.y - anchor.y) * scale
    )
  }

  static func previewZoomTransform(
    visibleSourceRect: CGRect,
    in containerSize: CGSize,
    sourceSize: CGSize
  ) -> (scale: CGFloat, offset: CGSize) {
    let layoutSize = stablePreviewContainerSize(containerSize)
    let videoRect = aspectFitRect(sourceSize: sourceSize, in: layoutSize)
    guard videoRect.width > 0, videoRect.height > 0 else {
      return (1, .zero)
    }

    let visibleWidth = CGFloat(max(RecordingProject.ZoomSegment.minTargetRegionSize, min(1, visibleSourceRect.width)))
    let visibleHeight = CGFloat(max(RecordingProject.ZoomSegment.minTargetRegionSize, min(1, visibleSourceRect.height)))
    let visibleX = CGFloat(max(0, min(1 - visibleWidth, visibleSourceRect.minX)))
    let visibleY = CGFloat(max(0, min(1 - visibleHeight, visibleSourceRect.minY)))
    let scale = min(1 / visibleWidth, 1 / visibleHeight)
    let visibleRect = CGRect(
      x: videoRect.minX + visibleX * videoRect.width,
      y: videoRect.maxY - (visibleY + visibleHeight) * videoRect.height,
      width: visibleWidth * videoRect.width,
      height: visibleHeight * videoRect.height
    )

    return pixelSnappedPreviewZoomTransform(
      scale: scale,
      offset: CGSize(
        width: videoRect.minX - visibleRect.minX * scale,
        height: videoRect.minY - visibleRect.minY * scale
      )
    )
  }

  /// Floors preview layout dimensions so GeometryReader micro-drift does not re-fit video every frame.
  static func stablePreviewContainerSize(_ size: CGSize) -> CGSize {
    CGSize(
      width: max(1, size.width.rounded(.down)),
      height: max(1, size.height.rounded(.down))
    )
  }

  /// Snaps translation to the device pixel grid while zoomed to reduce shimmering during hold.
  static func pixelSnappedPreviewZoomTransform(
    scale: CGFloat,
    offset: CGSize,
    pixelScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
  ) -> (scale: CGFloat, offset: CGSize) {
    guard scale > 1.0001 else { return (1, .zero) }
    let safeScale = max(1, pixelScale)
    func snapToPixelGrid(_ value: CGFloat) -> CGFloat {
      (value * safeScale).rounded(.toNearestOrAwayFromZero) / safeScale
    }
    return (
      scale,
      CGSize(
        width: snapToPixelGrid(offset.width),
        height: snapToPixelGrid(offset.height)
      )
    )
  }

  static func applyingPreviewZoom(
    to point: CGPoint,
    in containerSize: CGSize,
    sourceSize: CGSize,
    visibleSourceRect: CGRect
  ) -> CGPoint {
    let transform = previewZoomTransform(
      visibleSourceRect: visibleSourceRect,
      in: containerSize,
      sourceSize: sourceSize
    )
    return CGPoint(
      x: point.x * transform.scale + transform.offset.width,
      y: point.y * transform.scale + transform.offset.height
    )
  }

  static func applyingPreviewZoom(
    to rect: CGRect,
    in containerSize: CGSize,
    sourceSize: CGSize,
    visibleSourceRect: CGRect
  ) -> CGRect {
    let transform = previewZoomTransform(
      visibleSourceRect: visibleSourceRect,
      in: containerSize,
      sourceSize: sourceSize
    )
    return CGRect(
      x: rect.minX * transform.scale + transform.offset.width,
      y: rect.minY * transform.scale + transform.offset.height,
      width: rect.width * transform.scale,
      height: rect.height * transform.scale
    )
  }
}

struct ArcShotRenderGeometry: Equatable {
  var stageRect: CGRect
  var cardRect: CGRect
  var contentRect: CGRect
  var cardCornerRadius: CGFloat
  var sourceCornerRadius: CGFloat
  /// Export-only clip radius for window captures (continuous mask + minimal fringe margin).
  var windowExportClipRadius: CGFloat?
  var visualScale: CGFloat

  /// Whole-pixel clip rect for window export; floors size so pixelAligned never expands past layout (avoids right-edge gap).
  static func windowExportClipRect(_ contentRect: CGRect) -> CGRect {
    CGRect(
      x: contentRect.minX.rounded(.down),
      y: contentRect.minY.rounded(.down),
      width: max(1, contentRect.width.rounded(.down)),
      height: max(1, contentRect.height.rounded(.down))
    )
  }

  /// Maps canvas aspect-fit video into the stage content card.
  /// Window captures use the same aspect-fit-in-card mapping as preview (`resizeAspect`), avoiding
  /// non-uniform stretch that leaves a right-edge extent gap and exposes capture fringe in corners.
  func stageVideoTransform(
    canvasSize: CGSize,
    sourceVideoSize: CGSize,
    sourceKind: RecordingProject.SourceKind
  ) -> CGAffineTransform {
    let clipRect = Self.windowExportClipRect(contentRect)
    switch sourceKind {
    case .window:
      guard canvasSize.width > 1, canvasSize.height > 1,
            sourceVideoSize.width > 1, sourceVideoSize.height > 1 else { return .identity }
      let canvasFit = EditorPreviewLayout.aspectFitRect(
        sourceSize: sourceVideoSize,
        in: canvasSize
      )
      let fitInClip = EditorPreviewLayout.aspectFitRect(
        sourceSize: sourceVideoSize,
        in: clipRect.size
      )
      guard canvasFit.width > 1, canvasFit.height > 1 else { return .identity }
      let scale = fitInClip.width / canvasFit.width
      return CGAffineTransform(
        translationX: clipRect.minX + fitInClip.minX,
        y: clipRect.minY + fitInClip.minY
      )
      .scaledBy(x: scale, y: scale)
      .concatenating(CGAffineTransform(
        translationX: -canvasFit.minX,
        y: -canvasFit.minY
      ))
    case .display, .area:
      return contentTransform(from: canvasSize, clipRect: clipRect)
    }
  }

  func contentTransform(from sourceSize: CGSize, clipRect: CGRect? = nil) -> CGAffineTransform {
    guard sourceSize.width > 1, sourceSize.height > 1 else { return .identity }
    let aligned = clipRect ?? Self.windowExportClipRect(contentRect)
    return CGAffineTransform(translationX: aligned.minX, y: aligned.minY)
      .scaledBy(x: aligned.width / sourceSize.width, y: aligned.height / sourceSize.height)
  }

  static func make(
    stageSize: CGSize,
    contentAspectRatio: CGFloat,
    padding: CGFloat,
    contentInset: CGFloat,
    cornerRadius: CGFloat,
    sourceKind: RecordingProject.SourceKind,
    sourceVideoSize: CGSize = .zero
  ) -> ArcShotRenderGeometry {
    let stageRect = CGRect(origin: .zero, size: stageSize)
    let cardRect = fitRect(
      aspectRatio: contentAspectRatio,
      inside: stageRect,
      padding: padding
    )
    let safeInset = max(0, min(contentInset, min(cardRect.width, cardRect.height) * 0.18))
    let contentRect = cardRect.insetBy(dx: safeInset, dy: safeInset)

    if sourceKind == .window {
      let nativeCornerRadius = windowCaptureCornerRadius(
        contentRect: contentRect,
        sourceVideoSize: sourceVideoSize
      )
      return ArcShotRenderGeometry(
        stageRect: stageRect,
        cardRect: cardRect,
        contentRect: contentRect,
        cardCornerRadius: nativeCornerRadius,
        sourceCornerRadius: nativeCornerRadius,
        windowExportClipRadius: windowExportClipRadius(
          contentRect: contentRect,
          sourceVideoSize: sourceVideoSize,
          visualRadius: nativeCornerRadius
        ),
        visualScale: visualScale(stageSize: stageSize)
      )
    }

    let cardRadius = effectiveCornerRadius(
      requested: cornerRadius,
      rect: cardRect,
      minimum: 0
    )

    // Display/area captures keep square source video; macOS window chrome rounding is window-only.
    return ArcShotRenderGeometry(
      stageRect: stageRect,
      cardRect: cardRect,
      contentRect: contentRect,
      cardCornerRadius: cardRadius,
      sourceCornerRadius: 0,
      visualScale: visualScale(stageSize: stageSize)
    )
  }

  static func visualScale(stageSize: CGSize) -> CGFloat {
    max(0.35, min(1.15, min(stageSize.width / 1280, stageSize.height / 720)))
  }

  private static func fitRect(
    aspectRatio: CGFloat,
    inside bounds: CGRect,
    padding: CGFloat
  ) -> CGRect {
    let safePadding = max(0, min(padding, min(bounds.width, bounds.height) * 0.32))
    let available = bounds.insetBy(dx: safePadding, dy: safePadding)
    guard available.width > 1, available.height > 1 else {
      return bounds.insetBy(dx: max(0, bounds.width * 0.08), dy: max(0, bounds.height * 0.08))
    }

    let aspect = max(0.1, aspectRatio)
    let availableAspect = available.width / available.height
    let size: CGSize
    if aspect >= availableAspect {
      size = CGSize(width: available.width, height: available.width / aspect)
    } else {
      size = CGSize(width: available.height * aspect, height: available.height)
    }

    return CGRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  private static func effectiveCornerRadius(
    requested: CGFloat,
    rect: CGRect,
    minimum: CGFloat
  ) -> CGFloat {
    guard rect.width > 1, rect.height > 1 else { return 0 }
    return min(max(0, max(requested, minimum)), min(rect.width, rect.height) / 2)
  }

  private enum WindowCaptureChrome {
    /// Standard macOS window corner radius in points (Big Sur and later, continuous curve).
    static let cornerRadiusPts: CGFloat = 10
    /// Card-space padding for clip anti-aliasing after source→card scaling.
    static let cardSpaceOverscanPts: CGFloat = 2
    /// H.264 fringe extent measured in source pixels (alpha flattened to black).
    static let minimumMeasuredFringeSourcePx: CGFloat = 34
    static let measuredFringeFraction: CGFloat = 0.027
    /// Extra symmetric card-space margin beyond measured fringe (export + preview clip).
    static let exportFringeMarginPts: CGFloat = 14
  }

  /// Matches Big Sur+ window chrome: ~10pt continuous corners scaled into card space (preview + card layout).
  static func windowCaptureCornerRadius(
    contentRect: CGRect,
    sourceVideoSize: CGSize
  ) -> CGFloat {
    guard sourceVideoSize.width > 1, sourceVideoSize.height > 1,
          contentRect.width > 1, contentRect.height > 1 else {
      return WindowCaptureChrome.cornerRadiusPts
    }

    let fitScale = min(
      contentRect.width / sourceVideoSize.width,
      contentRect.height / sourceVideoSize.height
    )
    let macOSNativeRadius =
      WindowCaptureChrome.cornerRadiusPts * fitScale + WindowCaptureChrome.cardSpaceOverscanPts
    return effectiveCornerRadius(
      requested: macOSNativeRadius,
      rect: contentRect,
      minimum: 0
    )
  }

  /// Export clip radius: same on all four corners; large enough to hide H.264 fringe symmetrically.
  static func windowExportClipRadius(
    contentRect: CGRect,
    sourceVideoSize: CGSize,
    visualRadius: CGFloat
  ) -> CGFloat {
    guard sourceVideoSize.width > 1, sourceVideoSize.height > 1,
          contentRect.width > 1, contentRect.height > 1 else {
      return visualRadius
    }

    let fitScale = min(
      contentRect.width / sourceVideoSize.width,
      contentRect.height / sourceVideoSize.height
    )
    let minDim = min(sourceVideoSize.width, sourceVideoSize.height)
    let fringeSourcePx = max(
      WindowCaptureChrome.minimumMeasuredFringeSourcePx,
      minDim * WindowCaptureChrome.measuredFringeFraction
    )
    let fringeRadius = fringeSourcePx * fitScale + WindowCaptureChrome.cardSpaceOverscanPts
      + WindowCaptureChrome.exportFringeMarginPts
    return effectiveCornerRadius(
      requested: max(visualRadius, fringeRadius),
      rect: contentRect,
      minimum: visualRadius
    )
  }
}

extension AspectRatioPreset {
  var editorPreviewAspectRatio: CGFloat {
    switch self {
    case .sixteenNine:
      return 16.0 / 9.0
    case .nineSixteen:
      return 9.0 / 16.0
    case .oneOne:
      return 1.0
    case .fourThree:
      return 4.0 / 3.0
    case .threeFour:
      return 3.0 / 4.0
    }
  }
}

extension CGRect {
  /// Expands to a whole-pixel rect that fully contains the layout rect (avoids edge drift).
  var pixelAligned: CGRect {
    let minX = origin.x.rounded(.down)
    let minY = origin.y.rounded(.down)
    let maxX = (origin.x + width).rounded(.up)
    let maxY = (origin.y + height).rounded(.up)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

func editorFormatTime(_ seconds: Double, fractional: Bool = false) -> String {
  guard seconds.isFinite else { return "0:00" }
  let safe = max(0, seconds)
  let minutes = Int(safe) / 60
  let wholeSeconds = Int(safe) % 60
  if fractional {
    let hundredths = Int(round((safe - floor(safe)) * 100)) % 100
    return String(format: "%d:%02d.%02d", minutes, wholeSeconds, hundredths)
  }
  return String(format: "%d:%02d", minutes, wholeSeconds)
}
