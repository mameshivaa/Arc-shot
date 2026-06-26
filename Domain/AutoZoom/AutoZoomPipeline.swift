import AVFoundation
import CoreImage
import Foundation
import Vision

enum AutoZoomPipeline {
  struct Config {
    var activity: ActivityClassifier.Config = .init()
    var intent: ZoomIntentPlanner.Config = .init()
    var camera: SpringDamperCamera.Config = .init()
    var outputSampleRate: Double = 6
    var scaleThreshold: Double = 1.04
    var positionThreshold: Double = 0.02

    static var productDemo: Config {
      var config = Config()
      config.intent.enableTypingZoom = true
      return config
    }
  }

  struct Result {
    var track: CameraTrack
    var activities: [ActivitySpan]
    var intents: [ZoomIntent]
    var focusRegions: [FocusRegion]
    var zoomFrames: [RecordingProject.ZoomKeyframe]
    var zoomSegments: [RecordingProject.ZoomSegment]
  }

  static func generate(
    cursorSamples: [RecordingProject.CursorSample],
    inputEvents: [RecordingProject.InputEvent],
    durationSeconds: Double,
    existingManualKeyframes: [RecordingProject.ZoomKeyframe] = [],
    focusRegions: [FocusRegion] = [],
    config: Config = Config()
  ) -> Result {
    let activities = ActivityClassifier.classify(
      cursorSamples: cursorSamples,
      inputEvents: inputEvents,
      durationSeconds: durationSeconds,
      config: config.activity)

    let rawIntents = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: durationSeconds,
      focusRegions: focusRegions,
      config: config.intent)

    let intents = excludeManualOverrides(
      intents: rawIntents,
      manualKeyframes: existingManualKeyframes)

    let frames = SpringDamperCamera.simulate(
      intents: intents,
      cursorSamples: cursorSamples,
      durationSeconds: durationSeconds,
      config: config.camera)

    let track = CameraTrack(frames: frames, durationSeconds: durationSeconds)

    let keyframes = track.toZoomKeyframes(
      sampleRate: config.outputSampleRate,
      scaleThreshold: config.scaleThreshold,
      positionThreshold: config.positionThreshold)

    let autoSegments = track.toZoomSegments(
      sampleRate: config.outputSampleRate,
      scaleThreshold: config.scaleThreshold,
      positionThreshold: config.positionThreshold)
    let segments = excludeManualOverrides(
      segments: autoSegments,
      manualKeyframes: existingManualKeyframes,
      durationSeconds: durationSeconds)

    let merged = mergeWithManual(
      autoKeyframes: keyframes,
      manualKeyframes: existingManualKeyframes,
      durationSeconds: durationSeconds)

