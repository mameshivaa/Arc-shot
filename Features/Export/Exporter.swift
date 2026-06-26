@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Observation

struct ExportError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

@Observable
final class Exporter: @unchecked Sendable {
  enum ExportState: Equatable {
    case idle
    case exporting
    case finished(URL)
    case failed(String)
  }

  private(set) var state: ExportState = .idle
  private(set) var progress: Double = 0

  private var readerWriterSession: ExportReaderWriterSession?
  private var progressTimer: Timer?
  private var exportQueue = DispatchQueue(label: AppIdentifiers.DispatchQueueLabels.export)
  private var shouldCopyResultToClipboard = false
  private var activeExportID: UUID?
  private var activeTemporaryOutputURL: URL?
  private var outputAccess = ExportOutputAccess()

  func export(
    project: RecordingProject,
    to outputURL: URL,
    copyToClipboard: Bool = false
  ) {
    if case .exporting = state {
      return
    }
    stop()
    let exportID = UUID()
    activeExportID = exportID
    shouldCopyResultToClipboard = copyToClipboard

    Task { @MainActor in
      guard self.activeExportID == exportID else { return }
      guard self.outputAccess.begin(for: outputURL) else {
        self.state = .failed("保存先へのアクセス権を取得できませんでした。保存先を選び直してください。")
        self.activeExportID = nil
        return
      }
      guard self.activeExportID == exportID else {
        self.outputAccess.release()
        return
      }
      self.startExportWork(
        project: project,
        to: outputURL,
        exportID: exportID
      )
    }
  }

  @MainActor
  private func startExportWork(
    project: RecordingProject,
    to outputURL: URL,
    exportID: UUID
  ) {
    guard activeExportID == exportID else {
      outputAccess.release()
      return
    }

    let asset = AVURLAsset(url: project.mediaURL)
    let preset = ExportPreset.byID(project.exportPreset)
    let assetDurationCM: CMTime
    let timeRange: CMTimeRange?
    let sourceVideoSize: CGSize
    do {
      assetDurationCM = try ExportAsyncBridge.runSync { try await asset.load(.duration) }
      timeRange = makeExportTimeRange(project: project, assetDuration: assetDurationCM)
      sourceVideoSize = try ExportAsyncBridge.runSync {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return CGSize.zero }
        async let natural = track.load(.naturalSize)
        async let preferred = track.load(.preferredTransform)
        let (n, p) = try await (natural, preferred)
        return ExportVideoGeometry.orientedSourceSize(naturalSize: n, preferredTransform: p)
      }
    } catch {
      self.state = .failed(String(describing: error))
      self.activeExportID = nil
      self.outputAccess.release()
      return
    }

    let target = makeTargetVideoFormat(
      preset: preset,
      aspectRatio: project.outputAspectRatio,
      sourceSize: sourceVideoSize
    )

    state = .exporting
    progress = 0

    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      // Updated by background loop via `updateProgress`.
    }

    let (exportStart, exportEnd) = exportWindowSeconds(project: project, assetDuration: assetDurationCM)
    let assetDur = assetDurationCM.isNumeric ? max(0, assetDurationCM.seconds) : 0
    let motionResolution = AutoZoomMotionResolver.resolve(
      project: project,
      assetDurationSeconds: assetDur,
      exportStartSeconds: exportStart,
      exportEndSeconds: exportEnd
    )
    let cursorSamples = project.cursorVisualSettings.isVisible ? project.cursorSamples : []
    let highlights = project.stylePreset == .cursorFocus ? project.cursorHighlightRegions : []
    let style = project.styleSettings
    let exportVisualSettings = project.exportVisualSettings
    let sourceKind = project.source.kind
    exportQueue.async { [weak self] in
      self?.runExport(
        project: project,
        mainAsset: asset,
        preset: preset,
        timeRange: timeRange,
        target: target,
        outputURL: outputURL,
        exportID: exportID,
        motionResolution: motionResolution,
        cursorSamples: cursorSamples,
        cursorHighlightRegions: highlights,
        styleSettings: style,
        exportVisualSettings: exportVisualSettings,
        sourceKind: sourceKind
      )
    }
  }

  func stop() {
    progressTimer?.invalidate()
    progressTimer = nil
    readerWriterSession?.cancel()
    if let activeTemporaryOutputURL {
      ExportOutputPromotion.removeTemporaryOutputArtifacts(for: activeTemporaryOutputURL)
    }
    readerWriterSession = nil
    activeExportID = nil
    activeTemporaryOutputURL = nil
    progress = 0
    shouldCopyResultToClipboard = false
    if case .exporting = state { state = .idle }
    Task { @MainActor in
      self.outputAccess.release()
    }
  }

}

