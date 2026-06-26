import AppKit
import Foundation

struct ExportTimedDataPlan {
  var zoomKeyframes: [RecordingProject.ZoomKeyframe]
  var motionPlan: AutoZoomMotionPlan?
  var cursorSamples: [RecordingProject.CursorSample]
  var cursorHighlightRegions: [RecordingProject.CursorHighlightRegion]
  var textOverlays: [RecordingProject.TextOverlayAnnotation]
  var cursorClickCues: [RecordingProject.CursorClickCue]
  var visualMasks: [RecordingProject.VisualMask]
  var cameraLayoutSegments: [RecordingProject.CameraLayoutSegment]
}

/// Converts project-time metadata into the composition timeline consumed by the export compositor.
enum ExportTimedDataMapper {
  struct Input {
    var project: RecordingProject
    var motionResolution: AutoZoomMotionResolution
    var cursorSamples: [RecordingProject.CursorSample]
    var cursorHighlightRegions: [RecordingProject.CursorHighlightRegion]
    var exportStartSeconds: Double
    var effectiveExportDurationSeconds: Double
    var usesTimelineComposition: Bool
  }

  static func map(input: Input) -> ExportTimedDataPlan {
    let zoomKeyframes: [RecordingProject.ZoomKeyframe]
    let motionPlan: AutoZoomMotionPlan?
    if input.usesTimelineComposition {
      zoomKeyframes = RecordingProject.TimelineKeyframeSanitize.zoomFrames(
        mapZoomKeyframesForTimeline(input.motionResolution.zoomKeyframes, timeline: input.project.timeline),
        durationSeconds: input.effectiveExportDurationSeconds
      )
      motionPlan = input.motionResolution.motionPlan.map {
        AutoZoomMotionPlan(frames: mapMotionFramesForTimeline($0.frames, timeline: input.project.timeline))
      }
    } else {
      zoomKeyframes = RecordingProject.shiftZoomKeyframesForCompositionExport(
        input.motionResolution.zoomKeyframes,
        sourceStartSeconds: input.exportStartSeconds,
        compositionDurationSeconds: input.effectiveExportDurationSeconds
      )
      motionPlan = input.motionResolution.motionPlan.map {
        AutoZoomMotionPlan(frames: shiftMotionFramesForCompositionExport(
          $0.frames,
          sourceStartSeconds: input.exportStartSeconds,
          compositionDurationSeconds: input.effectiveExportDurationSeconds
        ))
      }
    }

    let timelineTextOverlays =
      input.project.textOverlayAnnotations
      + input.project.captionTrack.asTextOverlays()
      + keyboardShortcutOverlays(
        project: input.project,
        exportDurationSeconds: input.effectiveExportDurationSeconds
      )
    let mappedTextOverlays = input.usesTimelineComposition
      ? mapTextOverlaysForTimeline(timelineTextOverlays, timeline: input.project.timeline)
      : RecordingProject.shiftTextOverlaysForCompositionExport(
        timelineTextOverlays,
        sourceStartSeconds: input.exportStartSeconds
      )
    let textOverlays = RecordingProject.TextOverlaySanitizeDefaults.sanitized(
      mappedTextOverlays,
      durationSeconds: input.effectiveExportDurationSeconds
    )

    let fallbackClickCues = clickCuesFromInputEvents(input.project.inputEvents)
    let timelineClickCues = input.project.cursorClickCues.isEmpty ? fallbackClickCues : input.project.cursorClickCues
    let mappedClickCues = input.usesTimelineComposition
      ? mapClickCuesForTimeline(timelineClickCues, timeline: input.project.timeline)
      : RecordingProject.shiftClickCuesForCompositionExport(
        timelineClickCues,
        sourceStartSeconds: input.exportStartSeconds
      )
    let cursorClickCues = RecordingProject.clampedSortedClickCueTimes(
      input.project.cursorVisualSettings.showClickEffects
        ? mappedClickCues
        : [],
      compositionDurationSeconds: input.effectiveExportDurationSeconds
    )

    let mappedMasks = input.usesTimelineComposition
      ? mapVisualMasksForTimeline(input.project.visualMasks, timeline: input.project.timeline)
      : shiftVisualMasksForCompositionExport(
        input.project.visualMasks,
        sourceStartSeconds: input.exportStartSeconds
      )
    let visualMasks = RecordingProject.sanitizedVisualMasks(
      mappedMasks,
      durationSeconds: input.effectiveExportDurationSeconds
    )

    let mappedCameraSegments = input.usesTimelineComposition
      ? mapCameraLayoutSegmentsForTimeline(input.project.cameraLayoutSegments, timeline: input.project.timeline)
      : shiftCameraLayoutSegmentsForCompositionExport(
        input.project.cameraLayoutSegments,
        sourceStartSeconds: input.exportStartSeconds
      )
    let cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
      mappedCameraSegments,
      durationSeconds: input.effectiveExportDurationSeconds
    )