    return Result(
      track: track,
      activities: activities,
      intents: intents,
      focusRegions: focusRegions,
      zoomFrames: merged,
      zoomSegments: segments)
  }

  static func generate(
    from project: RecordingProject,
    assetDurationSeconds: Double,
    config: Config = .productDemo
  ) -> Result {
    let manualKeyframes = project.zoomSegments
      .filter { $0.mode == .manual || $0.mode == .instant }
      .map(\.asZoomKeyframe)
    return generate(
      cursorSamples: project.cursorSamples,
      inputEvents: project.inputEvents,
      durationSeconds: assetDurationSeconds,
      existingManualKeyframes: manualKeyframes,
      config: config)
  }

  static func generateWithFocusDetection(
    from project: RecordingProject,
    assetDurationSeconds: Double,
    focusRegionDetector: FocusRegionDetecting = DefaultFocusRegionDetector(),
    config: Config = .productDemo
  ) async -> Result {
    let manualKeyframes = project.zoomSegments
      .filter { $0.mode == .manual || $0.mode == .instant }
      .map(\.asZoomKeyframe)
    let regions = await focusRegionDetector.detectFocusRegions(
      project: project,
      assetDurationSeconds: assetDurationSeconds
    )
    return generate(
      cursorSamples: project.cursorSamples,
      inputEvents: project.inputEvents,
      durationSeconds: assetDurationSeconds,
      existingManualKeyframes: manualKeyframes,
      focusRegions: regions,
      config: config)
  }

  private static func excludeManualOverrides(
    intents: [ZoomIntent],
    manualKeyframes: [RecordingProject.ZoomKeyframe]
  ) -> [ZoomIntent] {
    guard !manualKeyframes.isEmpty else { return intents }
    return intents.filter { intent in
      !manualKeyframes.contains { kf in
        max(intent.startSeconds, kf.startSeconds) < min(intent.endSeconds, kf.endSeconds)
      }
    }
  }

  private static func excludeManualOverrides(
    segments: [RecordingProject.ZoomSegment],
    manualKeyframes: [RecordingProject.ZoomKeyframe],
    durationSeconds: Double
  ) -> [RecordingProject.ZoomSegment] {
    let auto = segments.filter { segment in
      !manualKeyframes.contains { kf in
        max(segment.startSeconds, kf.startSeconds) < min(segment.endSeconds, kf.endSeconds)
      }
    }
    return RecordingProject.sanitizedZoomSegments(auto, durationSeconds: durationSeconds)
  }

  private static func mergeWithManual(
    autoKeyframes: [RecordingProject.ZoomKeyframe],
    manualKeyframes: [RecordingProject.ZoomKeyframe],
    durationSeconds: Double
  ) -> [RecordingProject.ZoomKeyframe] {
    let auto = autoKeyframes.filter { akf in
      !manualKeyframes.contains { mkf in
        max(akf.startSeconds, mkf.startSeconds) < min(akf.endSeconds, mkf.endSeconds)
      }
    }
    let merged = (auto + manualKeyframes).sorted { $0.startSeconds < $1.startSeconds }
    return RecordingProject.TimelineKeyframeSanitize.zoomFrames(merged, durationSeconds: durationSeconds)
  }
}

enum AutoZoomAnalysisService {
  static func sourceSignature(project: RecordingProject, assetDurationSeconds: Double) -> String {
    let cursorBounds = project.cursorSamples.reduce(into: (first: Double?.none, last: Double?.none)) { acc, sample in
      acc.first = min(acc.first ?? sample.timeSeconds, sample.timeSeconds)
      acc.last = max(acc.last ?? sample.timeSeconds, sample.timeSeconds)
    }
    let inputHash = project.inputEvents.reduce(into: 0) { partial, event in
      partial = partial &* 31 &+ Int((event.timeSeconds * 1000).rounded())
      let kindValue = event.kind.rawValue.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
      partial = partial &* 31 &+ kindValue
    }
    return [
      RecordingProject.AutoZoomAnalysis.currentAlgorithmVersion.description,
      project.mediaURL.standardizedFileURL.path,
      String(format: "%.3f", assetDurationSeconds),
      project.cursorSamples.count.description,
      String(format: "%.3f", cursorBounds.first ?? 0),
      String(format: "%.3f", cursorBounds.last ?? 0),
      project.inputEvents.count.description,
      inputHash.description,
    ].joined(separator: "|")
  }

  static func makeAnalysis(
    project: RecordingProject,
    assetDurationSeconds: Double,
    focusRegionDetector: FocusRegionDetecting = DefaultFocusRegionDetector()
  ) async -> RecordingProject.AutoZoomAnalysis {
    let result = await AutoZoomPipeline.generateWithFocusDetection(
      from: project,
      assetDurationSeconds: assetDurationSeconds,
      focusRegionDetector: focusRegionDetector
    )
    return makeAnalysis(from: result, project: project, assetDurationSeconds: assetDurationSeconds)
  }

  static func makeCursorDrivenAnalysis(
    project: RecordingProject,
    assetDurationSeconds: Double
  ) -> RecordingProject.AutoZoomAnalysis {
    // Export must not depend on frame inspection; keep this path cursor/input driven.
    let result = AutoZoomPipeline.generate(
      from: project,
      assetDurationSeconds: assetDurationSeconds
    )
    return makeAnalysis(from: result, project: project, assetDurationSeconds: assetDurationSeconds)
  }