/// `exportQueue` など非 async コンテキストから、`AVAsset` の macOS 13+ の非同期読み込みのみを同期的にブリッジする。
enum ExportAsyncBridge {
  static func runSync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    nonisolated(unsafe) var boxed: Result<T, Error>?
    let sem = DispatchSemaphore(value: 0)
    Task {
      do {
        boxed = .success(try await work())
      } catch {
        boxed = .failure(error)
      }
      sem.signal()
    }
    sem.wait()
    switch boxed {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    case .none:
      preconditionFailure("ExportAsyncBridge: incomplete")
    }
  }
}

enum ExportVideoGeometry {
  static func matchSourceRenderSize(sourceSize: CGSize, aspectRatio: AspectRatioPreset) -> CGSize {
    let aspect = aspectRatio.editorPreviewAspectRatio
    let srcW = max(2, sourceSize.width)
    let srcH = max(2, sourceSize.height)
    let fitW: CGFloat
    let fitH: CGFloat
    if srcW / srcH >= aspect {
      fitW = srcH * aspect
      fitH = srcH
    } else {
      fitW = srcW
      fitH = srcW / aspect
    }
    return CGSize(
      width: CGFloat(max(2, Int(fitW.rounded()) & ~1)),
      height: CGFloat(max(2, Int(fitH.rounded()) & ~1))
    )
  }

  static func orientedSourceSize(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
  ) -> CGSize {
    let sourceSize = naturalSize.applying(preferredTransform)
    return CGSize(width: abs(sourceSize.width), height: abs(sourceSize.height))
  }

  static func normalizedSourcePoint(
    x: Double,
    y: Double,
    sourceSize: CGSize
  ) -> CGPoint {
    CGPoint(
      x: max(0, min(1, x)) * sourceSize.width,
      y: max(0, min(1, y)) * sourceSize.height
    )
  }

