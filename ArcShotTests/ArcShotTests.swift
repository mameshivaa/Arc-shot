import AppKit
import AVFoundation
import ScreenCaptureKit
import XCTest

@testable import ArcShot

final class ArcShotTests: XCTestCase {
  func testTimelineCoordinateSpaceMapsSourceSecondsToX() {
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: 10,
      previewDurationSeconds: 10,
      width: 1000
    )

    XCTAssertEqual(space.sourceX(for: 0), 0, accuracy: 1e-9)
    XCTAssertEqual(space.sourceX(for: 5), 500, accuracy: 1e-9)
    XCTAssertEqual(space.sourceX(for: 10), 1000, accuracy: 1e-9)
    XCTAssertEqual(space.sourceSeconds(forX: -10), 0, accuracy: 1e-9)
    XCTAssertEqual(space.sourceSeconds(forX: 1200), 10, accuracy: 1e-9)
  }

  func testTimelineCoordinateSpaceKeepsTrueCoordinateSeparateFromFrameClamp() {
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: 10,
      previewDurationSeconds: 10,
      timelineDurationSeconds: 10,
      width: 1000
    )

    XCTAssertEqual(space.timelineX(for: 10), 1000, accuracy: 1e-9)
    XCTAssertEqual(space.frameX(for: 10, itemWidth: 120), 880, accuracy: 1e-9)
    XCTAssertEqual(space.frameX(for: 5, itemWidth: 120), 500, accuracy: 1e-9)
  }

  func testTimelineCoordinateSpaceRoundTripsAllAxes() {
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: 10,
      previewDurationSeconds: 6,
      timelineDurationSeconds: 3,
      width: 900
    )

    XCTAssertEqual(space.sourceSeconds(forX: space.sourceX(for: 7.5)), 7.5, accuracy: 1e-9)
    XCTAssertEqual(space.previewSeconds(forX: space.previewX(for: 4.5)), 4.5, accuracy: 1e-9)
    XCTAssertEqual(space.timelineSeconds(forX: space.timelineX(for: 2.25)), 2.25, accuracy: 1e-9)
  }

  func testTimelineViewportScalesContentWidthAndCoordinateSpace() {
    let fit = TimelineViewport(durationSeconds: 10, visibleWidth: 1000, zoomScale: 1)
    XCTAssertEqual(fit.contentWidth, 1000, accuracy: 1e-9)
    XCTAssertEqual(fit.activeContentWidth, 1000 - EditorLayout.timelineLaneInsetX * 2, accuracy: 1e-9)

    let zoomed = TimelineViewport(durationSeconds: 10, visibleWidth: 1000, zoomScale: 4)
    XCTAssertEqual(zoomed.contentWidth, 4000, accuracy: 1e-9)
    XCTAssertEqual(zoomed.coordinateSpace.timelineX(for: 10), zoomed.activeContentWidth, accuracy: 1e-9)
  }

  func testTimelineViewportClampsZoomScale() {
    XCTAssertEqual(TimelineViewport(durationSeconds: 10, visibleWidth: 1000, zoomScale: 0.25).zoomScale, 1, accuracy: 1e-9)
    XCTAssertEqual(TimelineViewport(durationSeconds: 10, visibleWidth: 1000, zoomScale: 12).zoomScale, 8, accuracy: 1e-9)
  }

  func testTimelineViewportVisibleRangeAndCenteredOffsetClamp() {
    let viewport = TimelineViewport(durationSeconds: 10, visibleWidth: 1000, zoomScale: 4, horizontalInset: 0)

    XCTAssertEqual(viewport.visibleRange(forOffsetX: 1000).startSeconds, 2.5, accuracy: 1e-9)
    XCTAssertEqual(viewport.visibleRange(forOffsetX: 1000).endSeconds, 5, accuracy: 1e-9)
    XCTAssertEqual(viewport.offsetX(centeredOn: 5), 1500, accuracy: 1e-9)
    XCTAssertEqual(viewport.offsetX(centeredOn: 0), 0, accuracy: 1e-9)
    XCTAssertEqual(viewport.offsetX(centeredOn: 10), 3000, accuracy: 1e-9)
  }

  func testTimelineSnapPolicySnapsNearestTargetWithinThreshold() {
    let policy = TimelineSnapPolicy(
      enabled: true,
      targets: [TimelineSnapTarget(seconds: 2), TimelineSnapTarget(seconds: 5)],
      thresholdSeconds: 0.15,
      validRange: 0...10
    )

    XCTAssertEqual(policy.snappedSeconds(for: 1.9), 2, accuracy: 1e-9)
    XCTAssertEqual(policy.snappedSeconds(for: 4.7), 4.7, accuracy: 1e-9)
  }

  func testTimelineSnapPolicyHonorsDisabledClampAndTieBreak() {
    let disabled = TimelineSnapPolicy(
      enabled: false,
      targets: [TimelineSnapTarget(seconds: 4)],
      thresholdSeconds: 1,
      validRange: 0...3
    )
    XCTAssertEqual(disabled.snappedSeconds(for: 4.5), 3, accuracy: 1e-9)

    let tie = TimelineSnapPolicy(
      enabled: true,
      targets: [TimelineSnapTarget(seconds: 4), TimelineSnapTarget(seconds: 6)],
      thresholdSeconds: 1,
      validRange: 0...10
    )
    XCTAssertEqual(tie.snappedSeconds(for: 5), 4, accuracy: 1e-9)
  }

  func testTimelineSnapPolicyReturnsTargetMetadata() {
    let policy = TimelineSnapPolicy(
      enabled: true,
      targets: [TimelineSnapTarget(seconds: 2, label: "Clip In")],
      thresholdSeconds: 0.15,
      validRange: 0...10
    )

    let result = policy.snappedResult(for: 2.1)
    XCTAssertTrue(result.didSnap)
    XCTAssertEqual(result.seconds, 2, accuracy: 1e-9)
    XCTAssertEqual(result.target?.label, "Clip In")
  }

  func testTimelineThumbnailPlannerUsesVisibleRangeOnly() {
    let times = TimelineThumbnailStripModel.plannedTimes(
      visibleRange: TimelineVisibleRange(startSeconds: 10, endSeconds: 20),
      durationSeconds: 120,
      targetPixelWidth: 300,
      thumbnailWidth: 100
    )

    XCTAssertFalse(times.isEmpty)
    XCTAssertGreaterThanOrEqual(try! XCTUnwrap(times.first), 10 - 1e-9)
    XCTAssertLessThanOrEqual(try! XCTUnwrap(times.last), 20 + 1e-9)
  }

  func testTimelineWaveformDownsampleClampsAndKeepsPeaks() {
    let bins = TimelineWaveformModel.downsample([-1, 0.25, 2, 0.5], targetCount: 2)

    XCTAssertEqual(bins, [0.25, 1])
  }

  func testTimelineCoordinateSpaceMapsTrimmedPreviewToSourceSeconds() {
    let previewDuration = TimelineCoordinateSpace.previewDurationSeconds(
      sourceStartSeconds: 2,
      sourceEndSeconds: 8
    )
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: 10,
      previewDurationSeconds: previewDuration,
      width: 1000
    )

    XCTAssertEqual(
      space.sourceSeconds(forPreviewSeconds: 0, sourceStartSeconds: 2, sourceEndSeconds: 8),
      2,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      space.sourceSeconds(forPreviewSeconds: 3, sourceStartSeconds: 2, sourceEndSeconds: 8),
      5,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      space.sourceSeconds(forPreviewSeconds: 6, sourceStartSeconds: 2, sourceEndSeconds: 8),
      8,
      accuracy: 1e-9
    )
  }

  func testTimelineCoordinateSpaceMapsSpeedAdjustedPreviewToSourceSeconds() {
    let previewDuration = TimelineCoordinateSpace.previewDurationSeconds(
      sourceStartSeconds: 2,
      sourceEndSeconds: 8,
      playbackRate: 2
    )
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: 10,
      previewDurationSeconds: previewDuration,
      width: 1000
    )

    XCTAssertEqual(previewDuration, 3, accuracy: 1e-9)
    XCTAssertEqual(
      space.sourceSeconds(forPreviewSeconds: 0, sourceStartSeconds: 2, sourceEndSeconds: 8, playbackRate: 2),
      2,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      space.sourceSeconds(forPreviewSeconds: 1.5, sourceStartSeconds: 2, sourceEndSeconds: 8, playbackRate: 2),
      5,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      space.sourceSeconds(forPreviewSeconds: 3, sourceStartSeconds: 2, sourceEndSeconds: 8, playbackRate: 2),
      8,
      accuracy: 1e-9
    )
  }

  func testEditorPreviewFadeIntroOpacityMatchesExportSemantics() {
    let style = RecordingProject.StyleSettings(introFadeSeconds: 2, outroFadeSeconds: 0)

    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 0, durationSeconds: 10, styleSettings: style),
      1,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 1, durationSeconds: 10, styleSettings: style),
      0.5,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 2, durationSeconds: 10, styleSettings: style),
      0,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 2.1, durationSeconds: 10, styleSettings: style),
      0,
      accuracy: 1e-9
    )
  }

  func testEditorPreviewFadeOutroOpacityMatchesExportSemantics() {
    let style = RecordingProject.StyleSettings(introFadeSeconds: 0, outroFadeSeconds: 2)

    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 7.9, durationSeconds: 10, styleSettings: style),
      0,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 9, durationSeconds: 10, styleSettings: style),
      0.5,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 10, durationSeconds: 10, styleSettings: style),
      1,
      accuracy: 1e-9
    )
  }

  func testEditorPreviewFadeReturnsZeroForZeroFadesOrInvalidDuration() {
    let zeroFadeStyle = RecordingProject.StyleSettings(introFadeSeconds: 0, outroFadeSeconds: 0)
    let fadeStyle = RecordingProject.StyleSettings(introFadeSeconds: 1, outroFadeSeconds: 1)

    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 0, durationSeconds: 10, styleSettings: zeroFadeStyle),
      0,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 0.5, durationSeconds: 0, styleSettings: fadeStyle),
      0,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewFade.opacity(timeSeconds: 0.5, durationSeconds: -1, styleSettings: fadeStyle),
      0,
      accuracy: 1e-9
    )
  }

  func testExportVisualSettingsClampsInvalidHex() {
    let v = RecordingProject.ExportVisualSettings(
      stageStyle: .roundedCard,
      backgroundKind: .solid,
      backgroundColorHex: "not-a-color",
      gradientEndColorHex: "####",
      backgroundBlur: 999,
      backgroundPadding: 999,
      contentCornerRadius: 500,
      contentInset: -10,
      dropShadowOpacity: -3,
      shadowRadius: 999,
      shadowYOffset: 1000,
      enabledForDisplayCapture: true,
      deviceFramePreset: .none
    )

    XCTAssertEqual(v.backgroundColorHex, RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageBackgroundFallbackHex)
    XCTAssertEqual(v.gradientEndColorHex, RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageGradientEndFallbackHex)
    XCTAssertEqual(v.backgroundBlur, RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.backgroundBlurMaxPts)
    XCTAssertEqual(v.backgroundPadding, RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.backgroundPaddingMaxPts)
    XCTAssertEqual(v.contentCornerRadius, RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.contentCornerRadiusMaxPts)
    XCTAssertEqual(v.contentInset, 0, accuracy: 1e-9)
    XCTAssertEqual(v.dropShadowOpacity, 0, accuracy: 1e-9)
    XCTAssertEqual(v.shadowRadius, RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.shadowRadiusMaxPts)
    XCTAssertEqual(
      v.shadowYOffset,
      RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.shadowYOffsetMaxAbsPts,
      accuracy: 1e-9
    )
  }

  func testEffectiveCornerRadiusPtsRespectsInsetBounds() {
    let uncapped = RecordingProject.ExportVisualSettings.effectiveCornerRadiusPts(
      requested: 80,
      contentRectSideMinPts: 120
    )
    XCTAssertEqual(Double(uncapped), 48, accuracy: 0.01)

    let capped = RecordingProject.ExportVisualSettings.effectiveCornerRadiusPts(
      requested: 48,
      contentRectSideMinPts: 70
    )
    XCTAssertEqual(Double(capped), 34.3, accuracy: 0.15)
  }

  func testExportVisualDefaultsStageAllCaptureKinds() {
    for kind in [RecordingProject.SourceKind.display, .window, .area] {
      let settings = RecordingProject.ExportVisualSettings.defaulted(forSourceKind: kind)
      XCTAssertEqual(settings.stageStyle, .roundedCard)
      XCTAssertEqual(settings.backgroundKind, .linearGradientVertical)
      XCTAssertTrue(settings.enabledForDisplayCapture)
      XCTAssertGreaterThan(settings.backgroundPadding, 0)
      XCTAssertGreaterThan(settings.contentCornerRadius, 0)
      XCTAssertEqual(settings.contentInset, 0, accuracy: 1e-9)
    }
  }

  func testRecordingProjectRejectsOutdatedSchema() throws {
    let project = RecordingProject(
      schemaVersion: 7,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000087")!,
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Outdated",
      source: .init(kind: .window, displayID: nil, windowID: 10),
      mediaURL: URL(fileURLWithPath: "/tmp/outdated.mov"),
      cursorSamples: [],
      exportPreset: .p1080p60,
      stylePreset: .none
    )

    let data = try JSONEncoder.iso8601Test.encode(project)

    XCTAssertThrowsError(try JSONDecoder.iso8601Test.decode(RecordingProject.self, from: data))
  }

  func testRecordingProjectRejectsRemovedProjectFields() throws {
    let json = """
    {
      "schemaVersion": 8,
      "id": "00000000-0000-0000-0000-000000000088",
      "createdAt": "1970-01-01T00:00:00Z",
      "title": "Removed Fields",
      "source": { "kind": "window", "displayID": null, "windowID": 10 },
      "mediaURL": "file:///tmp/removed.mov",
      "trim": { "startSeconds": 0, "endSeconds": 1 },
      "zoomKeyframes": [],
      "cursorSamples": [],
      "exportPreset": "p1080p60",
      "stylePreset": "none",
      "timeline": { "clips": [], "speedSegments": [] },
      "zoomSegments": []
    }
    """
    let data = try XCTUnwrap(json.data(using: .utf8))

    XCTAssertThrowsError(try JSONDecoder.iso8601Test.decode(RecordingProject.self, from: data))
  }

  func testRecordingProjectDecodesWithoutAutoZoomAnalysis() throws {
    let json = """
    {
      "schemaVersion": 8,
      "id": "00000000-0000-0000-0000-000000000089",
      "createdAt": "1970-01-01T00:00:00Z",
      "title": "No Analysis",
      "source": { "kind": "window", "displayID": null, "windowID": 10 },
      "mediaURL": "file:///tmp/no-analysis.mov",
      "cursorSamples": [],
      "exportPreset": "p1080p60",
      "stylePreset": "none",
      "timeline": { "clips": [], "speedSegments": [] },
      "zoomSegments": []
    }
    """
    let data = try XCTUnwrap(json.data(using: .utf8))
    let project = try JSONDecoder.iso8601Test.decode(RecordingProject.self, from: data)
    XCTAssertNil(project.autoZoomAnalysis)
  }

  func testRecordingProjectRoundTripsAutoZoomAnalysis() throws {
    let analysis = RecordingProject.AutoZoomAnalysis(
      sourceSignature: "sig",
      assetDurationSeconds: 2,
      focusRegions: [
        FocusRegion(
          startSeconds: 0.2,
          endSeconds: 0.8,
          bounds: CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.1),
          kind: .clickTarget,
          confidence: 0.9
        ),
      ],
      motionFrames: [
        RecordingProject.AutoZoomMotionFrame(timeSeconds: 0, anchorX: 0.5, anchorY: 0.5, scale: 1),
        RecordingProject.AutoZoomMotionFrame(timeSeconds: 1, anchorX: 0.4, anchorY: 0.4, scale: 1.4),
      ],
      editableSegments: [
        RecordingProject.ZoomSegment(startSeconds: 0.2, endSeconds: 1.4, mode: .auto, scale: 1.4, anchorX: 0.4, anchorY: 0.4),
      ]
    )
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Analysis",
      source: .init(kind: .window, displayID: nil, windowID: 10),
      mediaURL: URL(fileURLWithPath: "/tmp/analysis.mov"),
      cursorSamples: [],
      exportPreset: .p1080p60,
      stylePreset: .cursorFocus,
      autoZoomAnalysis: analysis
    )

    let data = try JSONEncoder.iso8601Test.encode(project)
    let decoded = try JSONDecoder.iso8601Test.decode(RecordingProject.self, from: data)
    XCTAssertEqual(decoded.autoZoomAnalysis, analysis)
  }

  func testStagePolicyUsesDisplayToggleForDisplayLikeCapture() {
    var settings = RecordingProject.ExportVisualSettings.defaulted(forSourceKind: .window)
    settings.enabledForDisplayCapture = false

    XCTAssertTrue(
      Exporter.ExportStageLayoutPolicy.shouldApply(
        settings: settings,
        sourceKind: .window
      )
    )
    XCTAssertFalse(
      Exporter.ExportStageLayoutPolicy.shouldApply(
        settings: settings,
        sourceKind: .display
      )
    )

    settings.enabledForDisplayCapture = true
    XCTAssertTrue(
      Exporter.ExportStageLayoutPolicy.shouldApply(
        settings: settings,
        sourceKind: .display
      )
    )
  }

  func testHighlightRegionsShiftForTrimmedCompositionExport() {
    let regions = [
      RecordingProject.CursorHighlightRegion(
        startSeconds: 2.5,
        endSeconds: 4.0
      ),
    ]

    let shifted = RecordingProject.shiftHighlightRegionsForCompositionExport(
      regions,
      sourceStartSeconds: 1.25
    )

    XCTAssertEqual(shifted.count, 1)
    XCTAssertEqual(shifted[0].startSeconds, 1.25, accuracy: 1e-9)
    XCTAssertEqual(shifted[0].endSeconds, 2.75, accuracy: 1e-9)
  }

  func testEditorPreviewLayoutUsesOutputAspectForCard() {
    let stage = CGSize(width: 1280, height: 720)
    let rect = EditorPreviewLayout.cardRect(stageSize: stage, cardAspectRatio: 16.0 / 9.0, padding: 36)

    XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
    XCTAssertEqual(rect.minY, 36, accuracy: 0.001)
    XCTAssertEqual(rect.maxY, stage.height - 36, accuracy: 0.001)
    XCTAssertGreaterThan(rect.width, 1100)
  }

  func testEditorPreviewLayoutClampsExcessivePadding() {
    let stage = CGSize(width: 640, height: 360)
    let rect = EditorPreviewLayout.cardRect(stageSize: stage, cardAspectRatio: 16.0 / 9.0, padding: 10_000)

    XCTAssertGreaterThan(rect.width, 0)
    XCTAssertGreaterThan(rect.height, 0)
    XCTAssertEqual(rect.midX, stage.width / 2, accuracy: 0.001)
    XCTAssertEqual(rect.midY, stage.height / 2, accuracy: 0.001)
  }

  func testArcShotRenderGeometryMatchesEditorFloatingVideoRect() {
    let stage = CGSize(width: 1280, height: 720)
    let legacy = EditorPreviewLayout.cardRect(
      stageSize: stage,
      cardAspectRatio: 16.0 / 9.0,
      padding: 24
    )
    let geometry = ArcShotRenderGeometry.make(
      stageSize: stage,
      contentAspectRatio: 16.0 / 9.0,
      padding: 24,
      contentInset: 0,
      cornerRadius: 18,
      sourceKind: .window,
      sourceVideoSize: CGSize(width: 1820, height: 1378)
    )

    XCTAssertEqual(geometry.cardRect, legacy)
    XCTAssertEqual(geometry.contentRect, legacy)
    let fitScale = min(
      geometry.contentRect.width / 1820,
      geometry.contentRect.height / 1378
    )
    let expectedNativeRadius = 10 * fitScale + 2
    XCTAssertEqual(geometry.sourceCornerRadius, expectedNativeRadius, accuracy: 0.01)
    XCTAssertLessThan(geometry.sourceCornerRadius, 16)
    XCTAssertEqual(geometry.sourceCornerRadius, geometry.cardCornerRadius)
  }

  func testWindowCaptureCornerRadiusMatchesMacOSChrome() {
    let contentRect = CGRect(x: 40, y: 24, width: 1194, height: 672)
    let sourceSize = CGSize(width: 1820, height: 1378)
    let fitScale = min(contentRect.width / sourceSize.width, contentRect.height / sourceSize.height)
    let visual = ArcShotRenderGeometry.windowCaptureCornerRadius(
      contentRect: contentRect,
      sourceVideoSize: sourceSize
    )
    let exportClip = ArcShotRenderGeometry.windowExportClipRadius(
      contentRect: contentRect,
      sourceVideoSize: sourceSize,
      visualRadius: visual
    )
    XCTAssertEqual(visual, 10 * fitScale + 2, accuracy: 0.01)
    XCTAssertGreaterThanOrEqual(exportClip, visual)
  }

  func testArcShotRenderGeometryUsesSquareClipForDisplayCapture() {
    let geometry = ArcShotRenderGeometry.make(
      stageSize: CGSize(width: 1280, height: 720),
      contentAspectRatio: 16.0 / 9.0,
      padding: 24,
      contentInset: 0,
      cornerRadius: 18,
      sourceKind: .display
    )

    XCTAssertEqual(geometry.sourceCornerRadius, 0, accuracy: 0.01)
    XCTAssertGreaterThan(geometry.cardCornerRadius, 0)
  }

  func testExportStageCardShadowMatchesPreviewNonWindowRule() {
    let geometry = ArcShotRenderGeometry.make(
      stageSize: CGSize(width: 1280, height: 720),
      contentAspectRatio: 16.0 / 9.0,
      padding: 48,
      contentInset: 0,
      cornerRadius: 24,
      sourceKind: .display
    )
    let shadow = ArcShotVideoCompositor.stageCardShadow(
      stage: ArcShotCompositionInstruction.StageConfig(
        useStage: true,
        padding: 48,
        cornerRadius: 24,
        contentInset: 0,
        shadowOpacity: 0.5,
        shadowRadius: 20,
        shadowYOffset: 10,
        backgroundSettings: .defaulted(forSourceKind: .display),
        sourceKind: .display
      ),
      geometry: geometry
    )

    XCTAssertEqual(shadow?.opacity ?? -1, 0.21, accuracy: 1e-9)
    XCTAssertEqual(shadow?.blurRadius ?? -1, 20, accuracy: 1e-9)
    XCTAssertEqual(shadow?.offsetY ?? 1, -10, accuracy: 1e-9)

    let windowShadow = ArcShotVideoCompositor.stageCardShadow(
      stage: ArcShotCompositionInstruction.StageConfig(
        useStage: true,
        padding: 48,
        cornerRadius: 24,
        contentInset: 0,
        shadowOpacity: 0.5,
        shadowRadius: 20,
        shadowYOffset: -10,
        backgroundSettings: .defaulted(forSourceKind: .window),
        sourceKind: .window
      ),
      geometry: geometry
    )
    XCTAssertNil(windowShadow)

    let opacityDisabledShadow = ArcShotVideoCompositor.stageCardShadow(
      stage: ArcShotCompositionInstruction.StageConfig(
        useStage: true,
        padding: 48,
        cornerRadius: 24,
        contentInset: 0,
        shadowOpacity: 0,
        shadowRadius: 20,
        shadowYOffset: 10,
        backgroundSettings: .defaulted(forSourceKind: .display),
        sourceKind: .display
      ),
      geometry: geometry
    )
    XCTAssertNil(opacityDisabledShadow)

    let radiusDisabledShadow = ArcShotVideoCompositor.stageCardShadow(
      stage: ArcShotCompositionInstruction.StageConfig(
        useStage: true,
        padding: 48,
        cornerRadius: 24,
        contentInset: 0,
        shadowOpacity: 0.5,
        shadowRadius: 0,
        shadowYOffset: 10,
        backgroundSettings: .defaulted(forSourceKind: .display),
        sourceKind: .display
      ),
      geometry: geometry
    )
    XCTAssertNil(radiusDisabledShadow)
  }

  func testExportCursorPointUsesSourceSizeBeforeAspectFit() {
    let sourceSize = CGSize(width: 3420, height: 2214)
    let renderSize = CGSize(width: 1920, height: 1080)
    let baseTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )

    let sourcePoint = ExportVideoGeometry.normalizedSourcePoint(
      x: 0.5,
      y: 0.5,
      sourceSize: sourceSize
    ).applying(baseTransform)

    XCTAssertEqual(sourcePoint.x, renderSize.width / 2, accuracy: 0.001)
    XCTAssertEqual(sourcePoint.y, renderSize.height / 2, accuracy: 0.001)
  }

  func testEditorPreviewCursorPointUsesSwiftUIYAxis() {
    let point = EditorPreviewLayout.cursorPoint(
      sample: RecordingProject.CursorSample(timeSeconds: 0, x: 0.2, y: 0.8),
      in: CGSize(width: 1000, height: 500)
    )

    XCTAssertEqual(point.x, 200, accuracy: 0.001)
    XCTAssertEqual(point.y, 100, accuracy: 0.001)
  }

  func testEditorPreviewCursorPointUsesAspectFitVideoRect() {
    let point = EditorPreviewLayout.cursorPoint(
      sample: RecordingProject.CursorSample(timeSeconds: 0, x: 0, y: 1),
      in: CGSize(width: 1000, height: 500),
      sourceSize: CGSize(width: 1000, height: 1000)
    )

    XCTAssertEqual(point.x, 250, accuracy: 0.001)
    XCTAssertEqual(point.y, 0, accuracy: 0.001)
  }

  func testEditorPreviewZoomAnchorUsesAspectFitVideoRect() {
    let point = EditorPreviewLayout.zoomAnchorPoint(
      anchorX: 0,
      anchorY: 0.5,
      in: CGSize(width: 1000, height: 500),
      sourceSize: CGSize(width: 1000, height: 1000)
    )

    XCTAssertEqual(point.x, 250, accuracy: 0.001)
    XCTAssertEqual(point.y, 250, accuracy: 0.001)
  }

  func testEditorPreviewZoomTransformMapsVisibleSourceRectToVideoRect() {
    let containerSize = CGSize(width: 1000, height: 500)
    let sourceSize = CGSize(width: 1000, height: 1000)
    let visibleRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    let topLeft = EditorPreviewLayout.applyingPreviewZoom(
      to: CGPoint(x: 375, y: 125),
      in: containerSize,
      sourceSize: sourceSize,
      visibleSourceRect: visibleRect
    )
    let bottomRight = EditorPreviewLayout.applyingPreviewZoom(
      to: CGPoint(x: 625, y: 375),
      in: containerSize,
      sourceSize: sourceSize,
      visibleSourceRect: visibleRect
    )

    XCTAssertEqual(topLeft.x, 250, accuracy: 0.001)
    XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)
    XCTAssertEqual(bottomRight.x, 750, accuracy: 0.001)
    XCTAssertEqual(bottomRight.y, 500, accuracy: 0.001)
  }

  func testEditorPreviewZoomTransformMapsVisibleSourceRectFrameToVideoRect() {
    let containerSize = CGSize(width: 1000, height: 500)
    let sourceSize = CGSize(width: 1000, height: 1000)
    let visibleRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let videoRect = EditorPreviewLayout.aspectFitRect(sourceSize: sourceSize, in: containerSize)
    let targetFrame = CGRect(
      x: videoRect.minX + visibleRect.minX * videoRect.width,
      y: videoRect.maxY - (visibleRect.maxY) * videoRect.height,
      width: visibleRect.width * videoRect.width,
      height: visibleRect.height * videoRect.height
    )

    let transformed = EditorPreviewLayout.applyingPreviewZoom(
      to: targetFrame,
      in: containerSize,
      sourceSize: sourceSize,
      visibleSourceRect: visibleRect
    )

    XCTAssertEqual(transformed.minX, videoRect.minX, accuracy: 0.001)
    XCTAssertEqual(transformed.minY, videoRect.minY, accuracy: 0.001)
    XCTAssertEqual(transformed.width, videoRect.width, accuracy: 0.001)
    XCTAssertEqual(transformed.height, videoRect.height, accuracy: 0.001)
  }

  func testExportZoomStateMapsTargetRegionToRenderBounds() {
    let frame = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 1,
      scale: 2,
      anchorX: 0.5,
      anchorY: 0.5,
      targetX: 0.25,
      targetY: 0.25,
      targetWidth: 0.5,
      targetHeight: 0.5
    )
    let state = ArcShotCompositionInstruction.ZoomState.targetRegion(frame)
    let transform = state.zoomTransform(
      renderSize: CGSize(width: 1000, height: 1000),
      sourceSize: CGSize(width: 1000, height: 1000),
      baseTransform: .identity
    )

    XCTAssertEqual(CGPoint(x: 250, y: 250).applying(transform).x, 0, accuracy: 0.001)
    XCTAssertEqual(CGPoint(x: 250, y: 250).applying(transform).y, 0, accuracy: 0.001)
    XCTAssertEqual(CGPoint(x: 750, y: 750).applying(transform).x, 1000, accuracy: 0.001)
    XCTAssertEqual(CGPoint(x: 750, y: 750).applying(transform).y, 1000, accuracy: 0.001)
  }

  func testExportZoomStateUsesAspectFitSourceRect() {
    let renderSize = CGSize(width: 1000, height: 500)
    let sourceSize = CGSize(width: 1000, height: 1000)
    let frame = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 1,
      scale: 2,
      anchorX: 0.5,
      anchorY: 0.5,
      targetX: 0.25,
      targetY: 0.25,
      targetWidth: 0.5,
      targetHeight: 0.5
    )
    let baseTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )
    let transform = ArcShotCompositionInstruction.ZoomState.targetRegion(frame).zoomTransform(
      renderSize: renderSize,
      sourceSize: sourceSize,
      baseTransform: baseTransform
    )

    XCTAssertEqual(CGPoint(x: 250, y: 250).applying(transform).x, 250, accuracy: 0.001)
    XCTAssertEqual(CGPoint(x: 250, y: 250).applying(transform).y, 0, accuracy: 0.001)
    XCTAssertEqual(CGPoint(x: 750, y: 750).applying(transform).x, 750, accuracy: 0.001)
    XCTAssertEqual(CGPoint(x: 750, y: 750).applying(transform).y, 500, accuracy: 0.001)
  }

  func testExportZoomStateKeepsTargetRegionAtScreenAspectRatio() {
    let frame = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 1,
      scale: 2,
      anchorX: 0.5,
      anchorY: 0.5,
      targetX: 0.2,
      targetY: 0.3,
      targetWidth: 0.4,
      targetHeight: 0.7
    )

    let state = ArcShotCompositionInstruction.ZoomState.targetRegion(frame)

    XCTAssertEqual(state.visibleWidth, state.visibleHeight, accuracy: 1e-9)
    XCTAssertEqual(state.visibleWidth, 0.4, accuracy: 1e-9)
  }

  func testEditorPreviewZoomTransformMatchesScaledVideoLayer() {
    let size = CGSize(width: 1000, height: 500)
    let zoom = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 1,
      scale: 2,
      anchorX: 0.5,
      anchorY: 0.8
    )
    let point = EditorPreviewLayout.cursorPoint(
      sample: RecordingProject.CursorSample(timeSeconds: 0, x: 0.75, y: 0.4),
      in: size
    )

    let transformed = EditorPreviewLayout.applyingPreviewZoom(
      to: point,
      in: size,
      keyframe: zoom
    )

    XCTAssertEqual(EditorPreviewLayout.zoomAnchorPoint(for: zoom, in: size).x, 500, accuracy: 0.001)
    XCTAssertEqual(EditorPreviewLayout.zoomAnchorPoint(for: zoom, in: size).y, 100, accuracy: 0.001)
    XCTAssertEqual(transformed.x, 1000, accuracy: 0.001)
    XCTAssertEqual(transformed.y, 500, accuracy: 0.001)
  }

  func testEditorPreviewCursorPointAppliesAutoMotionFrame() {
    let size = CGSize(width: 1000, height: 500)
    let point = EditorPreviewLayout.cursorPoint(
      sample: RecordingProject.CursorSample(timeSeconds: 0, x: 0.75, y: 0.4),
      in: size
    )
    let motion = RecordingProject.AutoZoomMotionFrame(
      timeSeconds: 0,
      anchorX: 0.5,
      anchorY: 0.8,
      scale: 2
    )

    let transformed = EditorPreviewLayout.applyingPreviewZoom(
      to: point,
      in: size,
      keyframe: nil,
      motionFrame: motion
    )

    XCTAssertEqual(transformed.x, 1000, accuracy: 0.001)
    XCTAssertEqual(transformed.y, 500, accuracy: 0.001)
  }

  func testZoomTargetRegionParityMatchesPreviewAndExportBoundaryTimingSamples() throws {
    let sourceSize = CGSize(width: 1440, height: 900)
    let renderSize = CGSize(width: 1280, height: 720)
    let frame = RecordingProject.ZoomKeyframe(
      startSeconds: 1,
      inEndSeconds: 2,
      outStartSeconds: 4,
      endSeconds: 5,
      scale: 2.4,
      anchorX: 0.4,
      anchorY: 0.46,
      targetX: 0.18,
      targetY: 0.24,
      targetWidth: 0.42,
      targetHeight: 0.42
    )
    let instruction = makeZoomInstruction(
      zoomFrame: frame,
      zoomState: .targetRegion(frame),
      sourceSize: sourceSize,
      renderSize: renderSize
    )
    let samples = [1.0, 2.0, 3.0, 4.0, 5.0]
    let sourcePoints = [
      CGPoint(x: frame.targetX, y: frame.targetY),
      CGPoint(x: frame.targetX + frame.targetWidth, y: frame.targetY + frame.targetHeight),
      CGPoint(x: 0.72, y: 0.28),
    ]

    for sampleSeconds in samples {
      let previewState = try XCTUnwrap(EditorPreviewZoomResolver.state(
        id: UUID(),
        startSeconds: frame.startSeconds,
        inEndSeconds: frame.inEndSeconds,
        outStartSeconds: frame.outStartSeconds,
        endSeconds: frame.endSeconds,
        targetX: frame.targetX,
        targetY: frame.targetY,
        targetWidth: frame.targetWidth,
        targetHeight: frame.targetHeight,
        at: sampleSeconds
      ))
      assertZoomTransformParity(
        previewState: previewState,
        instruction: instruction,
        compositionSeconds: sampleSeconds,
        sourcePoints: sourcePoints,
        sourceSize: sourceSize,
        renderSize: renderSize
      )
    }
  }

  func testPreviewZoomTransformSnapsOffsetToWholePixelsWhileZoomed() {
    let transform = EditorPreviewLayout.pixelSnappedPreviewZoomTransform(
      scale: 2.17,
      offset: CGSize(width: 38.42, height: -17.83),
      pixelScale: 2
    )
    XCTAssertEqual(transform.offset.width, 38.5, accuracy: 0.001)
    XCTAssertEqual(transform.offset.height, -18, accuracy: 0.001)
    XCTAssertEqual(transform.scale, 2.17, accuracy: 0.001)
  }

  func testPreviewZoomTransformUsesStableContainerSize() {
    let jittery = CGSize(width: 812.4, height: 456.9)
    let stable = EditorPreviewLayout.stablePreviewContainerSize(jittery)
    XCTAssertEqual(stable.width, 812, accuracy: 0.001)
    XCTAssertEqual(stable.height, 456, accuracy: 0.001)
  }

  func testAdjacentZoomSegmentsCrossfadeAvoidsIdentityDip() {
    let first = RecordingProject.ZoomSegment(
      startSeconds: 0,
      inEndSeconds: 0.35,
      outStartSeconds: 3.65,
      endSeconds: 4,
      scale: 2,
      anchorX: 0.35,
      anchorY: 0.4,
      targetX: 0.2,
      targetY: 0.25,
      targetWidth: 0.5,
      targetHeight: 0.5
    )
    let second = RecordingProject.ZoomSegment(
      startSeconds: 4,
      inEndSeconds: 4.35,
      outStartSeconds: 7.65,
      endSeconds: 8,
      scale: 2.5,
      anchorX: 0.55,
      anchorY: 0.45,
      targetX: 0.34,
      targetY: 0.18,
      targetWidth: 0.4,
      targetHeight: 0.4
    )
    let segments = [first, second]
    let legacyOutgoing = EditorPreviewZoomResolver.state(for: first, at: 4)
    let crossfade = EditorPreviewZoomResolver.resolvedState(segments: segments, at: 4)

    XCTAssertNotNil(legacyOutgoing)
    XCTAssertNotNil(crossfade)
    XCTAssertLessThan(abs((legacyOutgoing?.scale ?? 1) - 1), 0.05)
    XCTAssertGreaterThan((crossfade?.scale ?? 1), 1.2)
    XCTAssertLessThan((crossfade?.scale ?? 1), 2.45)
  }

  func testExportZoomInstructionRampsFromPreviousStateAtSegmentBoundary() {
    let sourceSize = CGSize(width: 1440, height: 900)
    let renderSize = CGSize(width: 1280, height: 720)
    let previousFrame = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 2,
      scale: 2,
      anchorX: 0.4,
      anchorY: 0.42,
      targetX: 0.2,
      targetY: 0.22,
      targetWidth: 0.5,
      targetHeight: 0.5
    )
    let targetFrame = RecordingProject.ZoomKeyframe(
      startSeconds: 2,
      endSeconds: 4,
      scale: 2.5,
      anchorX: 0.5,
      anchorY: 0.5,
      targetX: 0.34,
      targetY: 0.18,
      targetWidth: 0.4,
      targetHeight: 0.4
    )
    let previousState = ArcShotCompositionInstruction.ZoomState.targetRegion(previousFrame)
    let targetState = ArcShotCompositionInstruction.ZoomState.targetRegion(targetFrame)
    let instruction = makeZoomInstruction(
      timeRangeStart: 2,
      zoomState: targetState,
      previousZoomState: previousState,
      rampDurationSeconds: 0.12,
      sourceSize: sourceSize,
      renderSize: renderSize
    )
    let baseTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )
    let from = previousState.zoomTransform(renderSize: renderSize, sourceSize: sourceSize, baseTransform: baseTransform)
    let target = targetState.zoomTransform(renderSize: renderSize, sourceSize: sourceSize, baseTransform: baseTransform)

    assertTransformsEqual(instruction.interpolatedZoomTransform(at: CMTime(seconds: 2.0, preferredTimescale: 600)), from)
    assertTransformsEqual(
      instruction.interpolatedZoomTransform(at: CMTime(seconds: 2.06, preferredTimescale: 600)),
      interpolatedTransform(from: from, to: target, progress: 0.5)
    )
    assertTransformsEqual(instruction.interpolatedZoomTransform(at: CMTime(seconds: 2.12, preferredTimescale: 600)), target)
  }

  func testCursorCoordinateParityMatchesPreviewAndExportForStagedAndNonStagedOutput() {
    let sourceSize = CGSize(width: 1000, height: 1000)
    let renderSize = CGSize(width: 1000, height: 500)
    let sample = RecordingProject.CursorSample(timeSeconds: 0.4, x: 0.68, y: 0.72)
    let visibleSourceRect = CGRect(x: 0.42, y: 0.48, width: 0.36, height: 0.36)

    assertCursorCoordinateParity(
      sample: sample,
      sourceSize: sourceSize,
      renderSize: renderSize,
      stageGeometry: nil,
      visibleSourceRect: nil
    )
    assertCursorCoordinateParity(
      sample: sample,
      sourceSize: sourceSize,
      renderSize: renderSize,
      stageGeometry: nil,
      visibleSourceRect: visibleSourceRect
    )

    let stageGeometry = ArcShotRenderGeometry.make(
      stageSize: renderSize,
      contentAspectRatio: renderSize.width / renderSize.height,
      padding: 64,
      contentInset: 0,
      cornerRadius: 28,
      sourceKind: .display,
      sourceVideoSize: sourceSize
    )
    assertCursorCoordinateParity(
      sample: sample,
      sourceSize: sourceSize,
      renderSize: renderSize,
      stageGeometry: stageGeometry,
      visibleSourceRect: nil
    )
    assertCursorCoordinateParity(
      sample: sample,
      sourceSize: sourceSize,
      renderSize: renderSize,
      stageGeometry: stageGeometry,
      visibleSourceRect: visibleSourceRect
    )
  }

  private func assertCursorCoordinateParity(
    sample: RecordingProject.CursorSample,
    sourceSize: CGSize,
    renderSize: CGSize,
    stageGeometry: ArcShotRenderGeometry?,
    visibleSourceRect: CGRect?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let previewContainerSize = stageGeometry?.contentRect.size ?? renderSize
    var previewPoint = EditorPreviewLayout.cursorPoint(
      sample: sample,
      in: previewContainerSize,
      sourceSize: sourceSize
    )
    if let visibleSourceRect {
      previewPoint = EditorPreviewLayout.applyingPreviewZoom(
        to: previewPoint,
        in: previewContainerSize,
        sourceSize: sourceSize,
        visibleSourceRect: visibleSourceRect
      )
    }
    if let stageGeometry {
      previewPoint.x += stageGeometry.contentRect.minX
      previewPoint.y += stageGeometry.contentRect.minY
    }

    let baseTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )
    let zoomTransform: CGAffineTransform = {
      guard let visibleSourceRect else { return baseTransform }
      return ArcShotCompositionInstruction.ZoomState.targetRegion(
        RecordingProject.ZoomKeyframe(
          startSeconds: 0,
          endSeconds: 1,
          scale: 1 / Double(visibleSourceRect.width),
          anchorX: visibleSourceRect.midX,
          anchorY: visibleSourceRect.midY,
          targetX: visibleSourceRect.minX,
          targetY: visibleSourceRect.minY,
          targetWidth: visibleSourceRect.width,
          targetHeight: visibleSourceRect.height
        )
      ).zoomTransform(
        renderSize: renderSize,
        sourceSize: sourceSize,
        baseTransform: baseTransform
      )
    }()
    let sourceTransform = stageGeometry.map {
      zoomTransform.concatenating($0.contentTransform(from: renderSize))
    } ?? zoomTransform
    let exportBottomUpPoint = ExportVideoGeometry.normalizedSourcePoint(
      x: sample.x,
      y: sample.y,
      sourceSize: sourceSize
    ).applying(sourceTransform)
    let exportTopDownPoint = CGPoint(
      x: exportBottomUpPoint.x,
      y: renderSize.height - exportBottomUpPoint.y
    )

    XCTAssertEqual(previewPoint.x, exportTopDownPoint.x, accuracy: 0.25, file: file, line: line)
    XCTAssertEqual(previewPoint.y, exportTopDownPoint.y, accuracy: 0.25, file: file, line: line)
  }

  private func assertZoomTransformParity(
    previewState: EditorPreviewZoomState,
    instruction: ArcShotCompositionInstruction,
    compositionSeconds: Double,
    sourcePoints: [CGPoint],
    sourceSize: CGSize,
    renderSize: CGSize,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let visibleSourceRect = CGRect(
      x: previewState.visibleX,
      y: previewState.visibleY,
      width: previewState.visibleWidth,
      height: previewState.visibleHeight
    )
    let exportTransform = instruction.interpolatedZoomTransform(
      at: CMTime(seconds: compositionSeconds, preferredTimescale: 600)
    )

    for sourcePoint in sourcePoints {
      let previewPoint = EditorPreviewLayout.applyingPreviewZoom(
        to: previewPoint(forNormalizedSourcePoint: sourcePoint, sourceSize: sourceSize, renderSize: renderSize),
        in: renderSize,
        sourceSize: sourceSize,
        visibleSourceRect: visibleSourceRect
      )
      let exportBottomUpPoint = ExportVideoGeometry.normalizedSourcePoint(
        x: sourcePoint.x,
        y: sourcePoint.y,
        sourceSize: sourceSize
      ).applying(exportTransform)
      let exportTopDownPoint = CGPoint(
        x: exportBottomUpPoint.x,
        y: renderSize.height - exportBottomUpPoint.y
      )

      XCTAssertEqual(previewPoint.x, exportTopDownPoint.x, accuracy: 0.25, file: file, line: line)
      XCTAssertEqual(previewPoint.y, exportTopDownPoint.y, accuracy: 0.25, file: file, line: line)
    }
  }

  private func previewPoint(
    forNormalizedSourcePoint sourcePoint: CGPoint,
    sourceSize: CGSize,
    renderSize: CGSize
  ) -> CGPoint {
    let videoRect = EditorPreviewLayout.aspectFitRect(sourceSize: sourceSize, in: renderSize)
    return CGPoint(
      x: videoRect.minX + sourcePoint.x * videoRect.width,
      y: videoRect.maxY - sourcePoint.y * videoRect.height
    )
  }

  private func makeZoomInstruction(
    timeRangeStart: Double = 0,
    zoomFrame: RecordingProject.ZoomKeyframe? = nil,
    zoomState: ArcShotCompositionInstruction.ZoomState,
    previousZoomState: ArcShotCompositionInstruction.ZoomState? = nil,
    rampDurationSeconds: Double = 0,
    sourceSize: CGSize,
    renderSize: CGSize
  ) -> ArcShotCompositionInstruction {
    let baseTransform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderSize: renderSize
    )
    return ArcShotCompositionInstruction(
      timeRange: CMTimeRange(
        start: CMTime(seconds: timeRangeStart, preferredTimescale: 600),
        duration: CMTime(seconds: 10, preferredTimescale: 600)
      ),
      mainTrackID: 1,
      pipTrackID: nil,
      pipTransform: nil,
      pipClip: nil,
      mainBaseTransform: baseTransform,
      mainSourceSize: sourceSize,
      renderSize: renderSize,
      zoomState: zoomState,
      zoomFrame: zoomFrame,
      previousZoomState: previousZoomState,
      rampDuration: CMTime(seconds: rampDurationSeconds, preferredTimescale: 600),
      cursor: ArcShotCompositionInstruction.CursorState(
        samples: [],
        clickCues: [],
        highlightRegions: [],
        settings: RecordingProject.CursorVisualSettings()
      ),
      stage: ArcShotCompositionInstruction.StageConfig(
        useStage: false,
        padding: 0,
        cornerRadius: 0,
        contentInset: 0,
        shadowOpacity: 0,
        shadowRadius: 0,
        shadowYOffset: 0,
        backgroundSettings: RecordingProject.ExportVisualSettings(
          stageStyle: .none,
          backgroundKind: .solid,
          backgroundColorHex: "#000000",
          gradientEndColorHex: "#000000",
          contentCornerRadius: 0,
          contentInset: 0,
          dropShadowOpacity: 0,
          shadowRadius: 0,
          shadowYOffset: 0,
          enabledForDisplayCapture: false
        ),
        sourceKind: .display
      ),
      fade: ArcShotCompositionInstruction.FadeConfig(
        introFadeSeconds: 0,
        outroFadeSeconds: 0,
        totalDurationSeconds: 10
      ),
      textOverlays: [],
      visualMasks: [],
      motionPlan: nil,
      timedDataOffsetSeconds: 0
    )
  }

  private func interpolatedTransform(
    from: CGAffineTransform,
    to: CGAffineTransform,
    progress: Double
  ) -> CGAffineTransform {
    let smoothT = progress * progress * (3 - 2 * progress)
    return CGAffineTransform(
      a: from.a + (to.a - from.a) * smoothT,
      b: from.b + (to.b - from.b) * smoothT,
      c: from.c + (to.c - from.c) * smoothT,
      d: from.d + (to.d - from.d) * smoothT,
      tx: from.tx + (to.tx - from.tx) * smoothT,
      ty: from.ty + (to.ty - from.ty) * smoothT
    )
  }

  private func assertTransformsEqual(
    _ actual: CGAffineTransform,
    _ expected: CGAffineTransform,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual.a, expected.a, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.b, expected.b, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.c, expected.c, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.d, expected.d, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.tx, expected.tx, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.ty, expected.ty, accuracy: 0.001, file: file, line: line)
  }

  func testExporterMainVideoTransformFitsTallWindowWithoutCropping() {
    let renderSize = CGSize(width: 1920, height: 1080)
    let transform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: CGSize(width: 854, height: 1072),
      preferredTransform: .identity,
      renderSize: renderSize
    )

    let drawn = CGRect(origin: .zero, size: CGSize(width: 854, height: 1072)).applying(transform)

    XCTAssertLessThanOrEqual(drawn.width, renderSize.width + 0.001)
    XCTAssertLessThanOrEqual(drawn.height, renderSize.height + 0.001)
    XCTAssertEqual(drawn.height, renderSize.height, accuracy: 0.001)
    XCTAssertGreaterThan(drawn.minX, 0)
    XCTAssertEqual(drawn.minY, 0, accuracy: 0.001)
  }

  func testExporterMainVideoTransformFitsWideWindowWithoutCropping() {
    let renderSize = CGSize(width: 1920, height: 1080)
    let transform = ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: CGSize(width: 2560, height: 720),
      preferredTransform: .identity,
      renderSize: renderSize
    )

    let drawn = CGRect(origin: .zero, size: CGSize(width: 2560, height: 720)).applying(transform)

    XCTAssertLessThanOrEqual(drawn.width, renderSize.width + 0.001)
    XCTAssertLessThanOrEqual(drawn.height, renderSize.height + 0.001)
    XCTAssertEqual(drawn.width, renderSize.width, accuracy: 0.001)
    XCTAssertEqual(drawn.minX, 0, accuracy: 0.001)
    XCTAssertGreaterThan(drawn.minY, 0)
  }

  func testEffectiveZoomKeyframes_softZoomAddsSyntheticBase() throws {
    let user = RecordingProject.ZoomKeyframe(
      startSeconds: 1,
      endSeconds: 2,
      scale: 1.5,
      anchorX: 0.2,
      anchorY: 0.3
    )
    let merged = RecordingProject.effectiveZoomKeyframes(
      stylePreset: .softZoom,
      userKeyframes: [user],
      exportStartSeconds: 0,
      exportEndSeconds: 10,
      softZoomScale: 1.1
    )
    XCTAssertEqual(merged.count, 2)
    let base = try XCTUnwrap(merged.first { $0.id == ExportStyleConstants.softZoomSyntheticID })
    XCTAssertEqual(base.startSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(base.endSeconds, 10, accuracy: 1e-9)
    XCTAssertEqual(base.scale, 1.1, accuracy: 1e-9)
  }

  func testEffectiveZoomKeyframes_nonSoftZoomReturnsUserOnly() {
    let user = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 5,
      scale: 1.2,
      anchorX: 0.5,
      anchorY: 0.5
    )
    for preset in [
      RecordingProject.StylePresetID.none,
      RecordingProject.StylePresetID.cursorFocus,
    ] {
      let merged = RecordingProject.effectiveZoomKeyframes(
        stylePreset: preset,
        userKeyframes: [user],
        exportStartSeconds: 0,
        exportEndSeconds: 10,
        softZoomScale: 1.1
      )
      XCTAssertEqual(merged, [user], "unexpected merge for \(preset)")
    }
  }

  func testTimelineKeyframeSanitizePreservesOverlappingZoomRanges() {
    let a = RecordingProject.ZoomKeyframe(
      startSeconds: 0,
      endSeconds: 5,
      scale: 1.2,
      anchorX: 0.1,
      anchorY: 0.2
    )
    let b = RecordingProject.ZoomKeyframe(
      startSeconds: 3,
      endSeconds: 8,
      scale: 1.7,
      anchorX: 0.88,
      anchorY: 0.45
    )
    let sanitized = RecordingProject.TimelineKeyframeSanitize.zoomFrames([b, a], durationSeconds: 10)
    XCTAssertEqual(sanitized.count, 2)
    XCTAssertEqual(sanitized[0].startSeconds, a.startSeconds, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].startSeconds, b.startSeconds, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].targetX + sanitized[1].targetWidth / 2, sanitized[1].anchorX, accuracy: 1e-9)
  }

  func testZoomSegmentSanitizeSupportsAutoManualInstantAndClamps() {
    let segments = [
      RecordingProject.ZoomSegment(startSeconds: 3, endSeconds: 1, mode: .instant, instantAnimation: false, scale: 99, anchorX: -1, anchorY: 2),
      RecordingProject.ZoomSegment(startSeconds: 0, endSeconds: 2, mode: .auto, instantAnimation: false, scale: 0.2, anchorX: 0.4, anchorY: 0.5, followsClick: true),
    ]

    let sanitized = RecordingProject.sanitizedZoomSegments(segments, durationSeconds: 4)

    XCTAssertEqual(sanitized.count, 2)
    XCTAssertEqual(sanitized[0].mode, .auto)
    XCTAssertTrue(sanitized[0].followsClick)
    XCTAssertEqual(sanitized[0].scale, 1, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].mode, .instant)
    XCTAssertTrue(sanitized[1].instantAnimation)
    XCTAssertEqual(sanitized[1].startSeconds, 1, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].endSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].scale, 3, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].anchorX, 1.0 / 6.0, accuracy: 1e-9)
    XCTAssertEqual(sanitized[1].anchorY, 5.0 / 6.0, accuracy: 1e-9)
  }

  func testSanitizedZoomSegmentsAllowsOverlapsButEditorSanitizerResolvesThem() {
    let firstID = UUID()
    let secondID = UUID()
    let overlapping = [
      RecordingProject.ZoomSegment(
        id: firstID,
        startSeconds: 1,
        endSeconds: 3,
        scale: 1.5,
        anchorX: 0.5,
        anchorY: 0.5
      ),
      RecordingProject.ZoomSegment(
        id: secondID,
        startSeconds: 2,
        endSeconds: 4,
        scale: 1.8,
        anchorX: 0.5,
        anchorY: 0.5
      ),
    ]

    let sanitized = RecordingProject.sanitizedZoomSegments(overlapping, durationSeconds: 6)
    XCTAssertTrue(RecordingProjectEditorZoomSanitizer.hasOverlappingSegments(sanitized))

    let resolved = RecordingProjectEditorZoomSanitizer.sanitizedSegments(overlapping, durationSeconds: 6)
    XCTAssertFalse(RecordingProjectEditorZoomSanitizer.hasOverlappingSegments(resolved))
  }

  func testNormalizedCursorPositionConvertsAppKitMouseYForWindowCaptureRect() {
    let primaryHeight: CGFloat = 1000
    let contentRect = CGRect(x: 0, y: 200, width: 800, height: 400)
    let globalMouse = CGPoint(x: 400, y: 600)

    let normalized = RecordingCoordinator.normalizedCursorPositionInContentRect(
      globalMouseLocation: globalMouse,
      contentRect: contentRect,
      primaryScreenHeight: primaryHeight
    )

    XCTAssertNotNil(normalized)
    XCTAssertEqual(normalized?.x ?? -1, 0.5, accuracy: 1e-9)
    XCTAssertEqual(normalized?.y ?? -1, 0.5, accuracy: 1e-9)
  }

  func testNormalizedCursorPositionUsesCGGlobalCoordinatesDirectly() {
    let contentRect = CGRect(x: 121, y: 80, width: 1496, height: 1072)
    let cgGlobal = CGPoint(x: 565.9, y: 650.9)

    let normalized = RecordingCoordinator.normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: cgGlobal,
      contentRect: contentRect
    )

    XCTAssertNotNil(normalized)
    XCTAssertEqual(normalized?.x ?? -1, 0.2974, accuracy: 0.001)
    XCTAssertEqual(normalized?.y ?? -1, 0.4675, accuracy: 0.001)
  }

  func testNormalizedCursorPositionUsesScreenRectWhenOffsetFromFilter() {
    let filterRect = CGRect(x: 92, y: 80, width: 1496, height: 1072)
    let screenRect = CGRect(x: 92, y: 47, width: 1496, height: 1072)
    let cgGlobal = CGPoint(x: 713.7, y: 666.5)

    let filterNorm = RecordingCoordinator.normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: cgGlobal,
      contentRect: filterRect
    )
    let screenNorm = RecordingCoordinator.normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: cgGlobal,
      contentRect: screenRect
    )
    let mappedRect = RecordingCoordinator.cursorMappingRect(
      filterContentRect: filterRect,
      streamScreenRect: screenRect
    )
    let mappedNorm = RecordingCoordinator.normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: cgGlobal,
      contentRect: mappedRect
    )

    XCTAssertEqual(filterNorm?.y ?? -1, 0.4529, accuracy: 0.001)
    XCTAssertEqual(screenNorm?.y ?? -1, 0.4221, accuracy: 0.001)
    XCTAssertEqual(mappedNorm?.y ?? -1, screenNorm?.y ?? -2, accuracy: 1e-9)
    XCTAssertEqual((filterNorm?.y ?? 0) - (screenNorm?.y ?? 0), 0.0308, accuracy: 0.001)
  }

  func testNormalizedCursorPositionLegacyFormulaWouldMismatchWindowCaptureRect() {
    let primaryHeight: CGFloat = 1000
    let contentRect = CGRect(x: 0, y: 200, width: 800, height: 400)
    let globalMouse = CGPoint(x: 400, y: 600)
    let legacyY = (globalMouse.y - contentRect.minY) / contentRect.height

    let normalized = RecordingCoordinator.normalizedCursorPositionInContentRect(
      globalMouseLocation: globalMouse,
      contentRect: contentRect,
      primaryScreenHeight: primaryHeight
    )

    XCTAssertNotEqual(normalized?.y ?? legacyY, legacyY, accuracy: 1e-9)
  }

  func testLegacyZoomSegmentDecodesMotionTimingAndTargetRegionDefaults() throws {
    let data = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "startSeconds": 1.0,
      "endSeconds": 3.0,
      "mode": "instant",
      "instantAnimation": false,
      "scale": 2.0,
      "anchorX": 0.75,
      "anchorY": 0.25,
      "followsClick": true
    }
    """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(RecordingProject.ZoomSegment.self, from: data)

    XCTAssertEqual(segment.inEndSeconds, segment.startSeconds, accuracy: 1e-9)
    XCTAssertEqual(segment.outStartSeconds, 2.56, accuracy: 1e-9)
    XCTAssertTrue(segment.instantAnimation)
    XCTAssertEqual(segment.targetWidth, 0.5, accuracy: 1e-9)
    XCTAssertEqual(segment.targetHeight, 0.5, accuracy: 1e-9)
    XCTAssertEqual(segment.targetX, 0.5, accuracy: 1e-9)
    XCTAssertEqual(segment.targetY, 0, accuracy: 1e-9)
  }

  func testZoomSegmentSanitizeClampsFourPointTimingAndTargetRegion() {
    let segment = RecordingProject.ZoomSegment(
      startSeconds: 3,
      inEndSeconds: 0.5,
      outStartSeconds: 5,
      endSeconds: 1,
      scale: 1.4,
      anchorX: 0.5,
      anchorY: 0.5,
      targetX: -0.4,
      targetY: 0.9,
      targetWidth: 0.03,
      targetHeight: 1.4
    )

    let sanitized = RecordingProject.sanitizedZoomSegments([segment], durationSeconds: 4)[0]

    XCTAssertEqual(sanitized.startSeconds, 1, accuracy: 1e-9)
    XCTAssertEqual(sanitized.endSeconds, 3, accuracy: 1e-9)
    XCTAssertGreaterThanOrEqual(sanitized.inEndSeconds, sanitized.startSeconds)
    XCTAssertGreaterThanOrEqual(sanitized.outStartSeconds, sanitized.inEndSeconds)
    XCTAssertLessThanOrEqual(sanitized.outStartSeconds, sanitized.endSeconds)
    XCTAssertEqual(sanitized.targetX, 0, accuracy: 1e-9)
    XCTAssertEqual(sanitized.targetY, 1 - sanitized.targetHeight, accuracy: 1e-9)
    XCTAssertEqual(sanitized.targetWidth, 1 / RecordingProject.ZoomSegment.maxZoomLevel, accuracy: 1e-9)
    XCTAssertEqual(sanitized.targetHeight, sanitized.targetWidth, accuracy: 1e-9)
  }

  func testTimelineEditableRangeSlidesFourPointZoomTimingTogether() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 1,
      inEndSeconds: 1.4,
      outStartSeconds: 2.6,
      endSeconds: 3,
      minDuration: 0.1,
      canTrim: true,
      canMove: true
    )

    let moved = range.moving(by: 0.5, durationSeconds: 5)

    XCTAssertEqual(moved.startSeconds, 1.5, accuracy: 1e-9)
    XCTAssertEqual(moved.inEndSeconds ?? -1, 1.9, accuracy: 1e-9)
    XCTAssertEqual(moved.outStartSeconds ?? -1, 3.1, accuracy: 1e-9)
    XCTAssertEqual(moved.endSeconds, 3.5, accuracy: 1e-9)
  }

  func testTimelineEditableRangeMovesInteriorZoomHandlesWithinBounds() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 1,
      inEndSeconds: 1.4,
      outStartSeconds: 2.6,
      endSeconds: 3,
      minDuration: 0.1,
      canTrim: true,
      canMove: true
    )

    let inMoved = range.movingInEnd(to: 2.8, durationSeconds: 5)
    let outMoved = range.movingOutStart(to: 1.2, durationSeconds: 5)

    XCTAssertEqual(inMoved.inEndSeconds ?? -1, 2.6, accuracy: 1e-9)
    XCTAssertEqual(outMoved.outStartSeconds ?? -1, 1.4, accuracy: 1e-9)
  }

  func testTimelineEditableRangeZoomTrimKeepsInteriorTimingOrdered() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 1,
      inEndSeconds: 1.4,
      outStartSeconds: 2.6,
      endSeconds: 3,
      minDuration: 0.1,
      canTrim: true,
      canMove: true
    )

    let leadingTrimmed = range.trimmingLeading(to: 2.7, durationSeconds: 5)
    let trailingTrimmed = range.trimmingTrailing(to: 1.2, durationSeconds: 5)

    XCTAssertEqual(leadingTrimmed.startSeconds, 2.7, accuracy: 1e-9)
    XCTAssertEqual(leadingTrimmed.inEndSeconds ?? -1, 3, accuracy: 1e-9)
    XCTAssertEqual(leadingTrimmed.outStartSeconds ?? -1, 3, accuracy: 1e-9)
    XCTAssertEqual(leadingTrimmed.endSeconds, 3, accuracy: 1e-9)

    XCTAssertEqual(trailingTrimmed.startSeconds, 1, accuracy: 1e-9)
    XCTAssertEqual(trailingTrimmed.inEndSeconds ?? -1, 1.2, accuracy: 1e-9)
    XCTAssertEqual(trailingTrimmed.outStartSeconds ?? -1, 1.2, accuracy: 1e-9)
    XCTAssertEqual(trailingTrimmed.endSeconds, 1.2, accuracy: 1e-9)
  }

  func testTimelineEditableRangeAppliesTimelineDragMoveFromPixels() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 2,
      inEndSeconds: 2.4,
      outStartSeconds: 3.6,
      endSeconds: 4,
      minDuration: 0.1,
      canTrim: true,
      canMove: true
    )

    let moved = range.applyingTimelineDrag(
      mode: .move,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    XCTAssertEqual(moved.startSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(moved.inEndSeconds ?? -1, 3.4, accuracy: 1e-9)
    XCTAssertEqual(moved.outStartSeconds ?? -1, 4.6, accuracy: 1e-9)
    XCTAssertEqual(moved.endSeconds, 5, accuracy: 1e-9)
  }

  func testTimelineEditableRangeAppliesTimelineDragTrimFromPixels() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 2,
      inEndSeconds: 2.4,
      outStartSeconds: 3.6,
      endSeconds: 4,
      minDuration: 0.1,
      canTrim: true,
      canMove: true
    )

    let leading = range.applyingTimelineDrag(
      mode: .leading,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let trailing = range.applyingTimelineDrag(
      mode: .trailing,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    XCTAssertEqual(leading.startSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(leading.endSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(leading.inEndSeconds ?? -1, 3.4, accuracy: 1e-9)
    XCTAssertEqual(leading.outStartSeconds ?? -1, 4, accuracy: 1e-9)
    XCTAssertEqual(trailing.startSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(trailing.endSeconds, 5, accuracy: 1e-9)
    XCTAssertEqual(trailing.inEndSeconds ?? -1, 2.4, accuracy: 1e-9)
    XCTAssertEqual(trailing.outStartSeconds ?? -1, 4.6, accuracy: 1e-9)
  }

  func testTimelineEditableRangeAppliesTimelineDragWithTinyWidth() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .caption,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let moved = range.applyingTimelineDrag(
      mode: .move,
      translationX: 100,
      timelineDurationSeconds: 0,
      activeWidth: 0,
      durationSeconds: 10
    )

    XCTAssertEqual(moved.startSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(moved.endSeconds, 4, accuracy: 1e-9)
  }

  func testTimelineEditableRangeTimelineDragRespectsCapabilities() {
    let fixed = TimelineEditableRange(
      id: UUID(),
      kind: .caption,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.05,
      canTrim: false,
      canMove: false
    )

    XCTAssertEqual(
      fixed.applyingTimelineDrag(
        mode: .move,
        translationX: 100,
        timelineDurationSeconds: 10,
        activeWidth: 1_000,
        durationSeconds: 10
      ),
      fixed
    )
    XCTAssertEqual(
      fixed.applyingTimelineDrag(
        mode: .leading,
        translationX: 100,
        timelineDurationSeconds: 10,
        activeWidth: 1_000,
        durationSeconds: 10
      ),
      fixed
    )
  }

  func testTimelineEffectRangeEditSessionKeepsOriginalAcrossLiveRerenders() {
    let id = UUID()
    let original = TimelineEditableRange(
      id: id,
      kind: .zoom,
      startSeconds: 1,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let first = TimelineEffectRangeEditSession.update(
      current: nil,
      range: original,
      startX: 60,
      visualWidth: 200,
      edgeHitWidth: 20,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let rerenderedRange = first.session.live
    let second = TimelineEffectRangeEditSession.update(
      current: first.session,
      range: rerenderedRange,
      startX: 60,
      visualWidth: 200,
      edgeHitWidth: 20,
      translationX: 200,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    XCTAssertTrue(first.didBegin)
    XCTAssertFalse(second.didBegin)
    XCTAssertEqual(second.session.original, original)
    XCTAssertEqual(second.session.live.startSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(second.session.live.endSeconds, 5, accuracy: 1e-9)
    XCTAssertTrue(second.session.hasLiveChanges)
  }

  func testTimelineEffectRangeEditSessionStartsNewSessionForDifferentKind() {
    let sharedID = UUID()
    let zoom = TimelineEditableRange(
      id: sharedID,
      kind: .zoom,
      startSeconds: 1,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let caption = TimelineEditableRange(
      id: sharedID,
      kind: .caption,
      startSeconds: 4,
      endSeconds: 5,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let first = TimelineEffectRangeEditSession.update(
      current: nil,
      range: zoom,
      startX: 60,
      visualWidth: 200,
      edgeHitWidth: 20,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let second = TimelineEffectRangeEditSession.update(
      current: first.session,
      range: caption,
      startX: 60,
      visualWidth: 200,
      edgeHitWidth: 20,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    XCTAssertTrue(second.didBegin)
    XCTAssertEqual(second.session.kind, .caption)
    XCTAssertEqual(second.session.original, caption)
    XCTAssertEqual(second.session.live.startSeconds, 5, accuracy: 1e-9)
    XCTAssertEqual(second.session.live.endSeconds, 6, accuracy: 1e-9)
  }

  func testTimelineEffectRangeEditSessionAppliesFinalDragBeforeChangeCheck() {
    let id = UUID()
    let range = TimelineEditableRange(
      id: id,
      kind: .zoom,
      startSeconds: 1,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let first = TimelineEffectRangeEditSession.update(
      current: nil,
      range: range,
      startX: 60,
      visualWidth: 200,
      edgeHitWidth: 20,
      translationX: 4,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    let final = first.session.applyingFinalDrag(
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    XCTAssertEqual(final.original, range)
    XCTAssertEqual(final.live.startSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(final.live.endSeconds, 4, accuracy: 1e-9)
    XCTAssertTrue(final.hasLiveChanges)
  }

  func testTimelineEffectRangeEditSessionMatchesSelectionByIDAndKind() {
    let id = UUID()
    let otherID = UUID()
    let range = TimelineEditableRange(
      id: id,
      kind: .zoom,
      startSeconds: 1,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let update = TimelineEffectRangeEditSession.update(
      current: nil,
      range: range,
      startX: 60,
      visualWidth: 200,
      edgeHitWidth: 20,
      translationX: 100,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )

    XCTAssertTrue(update.session.matches(selection: .zoom(id)))
    XCTAssertFalse(update.session.matches(selection: .caption(id)))
    XCTAssertFalse(update.session.matches(selection: .zoom(otherID)))
    XCTAssertFalse(update.session.matches(selection: nil))
  }

  func testEffectRangeEditModeUsesEdgesForTrimAndMiddleForMove() {
    let edgeWidth = EditorLayout.timelineZoomMotionBoundaryHitWidth

    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 0, visualWidth: 120, edgeHitWidth: edgeWidth),
      .leading
    )
    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: edgeWidth, visualWidth: 120, edgeHitWidth: edgeWidth),
      .leading
    )
    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 60, visualWidth: 120, edgeHitWidth: edgeWidth),
      .move
    )
    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 120 - edgeWidth, visualWidth: 120, edgeHitWidth: edgeWidth),
      .trailing
    )
    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 120, visualWidth: 120, edgeHitWidth: edgeWidth),
      .trailing
    )
  }

  func testEffectRangeEditModePrefersEdgesForVeryShortSegments() {
    let edgeWidth = EditorLayout.timelineZoomMotionBoundaryHitWidth

    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 0, visualWidth: 32, edgeHitWidth: edgeWidth),
      .leading
    )
    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 16, visualWidth: 32, edgeHitWidth: edgeWidth),
      .leading
    )
    XCTAssertEqual(
      EffectRangeEditMode.modeForInteraction(startX: 32, visualWidth: 32, edgeHitWidth: edgeWidth),
      .trailing
    )
  }

  func testTimelineEditableRangeAppliesScreenStudioZoomTiming() {
    let timing = TimelineEditableRange.screenStudioTiming(startSeconds: 1, endSeconds: 2.2)

    XCTAssertEqual(timing.inEndSeconds, 1.3, accuracy: 1e-9)
    XCTAssertEqual(timing.outStartSeconds, 1.9, accuracy: 1e-9)

    let longTiming = TimelineEditableRange.screenStudioTiming(startSeconds: 2, endSeconds: 6)
    XCTAssertEqual(longTiming.inEndSeconds, 2.35, accuracy: 1e-9)
    XCTAssertEqual(longTiming.outStartSeconds, 5.65, accuracy: 1e-9)
  }

  func testTimelineEditableRangeScreenStudioTimingKeepsShortZoomOrdered() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 0.2,
      inEndSeconds: 0.21,
      outStartSeconds: 0.29,
      endSeconds: 0.3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let timed = range.applyingScreenStudioZoomTiming()

    XCTAssertEqual(timed.inEndSeconds ?? -1, 0.225, accuracy: 1e-9)
    XCTAssertEqual(timed.outStartSeconds ?? -1, 0.275, accuracy: 1e-9)
    XCTAssertLessThanOrEqual(timed.startSeconds, timed.inEndSeconds ?? -1)
    XCTAssertLessThanOrEqual(timed.inEndSeconds ?? -1, timed.outStartSeconds ?? -1)
    XCTAssertLessThanOrEqual(timed.outStartSeconds ?? -1, timed.endSeconds)
  }

  func testZoomLevelUpdateKeepsTargetCenterAndClampsRegion() {
    var segment = RecordingProject.ZoomSegment(
      startSeconds: 0,
      endSeconds: 1,
      scale: 1.25,
      anchorX: 0.8,
      anchorY: 0.7,
      targetX: 0.55,
      targetY: 0.45,
      targetWidth: 0.3,
      targetHeight: 0.3
    )
    segment.setTargetZoomLevel(2)

    let center = segment.targetCenter
    XCTAssertEqual(segment.targetZoomLevel, 2, accuracy: 1e-9)
    XCTAssertEqual(center.x, 0.7, accuracy: 1e-9)
    XCTAssertEqual(center.y, 0.6, accuracy: 1e-9)

    segment.setTargetCenter(x: 1.2, y: -0.2)
    let region = segment.sanitizedTargetRegion()
    XCTAssertEqual(region.width, 0.5, accuracy: 1e-9)
    XCTAssertEqual(region.height, 0.5, accuracy: 1e-9)
    XCTAssertGreaterThanOrEqual(region.x, 0)
    XCTAssertGreaterThanOrEqual(region.y, 0)
    XCTAssertLessThanOrEqual(region.x + region.width, 1)
    XCTAssertLessThanOrEqual(region.y + region.height, 1)
  }

  func testZoomSegmentSanitizedTargetRegionKeepsScreenAspectRatio() {
    let segment = RecordingProject.ZoomSegment(
      startSeconds: 0,
      endSeconds: 1,
      scale: 2,
      anchorX: 0.5,
      anchorY: 0.5,
      targetX: 0.2,
      targetY: 0.3,
      targetWidth: 0.4,
      targetHeight: 0.7
    )

    let region = segment.sanitizedTargetRegion()

    XCTAssertEqual(region.width, region.height, accuracy: 1e-9)
    XCTAssertEqual(region.width, 0.4, accuracy: 1e-9)
  }

  func testCursorZoomHeuristicsPrioritizesClickCueAnchors() throws {
    let samples = [
      RecordingProject.CursorSample(timeSeconds: 0.1, x: 0.1, y: 0.1),
      RecordingProject.CursorSample(timeSeconds: 1.0, x: 0.72, y: 0.24),
      RecordingProject.CursorSample(timeSeconds: 1.3, x: 0.74, y: 0.26),
      RecordingProject.CursorSample(timeSeconds: 3.0, x: 0.3, y: 0.8),
    ]
    let cues = [
      RecordingProject.CursorClickCue(timeSeconds: 1.05),
    ]

    let proposed = CursorZoomHeuristics.suggestZoomKeyframes(
      samples: samples,
      clickCues: cues,
      assetDurationSeconds: 4,
      existingKeyframes: []
    )

    let zoom = try XCTUnwrap(proposed.first)
    XCTAssertEqual(zoom.anchorX, 0.72, accuracy: 0.001)
    XCTAssertEqual(zoom.anchorY, 0.24, accuracy: 0.001)
    XCTAssertLessThanOrEqual(zoom.startSeconds, cues[0].timeSeconds)
    XCTAssertGreaterThan(zoom.endSeconds, cues[0].timeSeconds)
  }

  func testCursorZoomHeuristicsSkipsClickCueOverlappingExistingZoom() {
    let samples = [
      RecordingProject.CursorSample(timeSeconds: 0.8, x: 0.6, y: 0.4),
      RecordingProject.CursorSample(timeSeconds: 1.0, x: 0.6, y: 0.4),
    ]
    let existing = [
      RecordingProject.ZoomKeyframe(startSeconds: 0.7, endSeconds: 1.6, scale: 1.4, anchorX: 0.5, anchorY: 0.5),
    ]

    let proposed = CursorZoomHeuristics.suggestZoomKeyframes(
      samples: samples,
      clickCues: [RecordingProject.CursorClickCue(timeSeconds: 1.0)],
      assetDurationSeconds: 4,
      existingKeyframes: existing
    )

    XCTAssertTrue(proposed.isEmpty)
  }

  func testCursorZoomHeuristicsKeepsClickCueNearAssetEnd() throws {
    let samples = [
      RecordingProject.CursorSample(timeSeconds: 3.85, x: 0.82, y: 0.22),
      RecordingProject.CursorSample(timeSeconds: 4.0, x: 0.84, y: 0.24),
    ]

    let proposed = CursorZoomHeuristics.suggestZoomKeyframes(
      samples: samples,
      clickCues: [RecordingProject.CursorClickCue(timeSeconds: 4.0)],
      assetDurationSeconds: 4.0,
      existingKeyframes: []
    )

    let zoom = try XCTUnwrap(proposed.first)
    XCTAssertLessThanOrEqual(zoom.startSeconds, 4.0)
    XCTAssertEqual(zoom.endSeconds, 4.0, accuracy: 1e-9)
    XCTAssertGreaterThanOrEqual(zoom.endSeconds - zoom.startSeconds, CursorZoomHeuristics.Defaults.minSegmentSeconds)
    XCTAssertEqual(zoom.anchorX, 0.84, accuracy: 0.001)
    XCTAssertEqual(zoom.anchorY, 0.24, accuracy: 0.001)
  }

  func testCursorZoomHeuristicsDoesNotDuplicateDwellOverClickZoom() {
    let samples = stride(from: 0.0, through: 2.0, by: 0.25).map {
      RecordingProject.CursorSample(timeSeconds: $0, x: 0.4, y: 0.45)
    }

    let proposed = CursorZoomHeuristics.suggestZoomKeyframes(
      samples: samples,
      clickCues: [RecordingProject.CursorClickCue(timeSeconds: 1.0)],
      assetDurationSeconds: 3.0,
      minDwellSeconds: 0.8,
      existingKeyframes: []
    )

    XCTAssertEqual(proposed.count, 1)
    XCTAssertLessThanOrEqual(proposed[0].startSeconds, 1.0)
    XCTAssertGreaterThan(proposed[0].endSeconds, 1.0)
  }

  func testCursorZoomHeuristicsMergesNearbyClickZooms() throws {
    let samples = [
      RecordingProject.CursorSample(timeSeconds: 0.8, x: 0.48, y: 0.42),
      RecordingProject.CursorSample(timeSeconds: 1.0, x: 0.50, y: 0.43),
      RecordingProject.CursorSample(timeSeconds: 3.1, x: 0.54, y: 0.45),
      RecordingProject.CursorSample(timeSeconds: 3.3, x: 0.56, y: 0.46),
    ]
    let cues = [
      RecordingProject.CursorClickCue(timeSeconds: 1.0),
      RecordingProject.CursorClickCue(timeSeconds: 3.1),
    ]

    let proposed = CursorZoomHeuristics.suggestZoomKeyframes(
      samples: samples,
      clickCues: cues,
      assetDurationSeconds: 6,
      existingKeyframes: []
    )

    let zoom = try XCTUnwrap(proposed.first)
    XCTAssertEqual(proposed.count, 1)
    XCTAssertLessThanOrEqual(zoom.startSeconds, cues[0].timeSeconds)
    XCTAssertGreaterThanOrEqual(zoom.endSeconds, cues[1].timeSeconds)
    XCTAssertGreaterThan(zoom.endSeconds - zoom.startSeconds, CursorZoomHeuristics.Defaults.clickSegmentSeconds)
  }

  func testInputEventShortcutDisplayUsesModifierSymbols() {
    let event = RecordingProject.InputEvent(
      timeSeconds: 0.5,
      kind: .keyDown,
      keyCode: 8,
      characters: "c",
      modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.command.rawValue)
        | UInt64(NSEvent.ModifierFlags.shift.rawValue)
    )

    XCTAssertEqual(event.shortcutDisplayText, "⌘⇧C")
  }

  func testPreviewKeyboardShortcutUsesExportFilteringAndTiming() throws {
    let mouseEvent = RecordingProject.InputEvent(
      timeSeconds: 0.5,
      kind: .mouseDown,
      modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.command.rawValue)
    )
    let shiftOnlyEvent = RecordingProject.InputEvent(
      timeSeconds: 0.6,
      kind: .keyDown,
      keyCode: 8,
      characters: "c",
      modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.shift.rawValue)
    )
    let commandEvent = RecordingProject.InputEvent(
      timeSeconds: 1.0,
      kind: .keyDown,
      keyCode: 8,
      characters: "c",
      modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.command.rawValue)
        | UInt64(NSEvent.ModifierFlags.shift.rawValue)
    )

    XCTAssertNil(EditorPreviewKeyboardShortcut.activeOverlay(
      at: 0.9,
      inputEvents: [mouseEvent, shiftOnlyEvent, commandEvent],
      showsKeyboardShortcuts: true
    ))

    let overlay = try XCTUnwrap(EditorPreviewKeyboardShortcut.activeOverlay(
      at: 1.5,
      inputEvents: [mouseEvent, shiftOnlyEvent, commandEvent],
      showsKeyboardShortcuts: true
    ))
    XCTAssertEqual(overlay.text, "⌘⇧C")
    XCTAssertEqual(overlay.startSeconds, 1.0, accuracy: 1e-9)
    XCTAssertEqual(overlay.endSeconds, 2.1, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.origin.x, 0.34, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.origin.y, 0.06, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.width, 0.32, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.height, 0.075, accuracy: 1e-9)
    XCTAssertNil(EditorPreviewKeyboardShortcut.activeOverlay(
      at: 2.101,
      inputEvents: [commandEvent],
      showsKeyboardShortcuts: true
    ))
  }

  func testPreviewKeyboardShortcutRespectsVisibilityToggle() {
    let event = RecordingProject.InputEvent(
      timeSeconds: 1.0,
      kind: .keyDown,
      keyCode: 8,
      characters: "c",
      modifierFlagsRaw: UInt64(NSEvent.ModifierFlags.command.rawValue)
    )

    XCTAssertNil(EditorPreviewKeyboardShortcut.activeOverlay(
      at: 1.2,
      inputEvents: [event],
      showsKeyboardShortcuts: false
    ))
  }

  func testPreviewKeyboardShortcutRectUsesExportNormalizedPlacement() {
    let size = CGSize(width: 1000, height: 800)
    let rect = EditorPreviewKeyboardShortcut.previewRect(in: size)

    XCTAssertEqual(rect.origin.x, 340, accuracy: 1e-9)
    XCTAssertEqual(rect.origin.y, 48, accuracy: 1e-9)
    XCTAssertEqual(rect.width, 320, accuracy: 1e-9)
    XCTAssertEqual(rect.height, 60, accuracy: 1e-9)
    XCTAssertEqual(rect.midX, 500, accuracy: 1e-9)
    XCTAssertEqual(rect.midY, 78, accuracy: 1e-9)

    let exportRect = ExportVideoGeometry.textOverlayRenderRect(
      originXN: EditorPreviewKeyboardShortcut.normalizedRect.origin.x,
      originYN: EditorPreviewKeyboardShortcut.normalizedRect.origin.y,
      widthN: EditorPreviewKeyboardShortcut.normalizedRect.width,
      heightN: EditorPreviewKeyboardShortcut.normalizedRect.height,
      renderSize: size
    )
    XCTAssertEqual(exportRect.minX, rect.minX, accuracy: 1e-9)
    XCTAssertEqual(exportRect.width, rect.width, accuracy: 1e-9)
    XCTAssertEqual(exportRect.height, rect.height, accuracy: 1e-9)
    XCTAssertEqual(exportRect.minY, size.height - rect.maxY, accuracy: 1e-9)
  }

  func testPreviewCaptionPresentationUsesExportFadeEnvelope() throws {
    let track = RecordingProject.CaptionTrack(
      isEnabled: true,
      segments: [
        .init(startSeconds: 1, endSeconds: 3, text: "Export parity"),
      ]
    )

    XCTAssertNil(EditorPreviewCaptionPresentation.activeOverlay(at: 0.949, captionTrack: track))
    XCTAssertNil(EditorPreviewCaptionPresentation.activeOverlay(at: 0.95, captionTrack: track))
    XCTAssertEqual(
      try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlay(at: 1.0, captionTrack: track)).opacity,
      0.5,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlay(at: 1.05, captionTrack: track)).opacity,
      1,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlay(at: 2.95, captionTrack: track)).opacity,
      1,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlay(at: 3.0, captionTrack: track)).opacity,
      0.5,
      accuracy: 1e-9
    )
    XCTAssertNil(EditorPreviewCaptionPresentation.activeOverlay(at: 3.05, captionTrack: track))
    XCTAssertNil(EditorPreviewCaptionPresentation.activeOverlay(at: 3.051, captionTrack: track))
  }

  func testPreviewCaptionPresentationUsesCaptionTextOverlayRect() throws {
    let style = RecordingProject.CaptionTrack.Style(
      fontPointSize: 44,
      bottomInsetN: 0.10,
      backgroundOpacity: 0.9
    )
    let track = RecordingProject.CaptionTrack(
      isEnabled: true,
      segments: [
        .init(startSeconds: 1, endSeconds: 3, text: "Caption"),
      ],
      style: style
    )

    let overlay = try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlay(
      at: 2,
      captionTrack: track
    ))
    let textOverlay = try XCTUnwrap(track.asTextOverlays().first)
    XCTAssertEqual(overlay.normalizedRect.origin.x, textOverlay.originXN, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.origin.y, textOverlay.originYN, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.width, textOverlay.widthN, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.height, textOverlay.heightN, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.origin.x, 0.08, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.origin.y, 0.78, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.width, 0.84, accuracy: 1e-9)
    XCTAssertEqual(overlay.normalizedRect.height, 0.12, accuracy: 1e-9)

    let size = CGSize(width: 1000, height: 800)
    let rect = EditorPreviewCaptionPresentation.previewRect(for: overlay, in: size)
    XCTAssertEqual(rect.origin.x, 80, accuracy: 1e-9)
    XCTAssertEqual(rect.origin.y, 624, accuracy: 1e-9)
    XCTAssertEqual(rect.width, 840, accuracy: 1e-9)
    XCTAssertEqual(rect.height, 96, accuracy: 1e-9)
  }

  func testPreviewCaptionPresentationKeepsMultipleActiveTextOverlays() throws {
    let firstID = UUID()
    let secondID = UUID()
    let overlays = [
      RecordingProject.TextOverlayAnnotation(
        id: firstID,
        startSeconds: 1,
        endSeconds: 3,
        text: "First",
        originXN: 0.08,
        originYN: 0.78,
        widthN: 0.84,
        heightN: 0.12,
        fontPointSize: 30
      ),
      RecordingProject.TextOverlayAnnotation(
        id: secondID,
        startSeconds: 1.5,
        endSeconds: 3,
        text: "Second",
        originXN: 0.12,
        originYN: 0.12,
        widthN: 0.5,
        heightN: 0.1,
        fontPointSize: 24
      ),
    ]

    let active = EditorPreviewCaptionPresentation.activeOverlays(at: 2, textOverlays: overlays)

    XCTAssertEqual(active.map(\.id), [firstID, secondID])
    XCTAssertEqual(active.map(\.text), ["First", "Second"])
  }

  func testPreviewCaptionPresentationIncludesManualTextOverlayAnnotations() throws {
    let manualID = UUID()
    var project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Text overlay parity",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: URL(fileURLWithPath: "/tmp/text-overlay-parity.mov"),
      cursorSamples: [],
      exportPreset: .p1080p60,
      stylePreset: .none
    )
    project.textOverlayAnnotations = [
      RecordingProject.TextOverlayAnnotation(
        id: manualID,
        startSeconds: 0,
        endSeconds: 2,
        text: "Manual title",
        originXN: 0.2,
        originYN: 0.2,
        widthN: 0.4,
        heightN: 0.1,
        fontPointSize: 32
      )
    ]
    project.captionTrack = RecordingProject.CaptionTrack(
      isEnabled: true,
      segments: [
        .init(startSeconds: 0, endSeconds: 2, text: "Caption"),
      ]
    )

    let active = EditorPreviewCaptionPresentation.activeOverlays(
      at: 1,
      textOverlays: project.textOverlayAnnotations + project.captionTrack.asTextOverlays()
    )

    XCTAssertEqual(active.count, 2)
    XCTAssertEqual(active.first?.id, manualID)
    XCTAssertEqual(active.first?.text, "Manual title")
    XCTAssertEqual(active.first?.normalizedRect.origin.x ?? -1, 0.2, accuracy: 1e-9)
  }

  func testPreviewCaptionPresentationUsesStableRenderIDsForDuplicateOverlayIDs() throws {
    let sharedID = UUID()
    let overlays = [
      RecordingProject.TextOverlayAnnotation(
        id: sharedID,
        startSeconds: 0,
        endSeconds: 2,
        text: "Manual",
        fontPointSize: 28
      ),
      RecordingProject.TextOverlayAnnotation(
        id: sharedID,
        startSeconds: 0,
        endSeconds: 2,
        text: "Caption fallback",
        fontPointSize: 28
      ),
    ]

    let active = EditorPreviewCaptionPresentation.activeOverlays(
      at: 1,
      textOverlays: overlays,
      durationSeconds: 2
    )

    XCTAssertEqual(active.map(\.id), [sharedID, sharedID])
    XCTAssertEqual(Set(active.map(\.renderID)).count, 2)
  }

  func testPreviewCaptionPresentationSanitizesManualTextOverlaysLikeExport() throws {
    let overlay = RecordingProject.TextOverlayAnnotation(
      startSeconds: 1.0,
      endSeconds: 0.98,
      text: String(repeating: "x", count: 2_100),
      originXN: 1.2,
      originYN: -0.2,
      widthN: 0.001,
      heightN: 4,
      fontPointSize: 240
    )

    let active = try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlays(
      at: 1.01,
      textOverlays: [overlay],
      durationSeconds: 2
    ).first)

    XCTAssertEqual(active.startSeconds, 0.98, accuracy: 1e-9)
    XCTAssertEqual(active.endSeconds, 1.03, accuracy: 1e-9)
    XCTAssertEqual(active.normalizedRect.origin.x, 1, accuracy: 1e-9)
    XCTAssertEqual(active.normalizedRect.origin.y, 0, accuracy: 1e-9)
    XCTAssertEqual(active.normalizedRect.width, 0.02, accuracy: 1e-9)
    XCTAssertEqual(active.normalizedRect.height, 1, accuracy: 1e-9)
    XCTAssertEqual(active.style.fontPointSize, 120, accuracy: 1e-9)
    XCTAssertEqual(active.text.count, 2_048)
  }

  func testPreviewCaptionPresentationSanitizesAgainstSourceDuration() throws {
    let overlay = RecordingProject.TextOverlayAnnotation(
      startSeconds: 6,
      endSeconds: 7,
      text: "After trimmed preview midpoint",
      fontPointSize: 28
    )

    XCTAssertNil(EditorPreviewCaptionPresentation.activeOverlays(
      at: 6.5,
      textOverlays: [overlay],
      durationSeconds: 5
    ).first)

    let active = try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlays(
      at: 6.5,
      textOverlays: [overlay],
      durationSeconds: 8
    ).first)
    XCTAssertEqual(active.startSeconds, 6, accuracy: 1e-9)
    XCTAssertEqual(active.endSeconds, 7, accuracy: 1e-9)
    XCTAssertEqual(active.text, "After trimmed preview midpoint")
  }

  func testPreviewCaptionPresentationUsesExportTextStyleConstants() throws {
    let track = RecordingProject.CaptionTrack(
      isEnabled: true,
      segments: [
        .init(startSeconds: 0, endSeconds: 2, text: "Caption style"),
      ],
      style: .init(fontPointSize: 40, bottomInsetN: 0.08, backgroundOpacity: 1)
    )

    let overlay = try XCTUnwrap(EditorPreviewCaptionPresentation.activeOverlay(
      at: 1,
      captionTrack: track
    ))

    XCTAssertEqual(overlay.style.fontPointSize, 40, accuracy: 1e-9)
    XCTAssertEqual(overlay.style.backgroundOpacity, 0.35, accuracy: 1e-9)
    XCTAssertEqual(overlay.style.cornerRadius, 6, accuracy: 1e-9)
    XCTAssertEqual(overlay.style.horizontalTextInset, 14, accuracy: 1e-9)
    XCTAssertEqual(overlay.style.verticalTextInset, 7.7, accuracy: 1e-9)
  }

  func testPreviewCameraPresentationUsesCameraSegmentGeometry() {
    let segment = RecordingProject.CameraLayoutSegment(
      startSeconds: 0,
      endSeconds: 2,
      layout: .pip,
      originXN: 0.72,
      originYN: 0.70,
      widthN: 0.22,
      heightN: 0.16,
      cornerRadiusPts: 24,
      shrinkDuringZoom: true
    )

    let presentation = EditorPreviewCameraPresentation.presentation(
      for: segment,
      isZoomActive: false
    )

    XCTAssertFalse(presentation.isHidden)
    XCTAssertEqual(presentation.normalizedRect.origin.x, 0.72, accuracy: 1e-9)
    XCTAssertEqual(presentation.normalizedRect.origin.y, 0.70, accuracy: 1e-9)
    XCTAssertEqual(presentation.normalizedRect.width, 0.22, accuracy: 1e-9)
    XCTAssertEqual(presentation.normalizedRect.height, 0.16, accuracy: 1e-9)
    XCTAssertEqual(presentation.cornerRadius, 13.2, accuracy: 1e-9)

    let rect = EditorPreviewCameraPresentation.previewRect(
      for: presentation,
      in: CGSize(width: 1000, height: 800)
    )
    XCTAssertEqual(rect.origin.x, 720, accuracy: 1e-9)
    XCTAssertEqual(rect.origin.y, 560, accuracy: 1e-9)
    XCTAssertEqual(rect.width, 220, accuracy: 1e-9)
    XCTAssertEqual(rect.height, 128, accuracy: 1e-9)
  }

  func testPreviewCameraPresentationKeepsConstantSizeDuringZoom() {
    let segment = RecordingProject.CameraLayoutSegment(
      startSeconds: 0,
      endSeconds: 2,
      layout: .pip,
      originXN: 0.72,
      originYN: 0.70,
      widthN: 0.20,
      heightN: 0.10,
      shrinkDuringZoom: true
    )

    let presentation = EditorPreviewCameraPresentation.presentation(
      for: segment,
      isZoomActive: true
    )

    XCTAssertEqual(presentation.normalizedRect.width, 0.20, accuracy: 1e-9)
    XCTAssertEqual(presentation.normalizedRect.height, 0.10, accuracy: 1e-9)
    XCTAssertEqual(presentation.normalizedRect.origin.x, 0.72, accuracy: 1e-9)
    XCTAssertEqual(presentation.normalizedRect.origin.y, 0.70, accuracy: 1e-9)
  }

  func testPreviewCameraPresentationHandlesFullscreenAndHiddenLayouts() {
    let fullscreen = EditorPreviewCameraPresentation.presentation(
      for: RecordingProject.CameraLayoutSegment(
        startSeconds: 0,
        endSeconds: 2,
        layout: .fullscreen,
        originXN: 0.72,
        originYN: 0.70,
        widthN: 0.20,
        heightN: 0.10,
        cornerRadiusPts: 24
      ),
      isZoomActive: true
    )

    XCTAssertFalse(fullscreen.isHidden)
    XCTAssertEqual(fullscreen.normalizedRect, CGRect(x: 0, y: 0, width: 1, height: 1))
    XCTAssertEqual(fullscreen.cornerRadius, 0, accuracy: 1e-9)

    let hidden = EditorPreviewCameraPresentation.presentation(
      for: RecordingProject.CameraLayoutSegment(
        startSeconds: 0,
        endSeconds: 2,
        layout: .hidden
      ),
      isZoomActive: true
    )

    XCTAssertTrue(hidden.isHidden)
    XCTAssertEqual(hidden.normalizedRect, .zero)
    XCTAssertEqual(hidden.cornerRadius, 0, accuracy: 1e-9)
  }

  func testPreviewCameraPresentationUsesTimelineSpeedForPlaybackRate() {
    let sourceURL = URL(fileURLWithPath: "/tmp/main.mov")
    let timeline = RecordingProject.TimelineModel(
      clips: [
        .init(
          sourceURL: sourceURL,
          sourceStartSeconds: 0,
          timelineStartSeconds: 0,
          durationSeconds: 2
        ),
        .init(
          sourceURL: sourceURL,
          sourceStartSeconds: 3,
          timelineStartSeconds: 2,
          durationSeconds: 1
        ),
      ],
      speedSegments: [
        .init(startSeconds: 2, endSeconds: 3, rate: 2),
      ]
    )

    XCTAssertEqual(
      EditorPreviewCameraPresentation.playbackRate(atTimelineSeconds: 0.5, timeline: timeline),
      1,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewCameraPresentation.playbackRate(atTimelineSeconds: 2.5, timeline: timeline),
      2,
      accuracy: 1e-9
    )
    XCTAssertEqual(
      EditorPreviewCameraPresentation.playbackRate(atTimelineSeconds: 9, timeline: timeline),
      RecordingProject.TimelineEditing.defaultSpeedRate,
      accuracy: 1e-9
    )
  }

  func testExportPIPClipUsesAttachmentGeometryAndCornerRadius() {
    let clip = ArcShotCompositionInstructionBuilder.pipClip(
      attachment: RecordingProject.SecondaryRecordingAttachment(
        mediaURL: URL(fileURLWithPath: "/tmp/camera.mov"),
        originXN: 0.70,
        originYN: 0.62,
        widthN: 0.20,
        heightN: 0.16,
        cornerRadiusPts: 24
      ),
      renderSize: CGSize(width: 1920, height: 1080)
    )

    XCTAssertEqual(clip.rect.origin.x, 1344, accuracy: 1e-9)
    XCTAssertEqual(clip.rect.origin.y, 237.6, accuracy: 1e-9)
    XCTAssertEqual(clip.rect.width, 384, accuracy: 1e-9)
    XCTAssertEqual(clip.rect.height, 172.8, accuracy: 1e-9)
    XCTAssertEqual(clip.cornerRadius, 13.2, accuracy: 1e-9)

    let fullscreenClip = ArcShotCompositionInstructionBuilder.pipClip(
      attachment: RecordingProject.SecondaryRecordingAttachment(
        mediaURL: URL(fileURLWithPath: "/tmp/camera.mov"),
        originXN: 0,
        originYN: 0,
        widthN: 1,
        heightN: 1,
        cornerRadiusPts: 24
      ),
      renderSize: CGSize(width: 1920, height: 1080)
    )
    XCTAssertEqual(fullscreenClip.rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(fullscreenClip.cornerRadius, 0, accuracy: 1e-9)
  }

  func testExportPIPCompositorRectMatchesBottomTrailingPreview() {
    let geometry = CameraPiPDefaults.bottomTrailingSquarePiP(videoWidth: 1920, videoHeight: 1080)
    let renderSize = CGSize(width: 1920, height: 1080)
    let pixelSize = geometry.pixelSize(for: renderSize)
    XCTAssertEqual(pixelSize.width, pixelSize.height, accuracy: 1e-6)
    let rect = ExportVideoGeometry.pipCompositorRect(
      originXN: geometry.originXN,
      originYN: geometry.originYN,
      widthN: geometry.widthN,
      heightN: geometry.heightN,
      renderSize: renderSize
    )
    XCTAssertEqual(rect.origin.y, CameraPiPDefaults.marginN * 1080, accuracy: 1e-9)
    XCTAssertGreaterThan(rect.origin.y, 0)
    XCTAssertLessThan(rect.origin.y, 1080 * 0.1)
  }

  func testCameraPiPDefaultsSquareFootprintUsesHeightAsReference() {
    let geometry = CameraPiPDefaults.bottomTrailingSquarePiP(videoWidth: 1920, videoHeight: 1080)
    XCTAssertEqual(geometry.heightN, CameraPiPDefaults.pipSizeN, accuracy: 1e-9)
    XCTAssertEqual(geometry.widthN, CameraPiPDefaults.pipSizeN * (1080.0 / 1920.0), accuracy: 1e-9)
    let pixels = geometry.pixelSize(for: CGSize(width: 1920, height: 1080))
    XCTAssertEqual(pixels.width, 1920 * CameraPiPDefaults.pipSizeN * (1080.0 / 1920.0), accuracy: 1e-6)
    XCTAssertEqual(pixels.height, 1080 * CameraPiPDefaults.pipSizeN, accuracy: 1e-6)
    XCTAssertEqual(pixels.width, pixels.height, accuracy: 1e-6)
  }

  func testExportPIPTimelineSourceMapperUsesClipSourceWindowsAndSpeed() {
    let sourceURL = URL(fileURLWithPath: "/tmp/main.mov")
    let firstClip = RecordingProject.TimelineModel.Clip(
      sourceURL: sourceURL,
      sourceStartSeconds: 1.25,
      timelineStartSeconds: 0,
      durationSeconds: 2
    )
    let secondClip = RecordingProject.TimelineModel.Clip(
      sourceURL: sourceURL,
      sourceStartSeconds: 4.5,
      timelineStartSeconds: 2,
      durationSeconds: 1
    )
    let timeline = RecordingProject.TimelineModel(
      clips: [firstClip, secondClip],
      speedSegments: [
        .init(startSeconds: 2, endSeconds: 3, rate: 2),
      ]
    )

    let slices = ExportPIPTimelineSourceMapper.slices(
      clips: timeline.activeClips,
      timeline: timeline,
      pipDurationSeconds: 8
    )

    XCTAssertEqual(slices.count, 2)
    XCTAssertEqual(slices[0].sourceStartSeconds, 1.25, accuracy: 1e-9)
    XCTAssertEqual(slices[0].sourceDurationSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(slices[0].timelineStartSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(slices[0].timelineDurationSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(slices[0].rate, 1, accuracy: 1e-9)

    XCTAssertEqual(slices[1].sourceStartSeconds, 4.5, accuracy: 1e-9)
    XCTAssertEqual(slices[1].sourceDurationSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(slices[1].timelineStartSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(slices[1].timelineDurationSeconds, 1, accuracy: 1e-9)
    XCTAssertEqual(slices[1].rate, 2, accuracy: 1e-9)
  }

  func testCaptionMaskCameraAndAudioSettingsClamp() {
    let caption = RecordingProject.CaptionTrack(
      isEnabled: true,
      transcript: String(repeating: "a", count: 21_000),
      segments: [
        .init(startSeconds: 5, endSeconds: 4, text: String(repeating: "b", count: 3_000)),
      ],
      style: .init(fontPointSize: 999, bottomInsetN: 9, backgroundOpacity: -2)
    )
    XCTAssertEqual(caption.transcript.count, 20_000)
    XCTAssertEqual(caption.segments[0].startSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(caption.segments[0].endSeconds, 5, accuracy: 1e-9)
    XCTAssertEqual(caption.segments[0].text.count, 2_048)
    XCTAssertEqual(caption.style.fontPointSize, 120, accuracy: 1e-9)
    XCTAssertEqual(caption.style.bottomInsetN, 0.35, accuracy: 1e-9)
    XCTAssertEqual(caption.style.backgroundOpacity, 0, accuracy: 1e-9)

    let masks = RecordingProject.sanitizedVisualMasks([
      .init(startSeconds: 8, endSeconds: 3, kind: .blur, originXN: 0.95, originYN: -1, widthN: 0.8, heightN: 0.001, opacity: 9),
    ], durationSeconds: 6)
    XCTAssertEqual(masks[0].startSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(masks[0].endSeconds, 6, accuracy: 1e-9)
    XCTAssertLessThanOrEqual(masks[0].widthN + masks[0].originXN, 1.000_001)
    XCTAssertEqual(masks[0].opacity, 1, accuracy: 1e-9)

    let sourceSize = CGSize(width: 1920, height: 1080)
    let previewSize = CGSize(width: 960, height: 540)
    let mask = RecordingProject.VisualMask(
      startSeconds: 0,
      endSeconds: 1,
      kind: .highlight,
      originXN: 0.25,
      originYN: 0.10,
      widthN: 0.50,
      heightN: 0.30
    )
    let previewRect = EditorPreviewLayout.maskRect(
      mask: mask,
      in: previewSize,
      sourceSize: sourceSize
    )
    XCTAssertEqual(Double(previewRect.minX), 240, accuracy: 1e-6)
    XCTAssertEqual(Double(previewRect.minY), 54, accuracy: 1e-6)
    XCTAssertEqual(Double(previewRect.width), 480, accuracy: 1e-6)
    XCTAssertEqual(Double(previewRect.height), 162, accuracy: 1e-6)

    let sourceRect = ExportVideoGeometry.maskSourceRect(
      originXN: mask.originXN,
      originYN: mask.originYN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize
    )
    XCTAssertEqual(Double(sourceRect.minX), 480, accuracy: 1e-6)
    XCTAssertEqual(Double(sourceRect.minY), 648, accuracy: 1e-6)
    XCTAssertEqual(Double(sourceRect.width), 960, accuracy: 1e-6)
    XCTAssertEqual(Double(sourceRect.height), 324, accuracy: 1e-6)

    let renderRect = ExportVideoGeometry.maskRenderRect(
      originXN: mask.originXN,
      originYN: mask.originYN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize,
      sourceTransform: .identity,
      renderSize: sourceSize
    )
    XCTAssertEqual(Double(renderRect.minX), 480, accuracy: 1e-6)
    XCTAssertEqual(Double(renderRect.minY), 108, accuracy: 1e-6)
    XCTAssertEqual(Double(renderRect.width), 960, accuracy: 1e-6)
    XCTAssertEqual(Double(renderRect.height), 324, accuracy: 1e-6)

    let previewStyle = EditorPreviewMaskPresentation.style(for: .highlight)
    XCTAssertEqual(previewStyle.cornerRadius, 12, accuracy: 1e-9)
    XCTAssertEqual(previewStyle.fillOpacity, 0.12, accuracy: 1e-9)
    XCTAssertEqual(previewStyle.strokeOpacity, 0.86, accuracy: 1e-9)
    XCTAssertEqual(previewStyle.strokeLineWidth, 4, accuracy: 1e-9)
    XCTAssertFalse(previewStyle.usesMaterialProxy)

    let camera = RecordingProject.sanitizedCameraLayoutSegments([
      .init(startSeconds: 9, endSeconds: 1, layout: .fullscreen, originXN: -1, originYN: 0.99, widthN: 10, heightN: 10, cornerRadiusPts: 999),
    ], durationSeconds: 5)
    XCTAssertEqual(camera[0].startSeconds, 1, accuracy: 1e-9)
    XCTAssertEqual(camera[0].endSeconds, 5, accuracy: 1e-9)
    XCTAssertEqual(camera[0].cornerRadiusPts, 160, accuracy: 1e-9)

    let audio = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: true, volume: 3),
      system: .init(isEnabled: true, volume: -1),
      backgroundMusic: .init(isEnabled: true, volume: 0.5)
    )
    XCTAssertEqual(audio.microphone.volume, 2, accuracy: 1e-9)
    XCTAssertEqual(audio.system.volume, 0, accuracy: 1e-9)
    XCTAssertEqual(audio.backgroundMusic.volume, 0.5, accuracy: 1e-9)
  }

  func testEditorPreviewMaskPresentationUsesExportFadeEnvelope() {
    let mask = RecordingProject.VisualMask(
      startSeconds: 1,
      endSeconds: 3,
      kind: .highlight,
      opacity: 0.5
    )

    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 0.91, mask: mask), 0, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 0.92, mask: mask), 0, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 1.0, mask: mask), 0.25, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 1.08, mask: mask), 0.5, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 2.0, mask: mask), 0.5, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 3.0, mask: mask), 0.25, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 3.08, mask: mask), 0, accuracy: 1e-9)
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 3.09, mask: mask), 0, accuracy: 1e-9)
    XCTAssertTrue(EditorPreviewMaskPresentation.isActive(at: 1.0, mask: mask))
    XCTAssertFalse(EditorPreviewMaskPresentation.isActive(at: 3.09, mask: mask))
  }

  func testVisualMaskStyleMatchesPreviewAndExportConstants() {
    let highlightStyle = EditorPreviewMaskPresentation.style(for: .highlight)
    XCTAssertEqual(VisualMaskStyle.cornerRadius, 12, accuracy: 1e-9)
    XCTAssertEqual(VisualMaskStyle.blurRadius, 28, accuracy: 1e-9)
    XCTAssertEqual(highlightStyle.cornerRadius, VisualMaskStyle.cornerRadius, accuracy: 1e-9)
    XCTAssertEqual(highlightStyle.fillOpacity, VisualMaskStyle.highlightFillOpacity, accuracy: 1e-9)
    XCTAssertEqual(highlightStyle.strokeOpacity, VisualMaskStyle.highlightStrokeOpacity, accuracy: 1e-9)
    XCTAssertEqual(highlightStyle.strokeLineWidth, VisualMaskStyle.highlightStrokeWidth, accuracy: 1e-9)
    XCTAssertFalse(highlightStyle.usesMaterialProxy)

    let sourceSize = CGSize(width: 1920, height: 1080)
    let videoRect = CGRect(x: 0, y: 0, width: 960, height: 540)
    XCTAssertEqual(
      VisualMaskStyle.previewBlurRadius(sourceSize: sourceSize, videoRect: videoRect),
      14,
      accuracy: 1e-6
    )

    let blurMask = RecordingProject.VisualMask(
      startSeconds: 1,
      endSeconds: 3,
      kind: .blur,
      opacity: 0.5
    )
    XCTAssertEqual(EditorPreviewMaskPresentation.activeOpacity(at: 2.0, mask: blurMask), 0.5, accuracy: 1e-9)
  }

  func testAudioTrackSettingsUsesExplicitRecordedRoleOrderWhenAvailable() {
    let musicURL = URL(fileURLWithPath: "/tmp/music.caf")
    let systemOnly = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: false, volume: 0.2),
      system: .init(isEnabled: true, volume: 0.7),
      recordedTrackRoles: [.system]
    )

    XCTAssertEqual(systemOnly.volumeForCompositionTrack(index: 0, totalCount: 1), 0.7, accuracy: 1e-9)

    let mixed = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: true, volume: 0.5),
      system: .init(isEnabled: true, volume: 0.8),
      backgroundMusic: .init(isEnabled: true, volume: 0.25),
      backgroundMusicURL: musicURL,
      recordedTrackRoles: [.system, .microphone]
    )

    XCTAssertEqual(mixed.volumeForCompositionTrack(index: 0, totalCount: 3), 0.8, accuracy: 1e-9)
    XCTAssertEqual(mixed.volumeForCompositionTrack(index: 1, totalCount: 3), 0.5, accuracy: 1e-9)
    XCTAssertEqual(mixed.volumeForCompositionTrack(index: 2, totalCount: 3), 0.25, accuracy: 1e-9)
  }

  func testAudioTrackSettingsFallsBackToInferredRoleOrder() {
    let inferred = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: true, volume: 0.4),
      system: .init(isEnabled: true, volume: 0.9)
    )

    XCTAssertEqual(inferred.volumeForCompositionTrack(index: 0, totalCount: 2), 0.4, accuracy: 1e-9)
    XCTAssertEqual(inferred.volumeForCompositionTrack(index: 1, totalCount: 2), 0.9, accuracy: 1e-9)
  }

  func testAudioTrackSettingsMapsDisabledExplicitRolesToZero() {
    let audio = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: false, volume: 0.6),
      system: .init(isEnabled: true, volume: 0.8),
      recordedTrackRoles: [.microphone, .system]
    )

    XCTAssertEqual(audio.volumeForCompositionTrack(index: 0, totalCount: 2), 0, accuracy: 1e-9)
    XCTAssertEqual(audio.volumeForCompositionTrack(index: 1, totalCount: 2), 0.8, accuracy: 1e-9)
  }

  func testTimelineAudioRoleStatusUsesRecordedRolesAndBackgroundURL() {
    let musicURL = URL(fileURLWithPath: "/tmp/music.caf")
    let audio = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: true, volume: 0.7),
      system: .init(isEnabled: true, volume: 0.8),
      backgroundMusic: .init(isEnabled: false, volume: 0.4),
      backgroundMusicURL: musicURL,
      recordedTrackRoles: [.microphone]
    )

    let statuses = TimelineAudioRoleStatus.statuses(for: audio)

    XCTAssertEqual(statuses.map(\.id), [.microphone, .system, .backgroundMusic])
    XCTAssertEqual(statuses[0].displayValue, "70%")
    XCTAssertEqual(statuses[1].isAvailable, false)
    XCTAssertEqual(statuses[1].displayValue, "未接続")
    XCTAssertEqual(statuses[2].isAvailable, true)
    XCTAssertEqual(statuses[2].displayValue, "Mute")
  }

  @MainActor
  func testCaptionGeneratorSanitizesLocalEngineResult() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/local-caption-source.mov")
    let overlayID = UUID()
    let generator = CaptionGenerator(engine: StubCaptionEngine(result: .success(.init(
      overlays: [
        // 壊れたエンジン出力でも、UI に渡す前に既存 sanitizer で安全な字幕範囲へ正規化する。
        RecordingProject.TextOverlayAnnotation(
          id: overlayID,
          startSeconds: 2.0,
          endSeconds: 1.0,
          text: String(repeating: "字", count: 3_000)
        ),
      ],
      transcript: String(repeating: "a", count: 21_000)
    ))))

    let generated = await generator.generateFromMedia(url: sourceURL)
    let result = try XCTUnwrap(generated)

    XCTAssertEqual(generator.state, .finished)
    XCTAssertEqual(generator.transcript.count, 20_000)
    XCTAssertEqual(result.transcript.count, 20_000)
    XCTAssertEqual(result.overlays.map(\.id), [overlayID])
    XCTAssertEqual(result.overlays[0].startSeconds, 1.0, accuracy: 1e-9)
    XCTAssertEqual(result.overlays[0].endSeconds, 2.0, accuracy: 1e-9)
    XCTAssertEqual(result.overlays[0].text.count, 2_048)
  }

  @MainActor
  func testCaptionGeneratorReportsLocalEngineFailure() async {
    let sourceURL = URL(fileURLWithPath: "/tmp/no-audio.mov")
    let generator = CaptionGenerator(engine: StubCaptionEngine(result: .failure(CaptionEngineError.noAudioTrack)))

    let result = await generator.generateFromMedia(url: sourceURL)

    XCTAssertNil(result)
    if case .failed(let message) = generator.state {
      XCTAssertTrue(
        message.contains("Caption generation failed") || message.contains("字幕生成"),
        "Unexpected failure message: \(message)"
      )
      XCTAssertTrue(message.contains("音声トラック"), "Unexpected failure message: \(message)")
    } else {
      XCTFail("Expected failed state, got \(generator.state)")
    }
    XCTAssertEqual(generator.transcript, "")
  }

  func testEditorSegmentRangePlayheadBasedShiftsLeftNearEnd() throws {
    let range = EditorSegmentRange.playheadBased(
      at: 9.5,
      preferredDuration: 2,
      totalDuration: 10,
      minimumDuration: 0.1
    )
    let unwrapped = try XCTUnwrap(range)

    XCTAssertEqual(unwrapped.start, 8, accuracy: 1e-9)
    XCTAssertEqual(unwrapped.end, 10, accuracy: 1e-9)
  }

  func testEditorSegmentRangeAppendBasedDoesNotShiftLeftAtEnd() {
    let range = EditorSegmentRange.appendBased(
      after: 10,
      preferredDuration: 2,
      totalDuration: 10,
      minimumDuration: 0.1
    )

    XCTAssertNil(range)
  }

  func testEditorSegmentRangeAppendBasedShortensWhenRemainingMeetsMinimum() throws {
    let range = EditorSegmentRange.appendBased(
      after: 9.95,
      preferredDuration: 2,
      totalDuration: 10,
      minimumDuration: 0.05
    )
    let unwrapped = try XCTUnwrap(range)

    XCTAssertEqual(unwrapped.start, 9.95, accuracy: 1e-9)
    XCTAssertEqual(unwrapped.end, 10, accuracy: 1e-9)
  }

  func testEditorLayoutPersistsTimelinePaneHeight() {
    let suiteName = "dev.arcshot.tests.timeline-pane-height.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(
      EditorLayout.loadStoredTimelinePaneHeight(defaults: defaults),
      EditorLayout.defaultTimelinePaneHeight,
      accuracy: 1e-6
    )

    EditorLayout.saveTimelinePaneHeight(350, defaults: defaults)
    XCTAssertEqual(
      EditorLayout.loadStoredTimelinePaneHeight(defaults: defaults),
      350,
      accuracy: 1e-6
    )
  }

  func testEditorLayoutPreviewTimelineSplitMetricsMatchClampRules() {
    let available: CGFloat = 700
    let metrics = EditorLayout.previewTimelineSplitMetrics(
      timelinePaneHeight: EditorLayout.defaultTimelinePaneHeight,
      availableHeight: available
    )
    XCTAssertEqual(
      metrics.clampedTimelineHeight,
      EditorLayout.clampedTimelinePaneHeight(
        EditorLayout.defaultTimelinePaneHeight,
        availableHeight: available
      ),
      accuracy: 1e-6
    )
    XCTAssertEqual(
      metrics.previewHeight + metrics.clampedTimelineHeight + metrics.handleHeight,
      available,
      accuracy: 1e-6
    )
    XCTAssertEqual(
      metrics.resizeBandHeight,
      EditorLayout.previewTimelineResizeHandleHeight + EditorLayout.previewTimelineResizeHitSlop * 2,
      accuracy: 1e-6
    )
  }

  func testEditorLayoutClampsTimelinePaneHeightWithinSplitBounds() {
    let available: CGFloat = 700
    XCTAssertEqual(
      EditorLayout.clampedTimelinePaneHeight(900, availableHeight: available),
      floor(available * EditorLayout.maxTimelinePaneShareOfSplit),
      accuracy: 1e-6
    )
    XCTAssertEqual(
      EditorLayout.clampedTimelinePaneHeight(900, availableHeight: 900),
      EditorLayout.maxTimelinePaneHeight,
      accuracy: 1e-6
    )
    XCTAssertEqual(
      EditorLayout.clampedTimelinePaneHeight(120, availableHeight: available),
      EditorLayout.minTimelinePaneHeight,
      accuracy: 1e-6
    )
    XCTAssertGreaterThanOrEqual(
      EditorLayout.minTimelinePaneHeight,
      EditorLayout.timelinePaneHeight(waveformRoleCount: 3)
    )
    XCTAssertEqual(
      EditorLayout.previewPaneHeight(
        timelinePaneHeight: EditorLayout.defaultTimelinePaneHeight,
        availableHeight: available
      ),
      available - EditorLayout.defaultTimelinePaneHeight - EditorLayout.previewTimelineResizeHandleHeight,
      accuracy: 1e-6
    )
  }

  func testEditorSegmentRangePlayheadBasedAllowsMaskAddWhenTimelineTailIsOccupied() throws {
    let range = EditorSegmentRange.playheadBased(
      at: 1.96,
      preferredDuration: 2,
      totalDuration: 19.43,
      minimumDuration: RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds
    )
    let unwrapped = try XCTUnwrap(range)

    XCTAssertEqual(unwrapped.start, 1.96, accuracy: 1e-9)
    XCTAssertEqual(unwrapped.end, 3.96, accuracy: 1e-9)
  }

  func testEditorSegmentRangeAppendBasedReturnsNilWhenRemainingIsBelowMinimum() {
    let range = EditorSegmentRange.appendBased(
      after: 9.96,
      preferredDuration: 2,
      totalDuration: 10,
      minimumDuration: 0.05
    )

    XCTAssertNil(range)
  }

  func testEditorTimelineEffectSelectionKeepsAssociatedIDs() {
    let zoomID = UUID()
    let captionID = UUID()
    let maskID = UUID()
    let cameraID = UUID()
    let audioID = UUID()

    XCTAssertEqual(EditorTimelineEffectSelection.zoom(zoomID), .zoom(zoomID))
    XCTAssertEqual(EditorTimelineEffectSelection.caption(captionID), .caption(captionID))
    XCTAssertEqual(EditorTimelineEffectSelection.mask(maskID), .mask(maskID))
    XCTAssertEqual(EditorTimelineEffectSelection.camera(cameraID), .camera(cameraID))
    XCTAssertEqual(EditorTimelineEffectSelection.audio(audioID), .audio(audioID))
    XCTAssertEqual(EditorTimelineEffectSelection.zoom(zoomID).id, zoomID)
    XCTAssertEqual(EditorTimelineEffectSelection.caption(captionID).id, captionID)
    XCTAssertEqual(EditorTimelineEffectSelection.mask(maskID).id, maskID)
    XCTAssertEqual(EditorTimelineEffectSelection.camera(cameraID).id, cameraID)
    XCTAssertEqual(EditorTimelineEffectSelection.audio(audioID).id, audioID)
    XCTAssertEqual(EditorTimelineEffectSelection.zoom(zoomID).rangeKind, .zoom)
    XCTAssertEqual(EditorTimelineEffectSelection.caption(captionID).rangeKind, .caption)
    XCTAssertEqual(EditorTimelineEffectSelection.mask(maskID).rangeKind, .mask)
    XCTAssertEqual(EditorTimelineEffectSelection.camera(cameraID).rangeKind, .camera)
    XCTAssertEqual(EditorTimelineEffectSelection.audio(audioID).rangeKind, .audio)
  }

  func testDefaultAudioTimelineSegmentsCoverRecordedRoles() {
    let settings = RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: true, volume: 1),
      system: .init(isEnabled: true, volume: 1),
      recordedTrackRoles: [.microphone, .system]
    )
    let segments = RecordingProject.defaultAudioTimelineSegments(durationSeconds: 12, settings: settings)
    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments.map(\.role), [.microphone, .system])
    XCTAssertEqual(segments.first?.startSeconds, 0)
    XCTAssertEqual(segments.first?.endSeconds ?? 0, 12, accuracy: 1e-6)
  }

  func testEditorTimelineEffectSegmentsKeepClickCuesOutOfEditableLane() {
    let maskID = UUID()
    let clickID = UUID()
    var project = RecordingProject.default(
      mediaURL: URL(fileURLWithPath: "/tmp/effects.mov"),
      source: .init(kind: .display, displayID: 1, windowID: nil)
    )
    project.visualMasks = [
      RecordingProject.VisualMask(
        id: maskID,
        startSeconds: 1,
        endSeconds: 3,
        kind: .blur
      ),
    ]
    project.cursorVisualSettings.showClickEffects = true
    project.cursorClickCues = [
      RecordingProject.CursorClickCue(id: clickID, timeSeconds: 2),
    ]

    let segments = EditorTimelineEffectSegment.segments(project: project, duration: 5)
    let mask = segments.first { $0.id == "mask-\(maskID.uuidString)-0" }
    let click = segments.first { $0.id == "click-\(clickID.uuidString)" }

    XCTAssertEqual(mask?.kind, .mask)
    XCTAssertEqual(mask?.selection, .mask(maskID))
    XCTAssertNil(click)
  }

  func testEditorTimelineEffectSegmentsKeepZoomVisibleDuringLiveDrag() {
    let zoomID = UUID()
    let captionID = UUID()
    let segments = [
      EditorTimelineEffectSegment(
        id: "zoom-\(zoomID.uuidString)",
        startSeconds: 0.8,
        endSeconds: 2.8,
        kind: .zoom,
        selection: .zoom(zoomID)
      ),
      EditorTimelineEffectSegment(
        id: "caption-\(captionID.uuidString)",
        startSeconds: 3,
        endSeconds: 4,
        kind: .caption,
        selection: .caption(captionID)
      ),
    ]
    let liveRange = TimelineEditableRange(
      id: zoomID,
      kind: .zoom,
      startSeconds: 1.1,
      endSeconds: 3.1,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let displayed = EditorTimelineEffectSegment.displayedSegments(segments, liveRange: liveRange)

    XCTAssertEqual(displayed.count, segments.count)
    XCTAssertEqual(displayed[0].id, segments[0].id)
    XCTAssertEqual(displayed[0].selection, .zoom(zoomID))
    XCTAssertEqual(displayed[0].kind, .zoom)
    XCTAssertEqual(displayed[0].startSeconds, 1.1, accuracy: 1e-9)
    XCTAssertEqual(displayed[0].endSeconds, 3.1, accuracy: 1e-9)
    XCTAssertEqual(displayed[1], segments[1])
  }

  func testEditorTimelineEffectSegmentsApplyLiveRangeOnlyToMatchingKind() {
    let sharedID = UUID()
    let segments = [
      EditorTimelineEffectSegment(
        id: "zoom-\(sharedID.uuidString)",
        startSeconds: 0.8,
        endSeconds: 2.8,
        kind: .zoom,
        selection: .zoom(sharedID)
      ),
      EditorTimelineEffectSegment(
        id: "caption-\(sharedID.uuidString)",
        startSeconds: 3,
        endSeconds: 4,
        kind: .caption,
        selection: .caption(sharedID)
      ),
    ]
    let liveRange = TimelineEditableRange(
      id: sharedID,
      kind: .zoom,
      startSeconds: 1.1,
      endSeconds: 3.1,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let displayed = EditorTimelineEffectSegment.displayedSegments(segments, liveRange: liveRange)

    XCTAssertEqual(displayed[0].startSeconds, 1.1, accuracy: 1e-9)
    XCTAssertEqual(displayed[0].endSeconds, 3.1, accuracy: 1e-9)
    XCTAssertEqual(displayed[1], segments[1])
  }

  func testEditorTimelineEffectSegmentsUseDeterministicOrderForOverlaps() {
    let zoomID = UUID()
    let captionID = UUID()
    let maskID = UUID()
    var project = RecordingProject.default(
      mediaURL: URL(fileURLWithPath: "/tmp/overlapping-effects.mov"),
      source: .init(kind: .display, displayID: 1, windowID: nil)
    )
    project.zoomSegments = [
      RecordingProject.ZoomSegment(
        id: zoomID,
        startSeconds: 1,
        endSeconds: 2,
        scale: 1.4,
        anchorX: 0.5,
        anchorY: 0.5
      )
    ]
    project.captionTrack.isEnabled = true
    project.captionTrack.segments = [
      RecordingProject.CaptionTrack.Segment(
        id: captionID,
        startSeconds: 1,
        endSeconds: 2,
        text: "caption"
      )
    ]
    project.visualMasks = [
      RecordingProject.VisualMask(
        id: maskID,
        startSeconds: 1,
        endSeconds: 2,
        kind: .highlight,
        originXN: 0.1,
        originYN: 0.1,
        widthN: 0.2,
        heightN: 0.2
      )
    ]

    let segments = EditorTimelineEffectSegment.segments(project: project, duration: 3)

    XCTAssertEqual(segments.map(\.selection), [.zoom(zoomID), .caption(captionID), .mask(maskID)])
  }

  func testEditorTimelineEffectSegmentsMapSourceRangesOntoMultiClipTimeline() {
    let zoomID = UUID()
    var project = RecordingProject.default(
      mediaURL: URL(fileURLWithPath: "/tmp/mapped-effects.mov"),
      source: .init(kind: .display, displayID: 1, windowID: nil)
    )
    project.timeline = RecordingProject.TimelineModel(clips: [
      RecordingProject.TimelineModel.Clip(
        sourceURL: URL(fileURLWithPath: "/tmp/mapped-effects.mov"),
        sourceStartSeconds: 2,
        timelineStartSeconds: 0,
        durationSeconds: 2
      ),
      RecordingProject.TimelineModel.Clip(
        sourceURL: URL(fileURLWithPath: "/tmp/mapped-effects.mov"),
        sourceStartSeconds: 8,
        timelineStartSeconds: 2,
        durationSeconds: 2
      ),
    ])
    project.zoomSegments = [
      RecordingProject.ZoomSegment(
        id: zoomID,
        startSeconds: 3,
        endSeconds: 9,
        scale: 1.4,
        anchorX: 0.5,
        anchorY: 0.5
      ),
    ]

    let segments = EditorTimelineEffectSegment.segments(project: project, duration: 4)

    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments.map(\.selection), [.zoom(zoomID), .zoom(zoomID)])
    XCTAssertEqual(segments[0].startSeconds, 1, accuracy: 1e-9)
    XCTAssertEqual(segments[0].endSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(segments[1].startSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(segments[1].endSeconds, 3, accuracy: 1e-9)
    XCTAssertNotEqual(segments[0].id, segments[1].id)
  }

  func testEditorTimelineEffectSegmentsKeepSingleClipInSourceCoordinates() {
    let zoomID = UUID()
    var project = RecordingProject.default(
      mediaURL: URL(fileURLWithPath: "/tmp/single-source-effects.mov"),
      source: .init(kind: .display, displayID: 1, windowID: nil)
    )
    project.timeline = RecordingProject.TimelineModel.singleClip(
      mediaURL: URL(fileURLWithPath: "/tmp/single-source-effects.mov"),
      sourceStartSeconds: 2,
      sourceEndSeconds: 8,
      assetDurationSeconds: 10
    )
    project.zoomSegments = [
      RecordingProject.ZoomSegment(
        id: zoomID,
        startSeconds: 3,
        endSeconds: 5,
        scale: 1.4,
        anchorX: 0.5,
        anchorY: 0.5
      ),
    ]

    let segments = EditorTimelineEffectSegment.segments(project: project, duration: 10)

    let segment = try! XCTUnwrap(segments.first)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segment.selection, .zoom(zoomID))
    XCTAssertEqual(segment.startSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(segment.endSeconds, 5, accuracy: 1e-9)
  }

  func testEditorTimelineEffectSegmentFrameStaysDrawableDuringLiveDrag() {
    let zoomID = UUID()
    let segments = [
      EditorTimelineEffectSegment(
        id: "zoom-\(zoomID.uuidString)",
        startSeconds: 0.8,
        endSeconds: 2.8,
        kind: .zoom,
        selection: .zoom(zoomID)
      ),
    ]
    let liveRange = TimelineEditableRange(
      id: zoomID,
      kind: .zoom,
      startSeconds: 1.1,
      endSeconds: 1.16,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let displayed = EditorTimelineEffectSegment.displayedSegments(segments, liveRange: liveRange)
    let frame = try! XCTUnwrap(displayed.first).timelineFrame(duration: 5, activeWidth: 500)

    XCTAssertTrue(frame.isDrawable)
    XCTAssertEqual(frame.x, EditorLayout.timelineLaneInsetX + 110, accuracy: 1e-9)
    XCTAssertEqual(frame.width, EditorLayout.timelineMinimumZoomEffectSegmentWidth, accuracy: 1e-9)
  }

  func testEditorTimelineEffectSegmentFrameKeepsMinimumWidthInsideLaneNearEnd() {
    let zoomID = UUID()
    let segment = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: 4.95,
      endSeconds: 5.0,
      kind: .zoom,
      selection: .zoom(zoomID)
    )

    let frame = segment.timelineFrame(duration: 5, activeWidth: 500)

    XCTAssertTrue(frame.isDrawable)
    XCTAssertEqual(frame.width, EditorLayout.timelineMinimumZoomEffectSegmentWidth, accuracy: 1e-9)
    XCTAssertEqual(frame.x + frame.width, EditorLayout.timelineLaneInsetX + 500, accuracy: 1e-9)
  }

  func testEditorTimelineEffectSegmentFrameTracksMoveDragBySamePixels() {
    let zoomID = UUID()
    let original = TimelineEditableRange(
      id: zoomID,
      kind: .zoom,
      startSeconds: 1,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let moved = original.applyingTimelineDrag(
      mode: .move,
      translationX: 120,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let originalSegment = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: original.startSeconds,
      endSeconds: original.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    )
    let movedSegment = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: moved.startSeconds,
      endSeconds: moved.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    )

    let originalFrame = originalSegment.timelineFrame(duration: 10, activeWidth: 1_000)
    let movedFrame = movedSegment.timelineFrame(duration: 10, activeWidth: 1_000)

    XCTAssertEqual(movedFrame.x - originalFrame.x, 120, accuracy: 1e-9)
    XCTAssertEqual(movedFrame.width, originalFrame.width, accuracy: 1e-9)
  }

  func testEditorTimelineEffectSegmentFrameKeepsTrimmedEdgeAnchoredToPixels() {
    let zoomID = UUID()
    let original = TimelineEditableRange(
      id: zoomID,
      kind: .zoom,
      startSeconds: 1,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let leadingTrimmed = original.applyingTimelineDrag(
      mode: .leading,
      translationX: 120,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let trailingTrimmed = original.applyingTimelineDrag(
      mode: .trailing,
      translationX: 120,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let originalFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: original.startSeconds,
      endSeconds: original.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)
    let leadingFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: leadingTrimmed.startSeconds,
      endSeconds: leadingTrimmed.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)
    let trailingFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: trailingTrimmed.startSeconds,
      endSeconds: trailingTrimmed.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)

    XCTAssertEqual(leadingFrame.x - originalFrame.x, 120, accuracy: 1e-9)
    XCTAssertEqual(leadingFrame.x + leadingFrame.width, originalFrame.x + originalFrame.width, accuracy: 1e-9)
    XCTAssertEqual(trailingFrame.x, originalFrame.x, accuracy: 1e-9)
    XCTAssertEqual(trailingFrame.width - originalFrame.width, 120, accuracy: 1e-9)
  }

  func testTrimmingZoomEffectShiftsRampBoundariesWithTrimmedEdges() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 1,
      inEndSeconds: 1.5,
      outStartSeconds: 2.5,
      endSeconds: 3,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let leadingTrimmed = range.trimmingLeading(to: 1.4, durationSeconds: 10)
    XCTAssertEqual(leadingTrimmed.startSeconds, 1.4, accuracy: 1e-9)
    XCTAssertEqual(leadingTrimmed.inEndSeconds ?? -1, 1.9, accuracy: 1e-9)
    XCTAssertEqual(leadingTrimmed.outStartSeconds ?? -1, 2.9, accuracy: 1e-9)
    XCTAssertEqual(leadingTrimmed.endSeconds, 3, accuracy: 1e-9)

    let trailingTrimmed = range.trimmingTrailing(to: 2.6, durationSeconds: 10)
    XCTAssertEqual(trailingTrimmed.endSeconds, 2.6, accuracy: 1e-9)
    XCTAssertEqual(trailingTrimmed.outStartSeconds ?? -1, 2.1, accuracy: 1e-9)
    XCTAssertEqual(trailingTrimmed.inEndSeconds ?? -1, 1.5, accuracy: 1e-9)
    XCTAssertEqual(trailingTrimmed.startSeconds, 1, accuracy: 1e-9)
  }

  func testTimelineZoomOverlapPolicyBlocksLeadingTrimIntoPeer() {
    let id = UUID()
    let range = TimelineEditableRange(
      id: id,
      kind: .zoom,
      startSeconds: 2.5,
      inEndSeconds: 2.8,
      outStartSeconds: 3.2,
      endSeconds: 3.5,
      minDuration: 0.2,
      canTrim: true,
      canMove: true
    )
    let peers = [TimelineZoomOverlapPolicy.Interval(start: 1, end: 2)]

    let resolved = TimelineZoomOverlapPolicy.resolve(
      range.trimmingLeading(to: 1.5, durationSeconds: 10),
      mode: .leading,
      peers: peers,
      totalDuration: 10
    )

    XCTAssertGreaterThanOrEqual(resolved.startSeconds, 2 - 1e-9)
    XCTAssertFalse(
      TimelineZoomOverlapPolicy.overlaps(resolved.startSeconds, resolved.endSeconds, with: peers[0])
    )
  }

  func testTimelineZoomOverlapPolicyDoesNotLeakOverlapWhenDensePeersBlockResolution() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 1.8,
      inEndSeconds: 2.1,
      outStartSeconds: 2.9,
      endSeconds: 3.2,
      minDuration: 0.2,
      canTrim: true,
      canMove: true
    )
    let peers = [
      TimelineZoomOverlapPolicy.Interval(start: 1, end: 2),
      TimelineZoomOverlapPolicy.Interval(start: 2.5, end: 3.5),
    ]

    let resolved = TimelineZoomOverlapPolicy.resolve(
      range,
      mode: .move,
      peers: peers,
      totalDuration: 10
    )

    XCTAssertGreaterThanOrEqual(resolved.startSeconds, 0 - 1e-9)
    XCTAssertLessThanOrEqual(resolved.endSeconds, 10 + 1e-9)
    XCTAssertGreaterThanOrEqual(resolved.endSeconds - resolved.startSeconds, range.minDuration - 1e-9)
    for peer in peers {
      XCTAssertFalse(TimelineZoomOverlapPolicy.overlaps(resolved.startSeconds, resolved.endSeconds, with: peer))
    }
  }

  func testMoveOverlapResolutionStaysOnApproachSideWhenDraggingLeftIntoPeer() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 1.5,
      inEndSeconds: 1.8,
      outStartSeconds: 3.2,
      endSeconds: 3.5,
      minDuration: 0.2,
      canTrim: true,
      canMove: true
    )
    let peers = [TimelineZoomOverlapPolicy.Interval(start: 2.11, end: 4.11)]

    let resolved = TimelineZoomOverlapPolicy.resolve(
      range,
      mode: .move,
      peers: peers,
      totalDuration: 10,
      moveReferenceStart: 4.11
    )

    XCTAssertEqual(resolved.startSeconds, 4.11, accuracy: 1e-9)
    XCTAssertFalse(
      TimelineZoomOverlapPolicy.overlaps(resolved.startSeconds, resolved.endSeconds, with: peers[0])
    )
  }

  func testEditorSegmentRangePlayheadBasedAvoidingZoomOverlapsUsesGapAfterPeer() {
    let peers = [TimelineZoomOverlapPolicy.Interval(start: 1, end: 3)]
    let range = EditorSegmentRange.playheadBasedAvoidingZoomOverlaps(
      at: 2,
      preferredDuration: 1,
      totalDuration: 10,
      minimumDuration: 0.2,
      peers: peers
    )

    XCTAssertNotNil(range)
    XCTAssertGreaterThanOrEqual(range?.start ?? 0, 3 - 1e-9)
    XCTAssertLessThanOrEqual(range?.end ?? 0, 10 + 1e-9)
  }

  func testTimelineEffectRowLayoutStacksOverlappingMaskSegments() {
    let segments = [
      EditorTimelineEffectSegment(
        id: "mask-a",
        startSeconds: 0,
        endSeconds: 3,
        kind: .mask,
        selection: nil
      ),
      EditorTimelineEffectSegment(
        id: "mask-b",
        startSeconds: 1,
        endSeconds: 4,
        kind: .mask,
        selection: nil
      ),
      EditorTimelineEffectSegment(
        id: "mask-c",
        startSeconds: 3.5,
        endSeconds: 5,
        kind: .mask,
        selection: nil
      ),
    ]

    let assignments = TimelineEffectRowLayout.assignments(for: segments)

    XCTAssertEqual(assignments["mask-a"], 0)
    XCTAssertEqual(assignments["mask-b"], 1)
    XCTAssertEqual(assignments["mask-c"], 0)
    XCTAssertEqual(TimelineEffectRowLayout.rowCount(for: segments), 2)
    XCTAssertEqual(
      EditorLayout.timelineMaskLaneHeight(rowCount: 2),
      EditorLayout.timelineEffectSegmentHeight * 2
        + EditorLayout.timelineMaskRowGap
        + EditorLayout.timelineMaskLaneVerticalPadding * 2,
      accuracy: 1e-6
    )
    XCTAssertEqual(
      EditorLayout.timelineMaskLaneHeight(rowCount: 23),
      EditorLayout.timelineMaskLaneHeight(rowCount: EditorLayout.timelineMaskLaneMaxRows),
      accuracy: 1e-6
    )
  }

  func testTimelineEffectRowLayoutCapsDisplayRowsForManyOverlappingMasks() {
    let segments = (0..<10).map { index in
      EditorTimelineEffectSegment(
        id: "mask-\(index)",
        startSeconds: 0,
        endSeconds: 2,
        kind: .mask,
        selection: nil
      )
    }
    let assignments = TimelineEffectRowLayout.assignments(
      for: segments,
      maxRows: EditorLayout.timelineMaskLaneMaxRows
    )

    XCTAssertEqual(assignments["mask-0"], 0)
    XCTAssertEqual(assignments["mask-3"], 3)
    XCTAssertEqual(assignments["mask-9"], 3)
    XCTAssertEqual(
      TimelineEffectRowLayout.displayRowCount(
        for: segments,
        maxRows: EditorLayout.timelineMaskLaneMaxRows
      ),
      EditorLayout.timelineMaskLaneMaxRows
    )
  }

  func testEditorTimelineEffectSegmentFrameStaysDrawableWhenDraggedBeyondBounds() {
    let zoomID = UUID()
    let original = TimelineEditableRange(
      id: zoomID,
      kind: .zoom,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let movedLeft = original.applyingTimelineDrag(
      mode: .move,
      translationX: -10_000,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let movedRight = original.applyingTimelineDrag(
      mode: .move,
      translationX: 10_000,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let leftFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: movedLeft.startSeconds,
      endSeconds: movedLeft.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)
    let rightFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: movedRight.startSeconds,
      endSeconds: movedRight.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)

    XCTAssertEqual(movedLeft.startSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(movedLeft.endSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(movedRight.startSeconds, 8, accuracy: 1e-9)
    XCTAssertEqual(movedRight.endSeconds, 10, accuracy: 1e-9)
    XCTAssertTrue(leftFrame.isDrawable)
    XCTAssertTrue(rightFrame.isDrawable)
    XCTAssertEqual(leftFrame.x, EditorLayout.timelineLaneInsetX, accuracy: 1e-9)
    XCTAssertEqual(rightFrame.x + rightFrame.width, EditorLayout.timelineLaneInsetX + 1_000, accuracy: 1e-9)
  }

  func testEditorTimelineEffectSegmentFrameStaysDrawableWhenTrimmedBeyondMinimum() {
    let zoomID = UUID()
    let original = TimelineEditableRange(
      id: zoomID,
      kind: .zoom,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )

    let leading = original.applyingTimelineDrag(
      mode: .leading,
      translationX: 10_000,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let trailing = original.applyingTimelineDrag(
      mode: .trailing,
      translationX: -10_000,
      timelineDurationSeconds: 10,
      activeWidth: 1_000,
      durationSeconds: 10
    )
    let leadingFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: leading.startSeconds,
      endSeconds: leading.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)
    let trailingFrame = EditorTimelineEffectSegment(
      id: "zoom-\(zoomID.uuidString)",
      startSeconds: trailing.startSeconds,
      endSeconds: trailing.endSeconds,
      kind: .zoom,
      selection: .zoom(zoomID)
    ).timelineFrame(duration: 10, activeWidth: 1_000)

    XCTAssertEqual(leading.endSeconds - leading.startSeconds, 0.05, accuracy: 1e-9)
    XCTAssertEqual(trailing.endSeconds - trailing.startSeconds, 0.05, accuracy: 1e-9)
    XCTAssertTrue(leadingFrame.isDrawable)
    XCTAssertTrue(trailingFrame.isDrawable)
    XCTAssertEqual(leadingFrame.width, EditorLayout.timelineMinimumZoomEffectSegmentWidth, accuracy: 1e-9)
    XCTAssertEqual(trailingFrame.width, EditorLayout.timelineMinimumZoomEffectSegmentWidth, accuracy: 1e-9)
  }

  func testEditorTimelineEffectSelectionRemovesSelectedEffect() {
    let zoomID = UUID()
    let captionID = UUID()
    let maskID = UUID()
    var project = RecordingProject.default(
      mediaURL: URL(fileURLWithPath: "/tmp/remove-effect.mov"),
      source: .init(kind: .display, displayID: 1, windowID: nil)
    )
    project.zoomSegments = [
      RecordingProject.ZoomSegment(
        id: zoomID,
        startSeconds: 0,
        endSeconds: 1,
        scale: 1.4,
        anchorX: 0.5,
        anchorY: 0.5
      ),
    ]
    project.captionTrack = RecordingProject.CaptionTrack(
      isEnabled: true,
      segments: [
        RecordingProject.CaptionTrack.Segment(
          id: captionID,
          startSeconds: 1,
          endSeconds: 2,
          text: "caption"
        ),
      ]
    )
    project.visualMasks = [
      RecordingProject.VisualMask(
        id: maskID,
        startSeconds: 2,
        endSeconds: 3,
        kind: .highlight
      ),
    ]

    XCTAssertTrue(EditorTimelineEffectSelection.remove(.zoom(zoomID), from: &project, durationSeconds: 4))
    XCTAssertTrue(project.zoomSegments.isEmpty)

    XCTAssertTrue(EditorTimelineEffectSelection.remove(.caption(captionID), from: &project, durationSeconds: 4))
    XCTAssertTrue(project.captionTrack.segments.isEmpty)

    XCTAssertTrue(EditorTimelineEffectSelection.remove(.mask(maskID), from: &project, durationSeconds: 4))
    XCTAssertTrue(project.visualMasks.isEmpty)
  }

  func testTimelineEditingSplitsDeletesAndMapsTime() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(
      mediaURL: mediaURL,
      sourceStartSeconds: 2,
      sourceEndSeconds: 8,
      assetDurationSeconds: 10
    )

    XCTAssertEqual(timeline.activeClips.count, 1)
    XCTAssertEqual(timeline.activeClips[0].sourceStartSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(timeline.activeClips[0].durationSeconds, 6, accuracy: 1e-9)

    let secondID = timeline.splitClip(atTimelineSeconds: 2.5)
    XCTAssertNotNil(secondID)
    XCTAssertEqual(timeline.activeClips.count, 2)
    XCTAssertEqual(timeline.activeClips[0].durationSeconds, 2.5, accuracy: 1e-9)
    XCTAssertEqual(timeline.activeClips[1].sourceStartSeconds, 4.5, accuracy: 1e-9)

    XCTAssertEqual(try! XCTUnwrap(timeline.timelineSeconds(forSourceSeconds: 5).first), 3, accuracy: 1e-9)
    XCTAssertEqual(try! XCTUnwrap(timeline.sourceSeconds(forTimelineSeconds: 3)), 5, accuracy: 1e-9)

    XCTAssertTrue(timeline.deleteClip(id: timeline.activeClips[0].id))
    XCTAssertEqual(timeline.activeClips.count, 1)
    XCTAssertEqual(timeline.activeClips[0].timelineStartSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(timeline.activeClips[0].sourceStartSeconds, 4.5, accuracy: 1e-9)
  }

  func testTimelineEditingSplitsSpeedClipUsingSourceDuration() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-speed-split.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(mediaURL: mediaURL, assetDurationSeconds: 8)
    let clipID = try! XCTUnwrap(timeline.singleEditableClip?.id)
    XCTAssertTrue(timeline.setSpeed(rate: 2, forClipID: clipID))

    XCTAssertNotNil(timeline.splitClip(atTimelineSeconds: 1.5))

    XCTAssertEqual(timeline.activeClips.count, 2)
    XCTAssertEqual(timeline.activeClips[0].durationSeconds, 1.5, accuracy: 1e-9)
    XCTAssertEqual(timeline.activeClips[1].sourceStartSeconds, 3, accuracy: 1e-9)
  }

  func testTimelineEditingMoveClipReordersGaplessAndPreservesSpeed() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-move.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(mediaURL: mediaURL, assetDurationSeconds: 9)
    let firstID = try! XCTUnwrap(timeline.activeClips.first?.id)
    let secondID = try! XCTUnwrap(timeline.splitClip(atTimelineSeconds: 3))
    let thirdID = try! XCTUnwrap(timeline.splitClip(atTimelineSeconds: 6))
    XCTAssertTrue(timeline.setSpeed(rate: 2, forClipID: secondID))

    XCTAssertTrue(timeline.moveClip(id: thirdID, toIndex: 0))

    let clips = timeline.activeClips
    XCTAssertEqual(clips.map(\.id), [thirdID, firstID, secondID])
    XCTAssertEqual(clips[0].timelineStartSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(clips[1].timelineStartSeconds, clips[0].durationSeconds, accuracy: 1e-9)
    XCTAssertEqual(clips[2].timelineStartSeconds, clips[0].durationSeconds + clips[1].durationSeconds, accuracy: 1e-9)
    XCTAssertEqual(timeline.speedRate(for: clips[2]), 2, accuracy: 1e-9)
  }

  func testSingleClipBoundsMigrateLegacyTrimAndClampEdges() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-bounds.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(
      mediaURL: mediaURL,
      sourceStartSeconds: 2,
      sourceEndSeconds: 8,
      assetDurationSeconds: 10
    )

    var clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 6, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSingleClipLeadingSourceSeconds(3.25, assetDurationSeconds: 10))
    clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 3.25, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 4.75, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSingleClipTrailingSourceSeconds(6.5, assetDurationSeconds: 10))
    clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 3.25, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 3.25, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSingleClipLeadingSourceSeconds(6.49, assetDurationSeconds: 10))
    clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 6.4, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 0.1, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSingleClipTrailingSourceSeconds(12, assetDurationSeconds: 10))
    clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 6.4, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 3.6, accuracy: 1e-9)
  }

  func testSingleClipBoundsPreserveSpeedMapping() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-speed-bounds.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(mediaURL: mediaURL, assetDurationSeconds: 8)
    let clipID = try! XCTUnwrap(timeline.singleEditableClip?.id)
    XCTAssertTrue(timeline.setSpeed(rate: 2, forClipID: clipID))

    XCTAssertTrue(timeline.setSingleClipLeadingSourceSeconds(2, assetDurationSeconds: 8))
    var clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(timeline.sourceDurationForClip(clip), 6, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSingleClipTrailingSourceSeconds(6, assetDurationSeconds: 8))
    clip = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clip.sourceStartSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(clip.durationSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(timeline.sourceRange(for: clip).startSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(timeline.sourceRange(for: clip).endSeconds, 6, accuracy: 1e-9)
    XCTAssertEqual(timeline.previewSeconds(forSourceSeconds: 5, in: clip), 1.5, accuracy: 1e-9)
    XCTAssertEqual(timeline.sourceSeconds(forPreviewSeconds: 1.5, in: clip), 5, accuracy: 1e-9)
    XCTAssertEqual(timeline.displayRange(for: clip, mode: .singleSource).durationSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(timeline.displayRange(for: clip, mode: .timeline).durationSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(try! XCTUnwrap(timeline.speedSegments.first?.rate), 2, accuracy: 1e-9)
    XCTAssertEqual(try! XCTUnwrap(timeline.sourceSeconds(forTimelineSeconds: 1.5)), 5, accuracy: 1e-9)
  }

  func testKeyboardTrimInEquivalentMovesSingleClipLeadingBoundaryToPlayheadSourceTime() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-keyboard-in.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(mediaURL: mediaURL, assetDurationSeconds: 8)
    let clipID = try! XCTUnwrap(timeline.singleEditableClip?.id)
    XCTAssertTrue(timeline.setSpeed(rate: 2, forClipID: clipID))
    let clipBefore = try! XCTUnwrap(timeline.singleEditableClip)
    let playheadSourceSeconds = timeline.sourceSeconds(forPreviewSeconds: 1.5, in: clipBefore)

    XCTAssertTrue(timeline.setSingleClipLeadingSourceSeconds(playheadSourceSeconds, assetDurationSeconds: 8))

    let clipAfter = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(clipAfter.sourceStartSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(timeline.sourceRange(for: clipAfter).endSeconds, 8, accuracy: 1e-9)
    XCTAssertEqual(clipAfter.durationSeconds, 2.5, accuracy: 1e-9)
  }

  func testKeyboardTrimOutEquivalentMovesSingleClipTrailingBoundaryToPlayheadSourceTimeAndClampsMinimum() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-keyboard-out.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(mediaURL: mediaURL, assetDurationSeconds: 8)
    let clipID = try! XCTUnwrap(timeline.singleEditableClip?.id)
    XCTAssertTrue(timeline.setSpeed(rate: 2, forClipID: clipID))
    let clipBefore = try! XCTUnwrap(timeline.singleEditableClip)
    let playheadSourceSeconds = timeline.sourceSeconds(forPreviewSeconds: 1.5, in: clipBefore)

    XCTAssertTrue(timeline.setSingleClipTrailingSourceSeconds(playheadSourceSeconds, assetDurationSeconds: 8))

    var clipAfter = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(timeline.sourceRange(for: clipAfter).endSeconds, 3, accuracy: 1e-9)
    XCTAssertEqual(clipAfter.durationSeconds, 1.5, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSingleClipTrailingSourceSeconds(0.01, assetDurationSeconds: 8))
    clipAfter = try! XCTUnwrap(timeline.singleEditableClip)
    XCTAssertEqual(timeline.sourceRange(for: clipAfter).endSeconds, 0.2, accuracy: 1e-9)
    XCTAssertEqual(clipAfter.durationSeconds, 0.1, accuracy: 1e-9)
  }

  func testPlaybackPreviewRangeMapsPreviewSecondsToSourceSeconds() {
    let range = PlaybackPreviewRange(sourceStartSeconds: 2, sourceEndSeconds: 6)

    XCTAssertEqual(range.durationSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(range.sourceSeconds(forPreviewSeconds: 0), 2, accuracy: 1e-9)
    XCTAssertEqual(range.sourceSeconds(forPreviewSeconds: 1.5), 3.5, accuracy: 1e-9)
    XCTAssertEqual(range.sourceSeconds(forPreviewSeconds: 10), 6, accuracy: 1e-9)
    XCTAssertEqual(range.previewSeconds(forSourceSeconds: 1), 0, accuracy: 1e-9)
    XCTAssertEqual(range.previewSeconds(forSourceSeconds: 4.25), 2.25, accuracy: 1e-9)
    XCTAssertEqual(range.previewSeconds(forSourceSeconds: 7), 4, accuracy: 1e-9)
  }

  func testPlaybackPreviewRangeHonorsSingleClipSpeed() {
    let range = PlaybackPreviewRange(sourceStartSeconds: 2, sourceEndSeconds: 6, playbackRate: 2)

    XCTAssertEqual(range.durationSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(range.sourceSeconds(forPreviewSeconds: 1.5), 5, accuracy: 1e-9)
    XCTAssertEqual(range.previewSeconds(forSourceSeconds: 5), 1.5, accuracy: 1e-9)
  }

  func testTimelinePlayheadHitTargetAcceptsVisibleLineAcrossTrackHeight() {
    let bounds = CGRect(x: 0, y: 0, width: 420, height: 180)
    let x = EditorTimelinePlayheadHitTarget.contentX(
      forDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    )
    let upperTrackY = (
      bounds.height
        - EditorLayout.timelineMaskLaneMinHeight
        - EditorLayout.timelineLaneGap
        - EditorLayout.timelineEffectLaneHeight
    ) / 2

    XCTAssertTrue(EditorTimelinePlayheadHitTarget.contains(
      point: CGPoint(x: x + 2, y: upperTrackY),
      bounds: bounds,
      currentDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    ))
    XCTAssertFalse(EditorTimelinePlayheadHitTarget.contains(
      point: CGPoint(x: x + EditorLayout.timelinePlayheadGhostHitWidth, y: upperTrackY),
      bounds: bounds,
      currentDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    ))
  }

  func testTimelinePlayheadHitTargetLetsEffectLaneReceiveClicks() {
    let bounds = CGRect(x: 0, y: 0, width: 420, height: 180)
    let x = EditorTimelinePlayheadHitTarget.contentX(
      forDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    )
    let effectLaneCenterY = bounds.height
      - EditorLayout.timelineMaskLaneMinHeight
      - EditorLayout.timelineLaneGap
      - EditorLayout.timelineEffectLaneHeight / 2

    XCTAssertFalse(EditorTimelinePlayheadHitTarget.contains(
      point: CGPoint(x: x + 2, y: effectLaneCenterY),
      bounds: bounds,
      currentDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    ))
  }

  func testTimelinePlayheadHitTargetLetsMaskLaneReceiveClicks() {
    let bounds = CGRect(x: 0, y: 0, width: 420, height: 180)
    let x = EditorTimelinePlayheadHitTarget.contentX(
      forDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    )
    let maskLaneCenterY = bounds.height - EditorLayout.timelineMaskLaneMinHeight / 2

    XCTAssertFalse(EditorTimelinePlayheadHitTarget.contains(
      point: CGPoint(x: x + 2, y: maskLaneCenterY),
      bounds: bounds,
      currentDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    ))
  }

  func testTimelinePlayheadHitTargetAcceptsTopSeekBand() {
    XCTAssertTrue(EditorTimelinePlayheadHitTarget.contains(
      point: CGPoint(x: EditorLayout.timelineLaneInsetX + 120, y: 8),
      bounds: CGRect(x: 0, y: 0, width: 420, height: 180),
      currentDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300
    ))
  }

  func testTimelinePlayheadHitTargetAcceptsRulerBelowPlayheadLabel() {
    XCTAssertTrue(EditorTimelinePlayheadHitTarget.contains(
      point: CGPoint(
        x: EditorLayout.timelineLaneInsetX + 120,
        y: EditorLayout.timelinePlayheadGhostLabelHeight + EditorLayout.timelineRulerHeight - 1
      ),
      bounds: CGRect(x: 0, y: 0, width: 420, height: 180 + EditorLayout.timelinePlayheadGhostLabelHeight),
      currentDisplaySeconds: 4,
      durationSeconds: 10,
      activeWidth: 300,
      topHitInsetY: EditorLayout.timelinePlayheadGhostLabelHeight
    ))
  }

  func testPreviewZoomPresentationSuppressesEditingChromeWhilePlaying() {
    let id = UUID()

    XCTAssertFalse(EditorPreviewZoomPresentation.allowsImplicitAnimation(
      isPlaying: true,
      hasLivePreviewRange: false
    ))
    XCTAssertFalse(EditorPreviewZoomPresentation.allowsImplicitAnimation(
      isPlaying: false,
      hasLivePreviewRange: true
    ))
    XCTAssertTrue(EditorPreviewZoomPresentation.allowsImplicitAnimation(
      isPlaying: false,
      hasLivePreviewRange: false
    ))

    XCTAssertFalse(EditorPreviewZoomPresentation.showsTargetOverlay(isPlaying: true, selectedZoomID: id))
    XCTAssertTrue(EditorPreviewZoomPresentation.showsTargetOverlay(isPlaying: false, selectedZoomID: id))
    XCTAssertFalse(EditorPreviewZoomPresentation.showsTargetOverlay(isPlaying: false, selectedZoomID: nil))
  }

  func testPreviewPlaybackTimeClampsToDisplayedDuration() {
    XCTAssertEqual(EditorPreviewPlaybackTime.clamped(currentSeconds: 10.16, durationSeconds: 10), 10)
    XCTAssertEqual(EditorPreviewPlaybackTime.clamped(currentSeconds: -0.5, durationSeconds: 10), 0)
    XCTAssertEqual(EditorPreviewPlaybackTime.clamped(currentSeconds: .infinity, durationSeconds: 10), 0)
    XCTAssertEqual(EditorPreviewPlaybackTime.clamped(currentSeconds: 2, durationSeconds: .nan), 0)
  }

  func testCursorRendererClickPulseProgressUsesPostClickWindow() {
    let cue = RecordingProject.CursorClickCue(timeSeconds: 1)

    XCTAssertNil(CursorRenderer.clickPulseProgress(at: 0.999, clickCues: [cue]))
    XCTAssertEqual(Double(CursorRenderer.clickPulseProgress(at: 1, clickCues: [cue]) ?? -1), 0, accuracy: 1e-9)
    XCTAssertEqual(Double(CursorRenderer.clickPulseProgress(at: 1.11, clickCues: [cue]) ?? -1), 0.5, accuracy: 1e-9)
    XCTAssertNil(CursorRenderer.clickPulseProgress(at: 1.221, clickCues: [cue]))
  }

  func testCursorRendererDrawsPrimaryCursorShapes() throws {
    for shape in RecordingProject.CursorShape.allCases {
      let luminance = try renderedCursorMaximumLuminance(shape: shape)
      XCTAssertGreaterThan(luminance, 80, "\(shape) should render visible cursor pixels.")
    }
  }

  private func renderedCursorMaximumLuminance(shape: RecordingProject.CursorShape) throws -> Double {
    let width = 96
    let height = 96
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
      throw NSError(domain: "ArcShotTests", code: 1)
    }

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CursorRenderer(sizeScale: 1.4, pointerStyle: .arrow).drawCursor(
      in: context,
      at: CGPoint(x: 48, y: 48),
      shape: shape
    )

    var maximum = 0.0
    for y in 0 ..< height {
      for x in 0 ..< width {
        let offset = y * bytesPerRow + x * bytesPerPixel
        let red = Double(pixels[offset])
        let green = Double(pixels[offset + 1])
        let blue = Double(pixels[offset + 2])
        maximum = max(maximum, 0.2126 * red + 0.7152 * green + 0.0722 * blue)
      }
    }
    return maximum
  }

  func testPreviewClickPulseUsesRendererPostClickSemantics() throws {
    let clickID = UUID()
    let cue = RecordingProject.CursorClickCue(id: clickID, timeSeconds: 1)

    XCTAssertNil(EditorPreviewClickPulse.activeCue(
      at: 0.999,
      clickCues: [cue],
      showsClickEffects: true
    ))
    XCTAssertEqual(EditorPreviewClickPulse.activeCue(
      at: 1,
      clickCues: [cue],
      showsClickEffects: true
    )?.id, clickID)
    XCTAssertEqual(EditorPreviewClickPulse.activeCue(
      at: 1.11,
      clickCues: [cue],
      showsClickEffects: true
    )?.id, clickID)
    XCTAssertNil(EditorPreviewClickPulse.activeCue(
      at: 1.221,
      clickCues: [cue],
      showsClickEffects: true
    ))
    XCTAssertNil(EditorPreviewClickPulse.activeCue(
      at: 1,
      clickCues: [cue],
      showsClickEffects: false
    ))
  }

  func testPreviewClickPulsePositionsAtCurrentCursorTime() {
    XCTAssertEqual(
      EditorPreviewClickPulse.pulseCursorTimeSeconds(currentSourceTimeSeconds: 1.11),
      1.11,
      accuracy: 1e-9
    )
  }

  func testPreviewPlaybackSourceTimeUsesSingleClipMappingForOverlays() {
    let mediaURL = URL(fileURLWithPath: "/tmp/overlay-source-time.mov")
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Overlay source time",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: mediaURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      timeline: RecordingProject.TimelineModel(clips: [
        RecordingProject.TimelineModel.Clip(
          sourceURL: mediaURL,
          sourceStartSeconds: 4,
          timelineStartSeconds: 0,
          durationSeconds: 2
        ),
      ])
    )

    XCTAssertEqual(project.sourceSecondsForPreviewPlayback(0), 4, accuracy: 1e-9)
    XCTAssertEqual(project.sourceSecondsForPreviewPlayback(1.25), 5.25, accuracy: 1e-9)
  }

  func testPreviewPlaybackSourceTimeUsesTimelineClipMappingForOverlays() {
    let mediaURL = URL(fileURLWithPath: "/tmp/overlay-bounds-time.mov")
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Timeline clip overlay source time",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: mediaURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      timeline: RecordingProject.TimelineModel.singleClip(
        mediaURL: mediaURL,
        sourceStartSeconds: 3,
        sourceEndSeconds: 8
      )
    )

    XCTAssertEqual(project.sourceSecondsForPreviewPlayback(0), 3, accuracy: 1e-9)
    XCTAssertEqual(project.sourceSecondsForPreviewPlayback(2.5), 5.5, accuracy: 1e-9)
  }

  func testTimelineEditingSpeedChangesTimelineDurationWithoutLosingSourceDuration() {
    let mediaURL = URL(fileURLWithPath: "/tmp/timeline-speed.mov")
    var timeline = RecordingProject.TimelineModel()
    timeline.ensureSingleEditableClip(mediaURL: mediaURL, assetDurationSeconds: 8)

    let clipID = try! XCTUnwrap(timeline.activeClips.first?.id)
    XCTAssertTrue(timeline.setSpeed(rate: 2, forClipID: clipID))

    let clip = try! XCTUnwrap(timeline.activeClips.first)
    XCTAssertEqual(clip.durationSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(timeline.sourceDurationForClip(clip), 8, accuracy: 1e-9)
    XCTAssertEqual(try! XCTUnwrap(timeline.speedSegments.first?.rate), 2, accuracy: 1e-9)
    XCTAssertEqual(try! XCTUnwrap(timeline.sourceSeconds(forTimelineSeconds: 3)), 6, accuracy: 1e-9)

    XCTAssertTrue(timeline.setSpeed(rate: 1, forClipID: clipID))
    XCTAssertTrue(timeline.speedSegments.isEmpty)
    XCTAssertEqual(try! XCTUnwrap(timeline.activeClips.first?.durationSeconds), 8, accuracy: 1e-9)
  }

  func testPreviewZoomKeyframeUsesTimelineSourceMapping() {
    let mediaURL = URL(fileURLWithPath: "/tmp/source.mov")
    let zoomID = UUID()
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Timeline zoom preview",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: mediaURL,
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      timeline: RecordingProject.TimelineModel(clips: [
        RecordingProject.TimelineModel.Clip(
          sourceURL: mediaURL,
          sourceStartSeconds: 4,
          timelineStartSeconds: 0,
          durationSeconds: 2
        ),
      ]),
      zoomSegments: [
        RecordingProject.ZoomSegment(
          id: zoomID,
          startSeconds: 4.5,
          endSeconds: 5.5,
          scale: 1.8,
          anchorX: 0.25,
          anchorY: 0.75
        ),
      ]
    )

    XCTAssertNil(project.activePreviewZoomKeyframe(atPlaybackSeconds: 0.25))
    let active = project.activePreviewZoomKeyframe(atPlaybackSeconds: 0.75)
    XCTAssertEqual(active?.id, zoomID)
    XCTAssertEqual(active?.scale ?? 0, 1.8, accuracy: 1e-9)
    XCTAssertNil(project.activePreviewZoomKeyframe(atPlaybackSeconds: 1.75))
  }

  func testTimelineEditableRangeLeadingTrimKeepsEndAndMinimumDuration() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.5,
      canTrim: true,
      canMove: true
    )

    let trimmed = range.trimmingLeading(to: 3.8, durationSeconds: 10)

    XCTAssertEqual(trimmed.startSeconds, 3.5, accuracy: 1e-9)
    XCTAssertEqual(trimmed.endSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(trimmed.durationSeconds, 0.5, accuracy: 1e-9)
  }

  func testTimelineEditableRangeTrailingTrimKeepsStartAndMinimumDuration() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.5,
      canTrim: true,
      canMove: true
    )

    let trimmed = range.trimmingTrailing(to: 2.1, durationSeconds: 10)

    XCTAssertEqual(trimmed.startSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(trimmed.endSeconds, 2.5, accuracy: 1e-9)
    XCTAssertEqual(trimmed.durationSeconds, 0.5, accuracy: 1e-9)
  }

  func testTimelineEditableRangeMoveKeepsDurationAndClampsToBounds() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 2,
      endSeconds: 4,
      minDuration: 0.5,
      canTrim: true,
      canMove: true
    )

    let movedLeft = range.moving(by: -10, durationSeconds: 6)
    let movedRight = range.moving(by: 10, durationSeconds: 6)

    XCTAssertEqual(movedLeft.startSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(movedLeft.endSeconds, 2, accuracy: 1e-9)
    XCTAssertEqual(movedRight.startSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(movedRight.endSeconds, 6, accuracy: 1e-9)
  }

  func testTimelineEditableRangeDurationResizeKeepsStartAndClampsEnd() {
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 4,
      endSeconds: 5,
      minDuration: 0.5,
      canTrim: true,
      canMove: true
    )

    let resizedShort = range.resizingDuration(to: 0.1, durationSeconds: 10)
    let resizedLong = range.resizingDuration(to: 20, durationSeconds: 6)

    XCTAssertEqual(resizedShort.startSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(resizedShort.endSeconds, 4.5, accuracy: 1e-9)
    XCTAssertEqual(resizedLong.startSeconds, 4, accuracy: 1e-9)
    XCTAssertEqual(resizedLong.endSeconds, 6, accuracy: 1e-9)
  }

  func testZoomRangeCommitKeepsSegmentsAndKeyframesSynchronized() {
    let zoomID = UUID()
    var project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Zoom range commit",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: URL(fileURLWithPath: "/tmp/zoom-range.mov"),
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      zoomSegments: [
        RecordingProject.ZoomSegment(
          id: zoomID,
          startSeconds: 1,
          endSeconds: 2,
          scale: 1.4,
          anchorX: 0.5,
          anchorY: 0.5
        ),
      ]
    )

    project.zoomSegments[0].startSeconds = 2
    project.zoomSegments[0].inEndSeconds = 2.35
    project.zoomSegments[0].outStartSeconds = 3.65
    project.zoomSegments[0].endSeconds = 4
    project.zoomSegments = RecordingProject.sanitizedZoomSegments(project.zoomSegments, durationSeconds: 6)

    XCTAssertEqual(project.zoomSegments.count, 1)
    XCTAssertEqual(project.zoomSegments.first?.id, zoomID)
    XCTAssertEqual(project.zoomSegments.first?.startSeconds ?? 0, 2, accuracy: 1e-9)
    XCTAssertEqual(project.zoomSegments.first?.inEndSeconds ?? 0, 2.35, accuracy: 1e-9)
    XCTAssertEqual(project.zoomSegments.first?.outStartSeconds ?? 0, 3.65, accuracy: 1e-9)
    XCTAssertEqual(project.zoomSegments.first?.endSeconds ?? 0, 4, accuracy: 1e-9)
  }

  func testCaptionRangeCommitKeepsTextAndClampsRange() {
    let captionID = UUID()
    var project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Caption range commit",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: URL(fileURLWithPath: "/tmp/caption-range.mov"),
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none
    )
    project.captionTrack = RecordingProject.CaptionTrack(
      isEnabled: true,
      transcript: "hello",
      languageIdentifier: "en-US",
      segments: [
        RecordingProject.CaptionTrack.Segment(
          id: captionID,
          startSeconds: 1,
          endSeconds: 2,
          text: "hello"
        ),
      ]
    )

    let range = TimelineEditableRange(
      id: captionID,
      kind: .caption,
      startSeconds: 4.9,
      endSeconds: 4.91,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    .sanitized(durationSeconds: 5)
    project.captionTrack.segments[0].startSeconds = range.startSeconds
    project.captionTrack.segments[0].endSeconds = range.endSeconds

    XCTAssertEqual(project.captionTrack.segments.first?.id, captionID)
    XCTAssertEqual(project.captionTrack.segments.first?.text, "hello")
    XCTAssertEqual(project.captionTrack.segments.first?.startSeconds ?? 0, 4.9, accuracy: 1e-9)
    XCTAssertEqual(project.captionTrack.segments.first?.endSeconds ?? 0, 4.95, accuracy: 1e-9)
  }

  func testMaskRangeCommitKeepsGeometryAndSanitizesRange() {
    let maskID = UUID()
    var project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Mask range commit",
      source: .init(kind: .display, displayID: 1, windowID: nil),
      mediaURL: URL(fileURLWithPath: "/tmp/mask-range.mov"),
      cursorSamples: [],
      exportPreset: .p720p30,
      stylePreset: .none,
      visualMasks: [
        RecordingProject.VisualMask(
          id: maskID,
          startSeconds: 1,
          endSeconds: 2,
          kind: .highlight,
          originXN: 0.2,
          originYN: 0.3,
          widthN: 0.4,
          heightN: 0.5,
          opacity: 0.8
        ),
      ]
    )

    project.visualMasks[0].startSeconds = 4.95
    project.visualMasks[0].endSeconds = 4.96
    project.visualMasks = RecordingProject.sanitizedVisualMasks(project.visualMasks, durationSeconds: 5)

    XCTAssertEqual(project.visualMasks.first?.id, maskID)
    XCTAssertEqual(project.visualMasks.first?.originXN ?? 0, 0.2, accuracy: 1e-9)
    XCTAssertEqual(project.visualMasks.first?.originYN ?? 0, 0.3, accuracy: 1e-9)
    XCTAssertEqual(project.visualMasks.first?.widthN ?? 0, 0.4, accuracy: 1e-9)
    XCTAssertEqual(project.visualMasks.first?.heightN ?? 0, 0.5, accuracy: 1e-9)
    XCTAssertEqual(project.visualMasks.first?.opacity ?? 0, 0.8, accuracy: 1e-9)
    XCTAssertEqual(project.visualMasks.first?.startSeconds ?? 0, 4.95, accuracy: 1e-9)
    XCTAssertEqual(project.visualMasks.first?.endSeconds ?? 0, 5, accuracy: 1e-9)
  }

}

private struct StubCaptionEngine: CaptionEngine {
  var result: Result<CaptionGenerationResult, Error>

  func generate(url _: URL, localeIdentifier _: String) async throws -> CaptionGenerationResult {
    try result.get()
  }
}

private extension JSONEncoder {
  static var iso8601Test: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private extension JSONDecoder {
  static var iso8601Test: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

// MARK: - TimelineAudioWaveformLoader.assembleBins

extension ArcShotTests {

  func testAssembleBinsSingleSegmentFillsCorrectRange() {
    let peaks: [Float] = [0.5, 1.0, 0.3]
    let result = TimelineAudioWaveformLoader.assembleBins(
      segments: [(timelineStart: 0, duration: 3, peaks: peaks)],
      totalDuration: 6,
      bins: 6
    )
    XCTAssertEqual(result.count, 6)
    XCTAssertGreaterThan(result[0], 0)
    XCTAssertGreaterThan(result[1], 0)
    XCTAssertGreaterThan(result[2], 0)
    XCTAssertEqual(result[3], 0)
    XCTAssertEqual(result[4], 0)
    XCTAssertEqual(result[5], 0)
  }

  func testAssembleBinsTwoSegmentsWithGap() {
    let result = TimelineAudioWaveformLoader.assembleBins(
      segments: [
        (timelineStart: 0, duration: 2, peaks: [0.8, 0.6]),
        (timelineStart: 4, duration: 2, peaks: [0.4, 0.9]),
      ],
      totalDuration: 6,
      bins: 6
    )
    XCTAssertEqual(result.count, 6)
    XCTAssertGreaterThan(result[0], 0, "First segment start")
    XCTAssertGreaterThan(result[1], 0, "First segment end")
    XCTAssertEqual(result[2], 0, "Gap")
    XCTAssertEqual(result[3], 0, "Gap")
    XCTAssertGreaterThan(result[4], 0, "Second segment start")
    XCTAssertGreaterThan(result[5], 0, "Second segment end")
  }

  func testAssembleBinsEmptyInputsReturnEmpty() {
    XCTAssertTrue(TimelineAudioWaveformLoader.assembleBins(segments: [], totalDuration: 5, bins: 10).isEmpty)
    XCTAssertTrue(TimelineAudioWaveformLoader.assembleBins(segments: [], totalDuration: 0, bins: 10).isEmpty)
    XCTAssertTrue(TimelineAudioWaveformLoader.assembleBins(
      segments: [(timelineStart: 0, duration: 1, peaks: [0.5])],
      totalDuration: 5,
      bins: 0
    ).isEmpty)
  }

  func testAssembleBinsNormalizesToMaxPeak() {
    let result = TimelineAudioWaveformLoader.assembleBins(
      segments: [(timelineStart: 0, duration: 4, peaks: [0.2, 0.4])],
      totalDuration: 4,
      bins: 4
    )
    let maxVal = result.max() ?? 0
    XCTAssertEqual(maxVal, 1.0, accuracy: 1e-5, "Should normalize to 1.0")
  }
}