  private static func makeAnalysis(
    from result: AutoZoomPipeline.Result,
    project: RecordingProject,
    assetDurationSeconds: Double
  ) -> RecordingProject.AutoZoomAnalysis {
    return RecordingProject.AutoZoomAnalysis(
      sourceSignature: sourceSignature(project: project, assetDurationSeconds: assetDurationSeconds),
      assetDurationSeconds: assetDurationSeconds,
      focusRegions: result.focusRegions,
      motionFrames: result.track.frames.map {
        RecordingProject.AutoZoomMotionFrame(
          timeSeconds: $0.timeSeconds,
          anchorX: $0.position.x,
          anchorY: $0.position.y,
          scale: $0.scale
        )
      },
      editableSegments: result.zoomSegments
    )
  }

  static func validAnalysis(
    in project: RecordingProject,
    assetDurationSeconds: Double
  ) -> RecordingProject.AutoZoomAnalysis? {
    let signature = sourceSignature(project: project, assetDurationSeconds: assetDurationSeconds)
    guard let analysis = project.autoZoomAnalysis,
      analysis.matches(sourceSignature: signature, assetDurationSeconds: assetDurationSeconds)
    else {
      return nil
    }
    return analysis
  }
}

struct AutoZoomMotionState: Equatable {
  var timeSeconds: Double
  var anchorX: Double
  var anchorY: Double
  var scale: Double
}

struct AutoZoomMotionPlan: Codable, Equatable {
  struct SmoothingConfig: Codable, Equatable {
    var isEnabled: Bool = true
    var anchorDeadband: Double = 0.004
    var scaleDeadband: Double = 0.006
    var maxSmoothingGapSeconds: Double = 1.0 / 12.0
    var alpha: Double = 0.35
  }

  var frames: [RecordingProject.AutoZoomMotionFrame]

  init(
    frames: [RecordingProject.AutoZoomMotionFrame],
    smoothingConfig: SmoothingConfig = SmoothingConfig()
  ) {
    let sortedFrames = frames.sorted { $0.timeSeconds < $1.timeSeconds }
    self.frames = Self.smoothedFrames(sortedFrames, config: smoothingConfig)
  }

  func state(at seconds: Double) -> AutoZoomMotionState? {
    guard !frames.isEmpty else { return nil }
    guard frames.count > 1 else { return Self.state(from: frames[0], at: seconds) }
    if seconds <= frames[0].timeSeconds { return Self.state(from: frames[0], at: seconds) }
    if seconds >= frames[frames.count - 1].timeSeconds {
      return Self.state(from: frames[frames.count - 1], at: seconds)
    }

    var lo = 0
    var hi = frames.count - 1
    while lo < hi - 1 {
      let mid = (lo + hi) / 2
      if frames[mid].timeSeconds <= seconds {
        lo = mid
      } else {
        hi = mid
      }
    }

    let a = frames[lo]
    let b = frames[hi]
    let u = max(0, min(1, (seconds - a.timeSeconds) / max(1e-9, b.timeSeconds - a.timeSeconds)))
    return AutoZoomMotionState(
      timeSeconds: seconds,
      anchorX: a.anchorX + (b.anchorX - a.anchorX) * u,
      anchorY: a.anchorY + (b.anchorY - a.anchorY) * u,
      scale: a.scale + (b.scale - a.scale) * u
    )
  }

  private static func state(
    from frame: RecordingProject.AutoZoomMotionFrame,
    at seconds: Double
  ) -> AutoZoomMotionState {
    AutoZoomMotionState(
      timeSeconds: seconds,
      anchorX: frame.anchorX,
      anchorY: frame.anchorY,
      scale: frame.scale
    )
  }