  static func aspectFitBaseTransform(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform,
    renderSize: CGSize
  ) -> CGAffineTransform {
    let sourceSize = orientedSourceSize(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
    let srcW = sourceSize.width
    let srcH = sourceSize.height
    let scale = min(renderSize.width / max(1, srcW), renderSize.height / max(1, srcH))
    let scaledW = srcW * scale
    let scaledH = srcH * scale
    let tx = (renderSize.width - scaledW) / 2
    let ty = (renderSize.height - scaledH) / 2

    var transform = preferredTransform
    transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
    return transform
  }

  /// Maps stage layout rects (top-left origin, matching preview SwiftUI) into CIImage space (bottom-left origin).
  static func stageRectInCIImageSpace(_ topLeftRect: CGRect, renderSize: CGSize) -> CGRect {
    CGRect(
      x: topLeftRect.origin.x,
      y: renderSize.height - topLeftRect.maxY,
      width: topLeftRect.width,
      height: topLeftRect.height
    )
  }

  /// Top-left normalized mask rect mapped into CIImage source pixel space (bottom-left origin).
  static func maskSourceRect(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double,
    sourceSize: CGSize
  ) -> CGRect {
    let width = CGFloat(sourceSize.width)
    let height = CGFloat(sourceSize.height)
    return CGRect(
      x: CGFloat(originXN) * width,
      y: CGFloat(1 - originYN - heightN) * height,
      width: CGFloat(widthN) * width,
      height: CGFloat(heightN) * height
    )
  }

  /// Top-left normalized blur rect in pre-zoom pixel-buffer row space.
  /// Matches `EditorPreviewLayout.maskRect` and is applied before zoom / Y-flip transforms.
  static func maskBlurSourceRect(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double,
    sourceSize: CGSize
  ) -> CGRect {
    let width = CGFloat(sourceSize.width)
    let height = CGFloat(sourceSize.height)
    return CGRect(
      x: CGFloat(originXN) * width,
      y: CGFloat(originYN) * height,
      width: CGFloat(widthN) * width,
      height: CGFloat(heightN) * height
    )
  }

  static func maskRenderRect(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double,
    sourceSize: CGSize,
    sourceTransform: CGAffineTransform,
    renderSize: CGSize
  ) -> CGRect {
    let sourceRect = maskSourceRect(
      originXN: originXN,
      originYN: originYN,
      widthN: widthN,
      heightN: heightN,
      sourceSize: sourceSize
    )
    let corners = [
      CGPoint(x: sourceRect.minX, y: sourceRect.minY),
      CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
      CGPoint(x: sourceRect.minX, y: sourceRect.maxY),
      CGPoint(x: sourceRect.maxX, y: sourceRect.maxY),
    ].map { $0.applying(sourceTransform) }
    let xs = corners.map(\.x)
    let ys = corners.map { renderSize.height - $0.y }
    return CGRect(
      x: xs.min() ?? 0,
      y: ys.min() ?? 0,
      width: max(1, (xs.max() ?? 1) - (xs.min() ?? 0)),
      height: max(1, (ys.max() ?? 1) - (ys.min() ?? 0))
    )
  }

  /// Top-left normalized text overlay rect mapped into CGContext render space (bottom-left origin).
  static func textOverlayRenderRect(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double,
    renderSize: CGSize
  ) -> CGRect {
    CGRect(
      x: CGFloat(originXN) * renderSize.width,
      y: CGFloat(1 - originYN - heightN) * renderSize.height,
      width: CGFloat(widthN) * renderSize.width,
      height: CGFloat(heightN) * renderSize.height
    )
  }

  /// Top-left normalized PiP rect mapped into CIImage compositor space (bottom-left origin).
  /// Matches editor preview (`EditorPreviewCameraPresentation`) and `textOverlayRenderRect`.
  static func pipCompositorRect(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double,
    renderSize: CGSize
  ) -> CGRect {
    textOverlayRenderRect(
      originXN: originXN,
      originYN: originYN,
      widthN: widthN,
      heightN: heightN,
      renderSize: renderSize
    )
  }
}

extension Exporter {
  enum ExportStageLayoutPolicy {
    static func shouldApply(
      settings: RecordingProject.ExportVisualSettings,
      sourceKind: RecordingProject.SourceKind
    ) -> Bool {
      guard settings.stageStyle != .none else { return false }
      switch sourceKind {
      case .window: return true
      case .display, .area: return settings.enabledForDisplayCapture
      }
    }
  }
}

private extension Exporter {
  func makeTargetVideoFormat(
    preset: ExportPreset,
    aspectRatio: AspectRatioPreset,
    sourceSize: CGSize = .zero
  ) -> ExportTargetVideoFormat {
    let size: CGSize = switch (preset.resolution, aspectRatio) {
    case (.matchSource, _):
      ExportVideoGeometry.matchSourceRenderSize(sourceSize: sourceSize, aspectRatio: aspectRatio)
    case (.p1080, .sixteenNine): .init(width: 1920, height: 1080)
    case (.p1080, .nineSixteen): .init(width: 1080, height: 1920)
    case (.p1080, .oneOne): .init(width: 1080, height: 1080)
    case (.p1080, .fourThree): .init(width: 1440, height: 1080)
    case (.p1080, .threeFour): .init(width: 1080, height: 1440)
    case (.p720, .sixteenNine): .init(width: 1280, height: 720)
    case (.p720, .nineSixteen): .init(width: 720, height: 1280)
    case (.p720, .oneOne): .init(width: 720, height: 720)
    case (.p720, .fourThree): .init(width: 960, height: 720)
    case (.p720, .threeFour): .init(width: 720, height: 960)
    }
    let bitrateMbps = ExportPreset.VideoEncoding.scaledBitrateMbps(
      baseMbps: preset.videoBitrateMbps,
      renderSize: size
    )
    return .init(size: size, frameRate: preset.frameRate, videoBitrateMbps: bitrateMbps)
  }

  /// Asset-timeline span used for zoom synthesis.
  func exportWindowSeconds(project: RecordingProject, assetDuration: CMTime) -> (Double, Double) {
    let assetDur = assetDuration.isNumeric ? max(0, assetDuration.seconds) : 0
    guard let clip = project.timeline.singleEditableClip else { return (0, assetDur) }
    let start = max(0, clip.sourceStartSeconds)
    let end = max(start, clip.sourceStartSeconds + clip.durationSeconds)
    return assetDur <= 0 ? (start, end) : (start, min(end, assetDur))
  }