    let cursorSamples = input.usesTimelineComposition
      ? mapCursorSamplesForTimeline(input.cursorSamples, timeline: input.project.timeline)
      : shiftCursorSamplesForCompositionExport(
        input.cursorSamples,
        sourceStartSeconds: input.exportStartSeconds,
        compositionDurationSeconds: input.effectiveExportDurationSeconds
      )
    let cursorHighlightRegions = input.usesTimelineComposition
      ? mapHighlightRegionsForTimeline(input.cursorHighlightRegions, timeline: input.project.timeline)
      : RecordingProject.shiftHighlightRegionsForCompositionExport(
        input.cursorHighlightRegions,
        sourceStartSeconds: input.exportStartSeconds
      )

    return ExportTimedDataPlan(
      zoomKeyframes: zoomKeyframes,
      motionPlan: motionPlan,
      cursorSamples: cursorSamples,
      cursorHighlightRegions: cursorHighlightRegions,
      textOverlays: textOverlays,
      cursorClickCues: cursorClickCues,
      visualMasks: visualMasks,
      cameraLayoutSegments: cameraLayoutSegments
    )
  }

  private static func keyboardShortcutOverlays(
    project: RecordingProject,
    exportDurationSeconds: Double
  ) -> [RecordingProject.TextOverlayAnnotation] {
    guard project.cursorVisualSettings.showKeyboardShortcuts else { return [] }
    let modifierMask =
      UInt64(NSEvent.ModifierFlags.command.rawValue)
      | UInt64(NSEvent.ModifierFlags.option.rawValue)
      | UInt64(NSEvent.ModifierFlags.control.rawValue)
    _ = exportDurationSeconds
    return project.inputEvents.compactMap { event in
      guard event.kind == .keyDown,
        event.modifierFlagsRaw & modifierMask != 0,
        let text = event.shortcutDisplayText,
        !text.isEmpty
      else { return nil }
      let start = max(0, event.timeSeconds)
      return RecordingProject.TextOverlayAnnotation(
        startSeconds: start,
        endSeconds: start + 1.1,
        text: text,
        originXN: 0.34,
        originYN: 0.06,
        widthN: 0.32,
        heightN: 0.075,
        fontPointSize: 24
      )
    }
  }

  private static func clickCuesFromInputEvents(_ events: [RecordingProject.InputEvent]) -> [RecordingProject.CursorClickCue] {
    events
      .filter { $0.kind == .mouseDown }
      .map { RecordingProject.CursorClickCue(id: $0.id, timeSeconds: $0.timeSeconds) }
  }

  private static func shiftMotionFramesForCompositionExport(
    _ frames: [RecordingProject.AutoZoomMotionFrame],
    sourceStartSeconds: Double,
    compositionDurationSeconds: Double
  ) -> [RecordingProject.AutoZoomMotionFrame] {
    frames.compactMap { frame in
      let t = frame.timeSeconds - sourceStartSeconds
      guard t >= -0.05 && t <= compositionDurationSeconds + 0.05 else { return nil }
      return RecordingProject.AutoZoomMotionFrame(
        timeSeconds: max(0, min(compositionDurationSeconds, t)),
        anchorX: frame.anchorX,
        anchorY: frame.anchorY,
        scale: frame.scale
      )
    }
    .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  private static func mapZoomKeyframesForTimeline(
    _ keyframes: [RecordingProject.ZoomKeyframe],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.ZoomKeyframe] {
    let mappings = timeline.timeMappings()
    guard !mappings.isEmpty else { return keyframes }
    return keyframes.flatMap { keyframe in
      mappings.compactMap { mapping in
        let sourceStart = max(keyframe.startSeconds, mapping.sourceStartSeconds)
        let sourceEnd = min(keyframe.endSeconds, mapping.sourceEndSeconds)
        guard sourceEnd - sourceStart >= RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds else {
          return nil
        }
        guard let timelineStart = mapping.timelineSeconds(forSourceSeconds: sourceStart),
          let timelineEnd = mapping.timelineSeconds(forSourceSeconds: sourceEnd)
        else {
          return nil
        }
        let timelineInEnd = mapping.timelineSeconds(forSourceSeconds: max(sourceStart, min(sourceEnd, keyframe.inEndSeconds)))
          ?? timelineStart
        let timelineOutStart = mapping.timelineSeconds(forSourceSeconds: max(sourceStart, min(sourceEnd, keyframe.outStartSeconds)))
          ?? timelineEnd
        return RecordingProject.ZoomKeyframe(
          id: keyframe.id,
          startSeconds: timelineStart,
          inEndSeconds: timelineInEnd,
          outStartSeconds: timelineOutStart,
          endSeconds: timelineEnd,
          scale: keyframe.scale,
          anchorX: keyframe.anchorX,
          anchorY: keyframe.anchorY,
          targetX: keyframe.targetX,
          targetY: keyframe.targetY,
          targetWidth: keyframe.targetWidth,
          targetHeight: keyframe.targetHeight
        )
      }
    }
  }

  private static func mapMotionFramesForTimeline(
    _ frames: [RecordingProject.AutoZoomMotionFrame],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.AutoZoomMotionFrame] {
    guard timeline.hasActiveClips else { return frames }
    return frames.flatMap { frame in
      timeline.timelineSeconds(forSourceSeconds: frame.timeSeconds).map { mappedSeconds in
        RecordingProject.AutoZoomMotionFrame(
          timeSeconds: mappedSeconds,
          anchorX: frame.anchorX,
          anchorY: frame.anchorY,
          scale: frame.scale
        )
      }
    }
    .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  private static func shiftVisualMasksForCompositionExport(
    _ masks: [RecordingProject.VisualMask],
    sourceStartSeconds: Double
  ) -> [RecordingProject.VisualMask] {
    masks.map { mask in
      RecordingProject.VisualMask(
        id: mask.id,
        startSeconds: mask.startSeconds - sourceStartSeconds,
        endSeconds: mask.endSeconds - sourceStartSeconds,
        kind: mask.kind,
        originXN: mask.originXN,
        originYN: mask.originYN,
        widthN: mask.widthN,
        heightN: mask.heightN,
        opacity: mask.opacity
      )
    }
  }

  private static func shiftCameraLayoutSegmentsForCompositionExport(
    _ segments: [RecordingProject.CameraLayoutSegment],
    sourceStartSeconds: Double
  ) -> [RecordingProject.CameraLayoutSegment] {
    segments.compactMap { segment in
      guard segment.endSeconds > sourceStartSeconds else { return nil }
      return RecordingProject.CameraLayoutSegment(
        id: segment.id,
        startSeconds: segment.startSeconds - sourceStartSeconds,
        endSeconds: segment.endSeconds - sourceStartSeconds,
        layout: segment.layout,
        originXN: segment.originXN,
        originYN: segment.originYN,
        widthN: segment.widthN,
        heightN: segment.heightN,
        cornerRadiusPts: segment.cornerRadiusPts,
        isMirrored: segment.isMirrored,
        shrinkDuringZoom: segment.shrinkDuringZoom
      )
    }
  }

  private static func mapCursorSamplesForTimeline(
    _ samples: [RecordingProject.CursorSample],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.CursorSample] {
    guard timeline.hasActiveClips else { return samples }
    return samples.flatMap { sample in
      timeline.timelineSeconds(forSourceSeconds: sample.timeSeconds).map { mappedSeconds in
        RecordingProject.CursorSample(
          id: sample.id,
          timeSeconds: mappedSeconds,
          x: sample.x,
          y: sample.y,
          shape: sample.shape
        )
      }
    }
    .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  private static func shiftCursorSamplesForCompositionExport(
    _ samples: [RecordingProject.CursorSample],
    sourceStartSeconds: Double,
    compositionDurationSeconds: Double
  ) -> [RecordingProject.CursorSample] {
    samples.compactMap { sample in
      let t = sample.timeSeconds - sourceStartSeconds
      guard t >= -0.02 && t <= compositionDurationSeconds + 0.02 else { return nil }
      return RecordingProject.CursorSample(
        id: sample.id,
        timeSeconds: max(0, min(compositionDurationSeconds, t)),
        x: sample.x,
        y: sample.y,
        shape: sample.shape
      )
    }
    .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  private static func mapHighlightRegionsForTimeline(
    _ regions: [RecordingProject.CursorHighlightRegion],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.CursorHighlightRegion] {
    let mappings = timeline.timeMappings()
    guard !mappings.isEmpty else { return regions }
    return regions.flatMap { region in
      mappings.compactMap { mapping in
        let sourceStart = max(region.startSeconds, mapping.sourceStartSeconds)
        let sourceEnd = min(region.endSeconds, mapping.sourceEndSeconds)
        guard sourceEnd - sourceStart >= RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds,
          let timelineStart = mapping.timelineSeconds(forSourceSeconds: sourceStart),
          let timelineEnd = mapping.timelineSeconds(forSourceSeconds: sourceEnd)
        else {
          return nil
        }
        return RecordingProject.CursorHighlightRegion(
          id: region.id,
          startSeconds: timelineStart,
          endSeconds: timelineEnd
        )
      }
    }
  }

  private static func mapTextOverlaysForTimeline(
    _ overlays: [RecordingProject.TextOverlayAnnotation],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.TextOverlayAnnotation] {
    let mappings = timeline.timeMappings()
    guard !mappings.isEmpty else { return overlays }
    return overlays.flatMap { overlay in
      mappings.compactMap { mapping in
        let sourceStart = max(overlay.startSeconds, mapping.sourceStartSeconds)
        let sourceEnd = min(overlay.endSeconds, mapping.sourceEndSeconds)
        guard sourceEnd > sourceStart,
          let timelineStart = mapping.timelineSeconds(forSourceSeconds: sourceStart),
          let timelineEnd = mapping.timelineSeconds(forSourceSeconds: sourceEnd)
        else {
          return nil
        }
        return RecordingProject.TextOverlayAnnotation(
          id: overlay.id,
          startSeconds: timelineStart,
          endSeconds: timelineEnd,
          text: overlay.text,
          originXN: overlay.originXN,
          originYN: overlay.originYN,
          widthN: overlay.widthN,
          heightN: overlay.heightN,
          fontPointSize: overlay.fontPointSize
        )
      }
    }
  }

  private static func mapClickCuesForTimeline(
    _ cues: [RecordingProject.CursorClickCue],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.CursorClickCue] {
    guard timeline.hasActiveClips else { return cues }
    return cues.flatMap { cue in
      timeline.timelineSeconds(forSourceSeconds: cue.timeSeconds).map {
        RecordingProject.CursorClickCue(id: cue.id, timeSeconds: $0)
      }
    }
    .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  private static func mapVisualMasksForTimeline(
    _ masks: [RecordingProject.VisualMask],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.VisualMask] {
    let mappings = timeline.timeMappings()
    guard !mappings.isEmpty else { return masks }
    return masks.flatMap { mask in
      mappings.compactMap { mapping in
        let sourceStart = max(mask.startSeconds, mapping.sourceStartSeconds)
        let sourceEnd = min(mask.endSeconds, mapping.sourceEndSeconds)
        guard sourceEnd > sourceStart,
          let timelineStart = mapping.timelineSeconds(forSourceSeconds: sourceStart),
          let timelineEnd = mapping.timelineSeconds(forSourceSeconds: sourceEnd)
        else {
          return nil
        }
        return RecordingProject.VisualMask(
          id: mask.id,
          startSeconds: timelineStart,
          endSeconds: timelineEnd,
          kind: mask.kind,
          originXN: mask.originXN,
          originYN: mask.originYN,
          widthN: mask.widthN,
          heightN: mask.heightN,
          opacity: mask.opacity
        )
      }
    }
  }

  private static func mapCameraLayoutSegmentsForTimeline(
    _ segments: [RecordingProject.CameraLayoutSegment],
    timeline: RecordingProject.TimelineModel
  ) -> [RecordingProject.CameraLayoutSegment] {
    let mappings = timeline.timeMappings()
    guard !mappings.isEmpty else { return segments }
    return segments.flatMap { segment in
      mappings.compactMap { mapping in
        let sourceStart = max(segment.startSeconds, mapping.sourceStartSeconds)
        let sourceEnd = min(segment.endSeconds, mapping.sourceEndSeconds)
        guard sourceEnd > sourceStart,
          let timelineStart = mapping.timelineSeconds(forSourceSeconds: sourceStart),
          let timelineEnd = mapping.timelineSeconds(forSourceSeconds: sourceEnd)
        else {
          return nil
        }
        return RecordingProject.CameraLayoutSegment(
          id: segment.id,
          startSeconds: timelineStart,
          endSeconds: timelineEnd,
          layout: segment.layout,
          originXN: segment.originXN,
          originYN: segment.originYN,
          widthN: segment.widthN,
          heightN: segment.heightN,
          cornerRadiusPts: segment.cornerRadiusPts,
          isMirrored: segment.isMirrored,
          shrinkDuringZoom: segment.shrinkDuringZoom
        )
      }
    }
  }
}