  private static func smoothedFrames(
    _ sortedFrames: [RecordingProject.AutoZoomMotionFrame],
    config: SmoothingConfig
  ) -> [RecordingProject.AutoZoomMotionFrame] {
    guard config.isEnabled, !sortedFrames.isEmpty else { return sortedFrames }

    let alpha = max(0, min(1, config.alpha))
    let anchorBlendLimit = config.anchorDeadband * 8
    let scaleBlendLimit = config.scaleDeadband * 8
    var output: [RecordingProject.AutoZoomMotionFrame] = []
    output.reserveCapacity(sortedFrames.count)

    for rawFrame in sortedFrames {
      guard let previous = output.last else {
        output.append(rawFrame)
        continue
      }

      let gap = rawFrame.timeSeconds - previous.timeSeconds
      guard gap >= 0, gap <= config.maxSmoothingGapSeconds else {
        output.append(rawFrame)
        continue
      }

      let anchorDeltaX = rawFrame.anchorX - previous.anchorX
      let anchorDeltaY = rawFrame.anchorY - previous.anchorY
      let anchorDistance = hypot(anchorDeltaX, anchorDeltaY)
      let scaleDelta = abs(rawFrame.scale - previous.scale)

      let anchorX: Double
      let anchorY: Double
      if anchorDistance < config.anchorDeadband {
        anchorX = previous.anchorX
        anchorY = previous.anchorY
      } else if anchorDistance < anchorBlendLimit {
        anchorX = previous.anchorX + anchorDeltaX * alpha
        anchorY = previous.anchorY + anchorDeltaY * alpha
      } else {
        anchorX = rawFrame.anchorX
        anchorY = rawFrame.anchorY
      }

      let scale: Double
      if scaleDelta < config.scaleDeadband {
        scale = previous.scale
      } else if scaleDelta < scaleBlendLimit {
        scale = previous.scale + (rawFrame.scale - previous.scale) * alpha
      } else {
        scale = rawFrame.scale
      }

      output.append(RecordingProject.AutoZoomMotionFrame(
        timeSeconds: rawFrame.timeSeconds,
        anchorX: anchorX,
        anchorY: anchorY,
        scale: scale
      ))
    }

    return output
  }
}

struct AutoZoomMotionResolution {
  enum Source: String, Equatable {
    case persisted
    case generated
    case manual
    case none
  }

  var source: Source
  var motionPlan: AutoZoomMotionPlan?
  var zoomKeyframes: [RecordingProject.ZoomKeyframe]
}

enum AutoZoomMotionResolver {
  static func resolve(
    project: RecordingProject,
    assetDurationSeconds: Double,
    exportStartSeconds: Double,
    exportEndSeconds: Double
  ) -> AutoZoomMotionResolution {
    let manualZoomKeyframes = project.zoomSegments
      .filter { $0.mode == .manual || $0.mode == .instant }
      .map(\.asZoomKeyframe)
    if !manualZoomKeyframes.isEmpty || project.stylePreset != .cursorFocus || project.cursorSamples.isEmpty {
      let keyframes = RecordingProject.effectiveZoomKeyframes(
        stylePreset: project.stylePreset,
        userKeyframes: manualZoomKeyframes,
        exportStartSeconds: exportStartSeconds,
        exportEndSeconds: exportEndSeconds,
        softZoomScale: project.styleSettings.softZoomScale
      )
      return AutoZoomMotionResolution(
        source: keyframes.isEmpty ? .none : .manual,
        motionPlan: nil,
        zoomKeyframes: keyframes
      )
    }

    if let analysis = AutoZoomAnalysisService.validAnalysis(
      in: project,
      assetDurationSeconds: assetDurationSeconds
    ) {
      return AutoZoomMotionResolution(
        source: .persisted,
        motionPlan: AutoZoomMotionPlan(frames: analysis.motionFrames),
        zoomKeyframes: []
      )
    }

    let analysis = AutoZoomAnalysisService.makeCursorDrivenAnalysis(
      project: project,
      assetDurationSeconds: assetDurationSeconds
    )
    return AutoZoomMotionResolution(
      source: .generated,
      motionPlan: AutoZoomMotionPlan(frames: analysis.motionFrames),
      zoomKeyframes: []
    )
  }
}

protocol FocusRegionDetecting {
  func detectFocusRegions(
    project: RecordingProject,
    assetDurationSeconds: Double
  ) async -> [FocusRegion]
}

struct DefaultFocusRegionDetector: FocusRegionDetecting {
  private struct EventProbe {
    var timeSeconds: Double
    var kind: FocusRegion.Kind
    var anchor: CGPoint
  }

  private static let maxProbeCount = 18
  private static let resultProbeDelaySeconds = 0.45
  private static let contextPadding: CGFloat = 0.035