  func makeExportTimeRange(project: RecordingProject, assetDuration: CMTime) -> CMTimeRange? {
    guard !project.timeline.hasActiveClips, let clip = project.timeline.singleEditableClip else { return nil }
    let start = CMTime(seconds: max(0, clip.sourceStartSeconds), preferredTimescale: 600)
    let end = CMTime(seconds: max(clip.sourceStartSeconds + clip.durationSeconds, clip.sourceStartSeconds), preferredTimescale: 600)
    let duration = CMTimeSubtract(end, start)
    if duration <= .zero { return nil }

    // Clamp end to asset duration when available.
    if assetDuration.isNumeric {
      let maxDuration = CMTimeSubtract(assetDuration, start)
      return CMTimeRange(start: start, duration: min(duration, maxDuration))
    }

    return CMTimeRange(start: start, duration: duration)
  }

  @MainActor
  private func releaseOutputAccessAfterExport() {
    outputAccess.release()
  }

  func runExport(
    project: RecordingProject,
    mainAsset: AVURLAsset,
    preset: ExportPreset,
    timeRange: CMTimeRange?,
    target: ExportTargetVideoFormat,
    outputURL: URL,
    exportID: UUID,
    motionResolution: AutoZoomMotionResolution,
    cursorSamples: [RecordingProject.CursorSample],
    cursorHighlightRegions: [RecordingProject.CursorHighlightRegion],
    styleSettings: RecordingProject.StyleSettings,
    exportVisualSettings: RecordingProject.ExportVisualSettings,
    sourceKind: RecordingProject.SourceKind
  ) {
    guard activeExportID == exportID else { return }
    let temporaryOutputURL = ExportOutputPromotion.temporaryOutputURL(for: outputURL)
    do {
      activeTemporaryOutputURL = temporaryOutputURL
      if FileManager.default.fileExists(atPath: temporaryOutputURL.path) {
        try FileManager.default.removeItem(at: temporaryOutputURL)
      }

      let mainLoadedDuration = try ExportAsyncBridge.runSync { try await mainAsset.load(.duration) }

      let (expStart, expEnd) = exportWindowSeconds(project: project, assetDuration: mainLoadedDuration)
      let trimExportDurSec = max(0.001, expEnd - expStart)

      let plan = try ExportCompositionPlanner.plan(input: ExportCompositionPlanner.Input(
        project: project,
        mainAsset: mainAsset,
        mainLoadedDuration: mainLoadedDuration,
        timeRange: timeRange,
        exportStartSeconds: expStart,
        trimmedExportDurationSeconds: trimExportDurSec
      ))
      let readerAsset = plan.readerAsset
      let mainVideoTrack = plan.mainVideoTrack
      let pipVideoTrack = plan.pipVideoTrack
      let pipForPipeline = plan.pipAttachment
      let compositionInstructionsTimeRange = plan.compositionInstructionsTimeRange
      let readerTimeRange = plan.readerTimeRange
      let readerProgressBase = plan.readerProgressBase
      let effectiveExportDurationSeconds = plan.effectiveExportDurationSeconds
      let usesTimelineComposition = plan.usesTimelineComposition
      let timedDataOffsetSeconds = plan.timedDataOffsetSeconds

      let timedData = ExportTimedDataMapper.map(input: ExportTimedDataMapper.Input(
        project: project,
        motionResolution: motionResolution,
        cursorSamples: cursorSamples,
        cursorHighlightRegions: cursorHighlightRegions,
        exportStartSeconds: expStart,
        effectiveExportDurationSeconds: effectiveExportDurationSeconds,
        usesTimelineComposition: usesTimelineComposition
      ))

      let (videoOutput, videoInput) = try ExportVideoPipelineFactory.makeVideoPipeline(
        mainVideoTrack: mainVideoTrack,
        pipVideoTrack: pipVideoTrack,
        pipAttachment: pipForPipeline,
        preset: preset,
        compositionInstructionsTimeRange: compositionInstructionsTimeRange,
        timedDataOffsetSeconds: timedDataOffsetSeconds,
        target: target,
        zoomFrames: timedData.zoomKeyframes,
        motionPlan: timedData.motionPlan,
        cursorSamples: timedData.cursorSamples,
        cursorHighlightRegions: timedData.cursorHighlightRegions,
        textOverlays: timedData.textOverlays,
        cursorClickCues: timedData.cursorClickCues,
        visualMasks: timedData.visualMasks,
        cameraLayoutSegments: timedData.cameraLayoutSegments,
        cursorVisualSettings: project.cursorVisualSettings,
        styleSettings: styleSettings,
        exportVisualSettings: exportVisualSettings,
        sourceKind: sourceKind
      )

      let (audioOutput, audioInput) = try ExportVideoPipelineFactory.makeAudioPipeline(
        asset: readerAsset,
        audioSettings: project.audioTrackSettings,
        audioSegments: project.audioTimelineSegments,
        compositionDurationSeconds: max(0.001, effectiveExportDurationSeconds)
      )

      let durationSeconds: Double = {
        if compositionInstructionsTimeRange.duration.isNumeric {
          return max(0.001, compositionInstructionsTimeRange.duration.seconds)
        }
        if let timeRange, timeRange.duration.isNumeric { return max(0.001, timeRange.duration.seconds) }
        if mainLoadedDuration.isNumeric { return max(0.001, mainLoadedDuration.seconds) }
        return 1.0
      }()
      let exportManifest = ExportManifest(
        renderSize: target.size,
        frameRate: target.frameRate,
        expectedDurationSeconds: durationSeconds,
        expectedFrameCount: max(1, Int((durationSeconds * Double(target.frameRate)).rounded())),
        codec: preset.codec,
        bitrateTarget: target.videoBitrateMbps * 1_000_000,
        usesTimelineComposition: usesTimelineComposition,
        motionSource: motionResolution.source
      )

      let session = ExportReaderWriterSession()
      readerWriterSession = session
      session.start(
        input: ExportReaderWriterSession.Input(
          readerAsset: readerAsset,
          readerTimeRange: readerTimeRange,
          temporaryOutputURL: temporaryOutputURL,
          videoOutput: videoOutput,
          videoInput: videoInput,
          audioOutput: audioOutput,
          audioInput: audioInput,
          readerProgressBase: readerProgressBase,
          durationSeconds: durationSeconds,
          exportQueue: exportQueue
        ),
        progress: { [weak self] ratio in
          Task { @MainActor in
            self?.progress = ratio
          }
        },
        onFinish: { [weak self] result in
          guard let self else { return }
          Task { @MainActor in
            self.handleReaderWriterResult(
              result,
              exportID: exportID,
              temporaryOutputURL: temporaryOutputURL,
              outputURL: outputURL,
              manifest: exportManifest
            )
          }
        }
      )
    } catch {
      ExportOutputPromotion.removeTemporaryOutputArtifacts(for: temporaryOutputURL)
      Task { @MainActor in
        guard self.activeExportID == exportID else { return }
        self.progressTimer?.invalidate()
        self.progressTimer = nil
        self.activeTemporaryOutputURL = nil
        self.state = .failed(String(describing: error))
        self.releaseOutputAccessAfterExport()
      }
    }
  }