  func detectFocusRegions(
    project: RecordingProject,
    assetDurationSeconds: Double
  ) async -> [FocusRegion] {
    guard assetDurationSeconds > 0, !project.inputEvents.isEmpty else { return [] }

    let asset = AVURLAsset(url: project.mediaURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)

    var regions: [FocusRegion] = []
    let probes = makeEventProbes(project: project, durationSeconds: assetDurationSeconds)

    for probe in probes.prefix(Self.maxProbeCount) {
      guard let image = await copyImage(at: probe.timeSeconds, generator: generator) else { continue }
      if let target = uiTargetRegion(
        in: image,
        anchor: probe.anchor,
        kind: probe.kind,
        timeSeconds: probe.timeSeconds
      ) {
        regions.append(target)
      }

      let resultTime = min(assetDurationSeconds, probe.timeSeconds + Self.resultProbeDelaySeconds)
      if resultTime > probe.timeSeconds + 0.05,
         let after = await copyImage(at: resultTime, generator: generator),
         let changed = changedRegion(
          before: image,
          after: after,
          anchor: probe.anchor,
          startSeconds: probe.timeSeconds,
          endSeconds: resultTime + 0.8
         ) {
        regions.append(changed)
      }
    }

    return mergeRegions(regions, durationSeconds: assetDurationSeconds)
  }

  private func makeEventProbes(
    project: RecordingProject,
    durationSeconds: Double
  ) -> [EventProbe] {
    let samples = project.cursorSamples.sorted { $0.timeSeconds < $1.timeSeconds }
    return project.inputEvents
      .filter { event in event.kind == .mouseDown || event.kind == .keyDown }
      .sorted { $0.timeSeconds < $1.timeSeconds }
      .compactMap { event -> EventProbe? in
        guard event.timeSeconds >= 0, event.timeSeconds <= durationSeconds else { return nil }
        let anchor: CGPoint
        if let x = event.x, let y = event.y {
          anchor = CGPoint(x: CGFloat(x), y: CGFloat(y))
        } else {
          let pos = ActivityClassifier.interpolatedPosition(at: event.timeSeconds, samples: samples)
          anchor = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
        }
        let kind: FocusRegion.Kind = event.kind == .keyDown ? .typingTarget : .clickTarget
        return EventProbe(timeSeconds: event.timeSeconds, kind: kind, anchor: anchor)
      }
  }

  private func copyImage(at seconds: Double, generator: AVAssetImageGenerator) async -> CGImage? {
    let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    return await withCheckedContinuation { continuation in
      generator.generateCGImageAsynchronously(for: time) { image, _, _ in
        continuation.resume(returning: image)
      }
    }
  }

  private func uiTargetRegion(
    in image: CGImage,
    anchor: CGPoint,
    kind: FocusRegion.Kind,
    timeSeconds: Double
  ) -> FocusRegion? {
    let textBoxes = textRegions(in: image)
    let rectBoxes = rectangleRegions(in: image)
    let candidates = (textBoxes + rectBoxes)
      .map { expand($0, by: Self.contextPadding) }
      .filter { rect in
        rect.contains(anchor) || distance(from: anchor, to: rect) < 0.18
      }

    guard let best = candidates.min(by: {
      distance(from: anchor, to: $0) < distance(from: anchor, to: $1)
    }) else { return nil }

    let nearby = candidates.filter { distance(from: center(of: best), to: $0) < 0.16 }
    let union = nearby.reduce(best) { $0.union($1) }
    return FocusRegion(
      startSeconds: max(0, timeSeconds - 0.12),
      endSeconds: timeSeconds + 1.15,
      bounds: clamp(expand(union, by: 0.02)),
      kind: kind,
      confidence: kind == .typingTarget ? 0.9 : 0.82
    )
  }

  private func textRegions(in image: CGImage) -> [CGRect] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.012
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }

    return (request.results ?? []).compactMap { observation in
      guard (observation.topCandidates(1).first?.confidence ?? 0) >= 0.25 else { return nil }
      return visionRectToTopLeft(observation.boundingBox)
    }
  }

  private func rectangleRegions(in image: CGImage) -> [CGRect] {
    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 12
    request.minimumConfidence = 0.35
    request.minimumSize = 0.025
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }
    return (request.results ?? []).map { visionRectToTopLeft($0.boundingBox) }
  }

  private func changedRegion(
    before: CGImage,
    after: CGImage,
    anchor: CGPoint,
    startSeconds: Double,
    endSeconds: Double
  ) -> FocusRegion? {
    guard let cells = differenceGrid(before: before, after: after) else { return nil }
    let hotCells = cells.filter { $0.intensity > 0.18 }
    guard hotCells.count >= 3 else { return nil }

    let nearCells = hotCells.filter { cell in
      distance(from: anchor, to: cell.rect) < 0.38
    }
    let selected = nearCells.isEmpty ? hotCells : nearCells
    guard var bounds = selected.first?.rect else { return nil }
    for cell in selected.dropFirst() {
      bounds = bounds.union(cell.rect)
    }
    guard bounds.width * bounds.height >= 0.004 else { return nil }

    return FocusRegion(
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      bounds: clamp(expand(bounds, by: 0.045)),
      kind: .resultChange,
      confidence: min(0.88, 0.45 + Double(selected.count) / Double(cells.count))
    )
  }

  private func differenceGrid(
    before: CGImage,
    after: CGImage
  ) -> [(rect: CGRect, intensity: Double)]? {
    let width = 32
    let height = 18
    let beforeImage = CIImage(cgImage: before)
    let afterImage = CIImage(cgImage: after)
    let diff = afterImage
      .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: beforeImage])
      .applyingFilter("CIEdges", parameters: ["inputIntensity": 2.4])

    let sourceExtent = afterImage.extent
    guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }
    let scaled = diff.transformed(by: CGAffineTransform(
      scaleX: CGFloat(width) / sourceExtent.width,
      y: CGFloat(height) / sourceExtent.height
    ))

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    bytes.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      context.render(
        scaled,
        toBitmap: baseAddress,
        rowBytes: width * 4,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
      )
    }

    var cells: [(CGRect, Double)] = []
    for y in 0..<height {
      for x in 0..<width {
        let idx = (y * width + x) * 4
        let intensity = (Double(bytes[idx]) + Double(bytes[idx + 1]) + Double(bytes[idx + 2])) / (255.0 * 3.0)
        let rect = CGRect(
          x: CGFloat(x) / CGFloat(width),
          y: CGFloat(1) - CGFloat(y + 1) / CGFloat(height),
          width: CGFloat(1) / CGFloat(width),
          height: CGFloat(1) / CGFloat(height)
        )
        cells.append((rect, intensity))
      }
    }
    return cells
  }

  private func mergeRegions(
    _ regions: [FocusRegion],
    durationSeconds: Double
  ) -> [FocusRegion] {
    let sorted = regions
      .filter { $0.durationSeconds > 0 && $0.bounds.width > 0 && $0.bounds.height > 0 }
      .sorted { $0.startSeconds < $1.startSeconds }
    var merged: [FocusRegion] = []
    for region in sorted {
      guard var last = merged.popLast() else {
        merged.append(region)
        continue
      }
      let closeInTime = region.startSeconds - last.endSeconds < 0.35
      let closeInSpace = distance(from: center(of: region.bounds), to: last.bounds) < 0.15
      if closeInTime && closeInSpace && region.kind == last.kind {
        last.endSeconds = min(durationSeconds, max(last.endSeconds, region.endSeconds))
        last.bounds = clamp(last.bounds.union(region.bounds))
        last.confidence = max(last.confidence, region.confidence)
        merged.append(last)
      } else {
        merged.append(last)
        merged.append(region)
      }
    }
    return merged
  }

  private func visionRectToTopLeft(_ rect: CGRect) -> CGRect {
    clamp(CGRect(
      x: rect.minX,
      y: 1.0 - rect.maxY,
      width: rect.width,
      height: rect.height
    ))
  }

  private func expand(_ rect: CGRect, by padding: CGFloat) -> CGRect {
    rect.insetBy(dx: -padding, dy: -padding)
  }

  private func clamp(_ rect: CGRect) -> CGRect {
    rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  private func center(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
  }

  private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
  }
}