  @MainActor
  private func handleReaderWriterResult(
    _ result: ExportReaderWriterSession.Result,
    exportID: UUID,
    temporaryOutputURL: URL,
    outputURL: URL,
    manifest: ExportManifest
  ) {
    progressTimer?.invalidate()
    progressTimer = nil

    guard activeExportID == exportID else {
      ExportOutputPromotion.removeTemporaryOutputArtifacts(for: temporaryOutputURL)
      return
    }

    switch result {
    case .success:
      finishSuccessfulExport(
        temporaryOutputURL: temporaryOutputURL,
        outputURL: outputURL,
        manifest: manifest
      )
    case let .readerFailure(message),
      let .writerFailure(message),
      let .setupFailure(message):
      failExport(message, temporaryOutputURL: temporaryOutputURL)
    }
  }

  @MainActor
  private func finishSuccessfulExport(
    temporaryOutputURL: URL,
    outputURL: URL,
    manifest: ExportManifest
  ) {
    do {
      try ExportOutputPromotion.promoteTemporaryOutput(
        temporaryOutputURL,
        to: outputURL,
        manifest: manifest
      )
    } catch {
      failExport(String(describing: error), temporaryOutputURL: temporaryOutputURL)
      return
    }
    progress = 1
    state = .finished(outputURL)
    activeExportID = nil
    activeTemporaryOutputURL = nil
    readerWriterSession = nil
    releaseOutputAccessAfterExport()
    if shouldCopyResultToClipboard {
      copyToClipboard(fileURL: outputURL)
    }
  }

  @MainActor
  private func failExport(_ message: String, temporaryOutputURL: URL) {
    ExportOutputPromotion.removeTemporaryOutputArtifacts(for: temporaryOutputURL)
    state = .failed(message)
    readerWriterSession = nil
    releaseOutputAccessAfterExport()
  }

  @MainActor
  func copyToClipboard(fileURL: URL) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])
  }

}
