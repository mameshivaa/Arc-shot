@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

struct ExportTargetVideoFormat {
  var size: CGSize
  var frameRate: Int
  var videoBitrateMbps: Int
}

enum ExportVideoPipelineFactory {
  static func makeVideoPipeline(
    mainVideoTrack: AVAssetTrack,
    pipVideoTrack: AVAssetTrack?,
    pipAttachment: RecordingProject.SecondaryRecordingAttachment?,
    preset: ExportPreset,
    compositionInstructionsTimeRange: CMTimeRange,
    timedDataOffsetSeconds: Double,
    target: ExportTargetVideoFormat,
    zoomFrames: [RecordingProject.ZoomKeyframe],
    motionPlan: AutoZoomMotionPlan?,
    cursorSamples: [RecordingProject.CursorSample],
    cursorHighlightRegions: [RecordingProject.CursorHighlightRegion],
    textOverlays: [RecordingProject.TextOverlayAnnotation],
    cursorClickCues: [RecordingProject.CursorClickCue],
    visualMasks: [RecordingProject.VisualMask],
    cameraLayoutSegments: [RecordingProject.CameraLayoutSegment],
    cursorVisualSettings: RecordingProject.CursorVisualSettings,
    styleSettings: RecordingProject.StyleSettings,
    exportVisualSettings: RecordingProject.ExportVisualSettings,
    sourceKind: RecordingProject.SourceKind
  ) throws -> (AVAssetReaderVideoCompositionOutput, AVAssetWriterInput) {
    let (mainNatural, mainPreferred) = try ExportAsyncBridge.runSync {
      async let n = mainVideoTrack.load(.naturalSize)
      async let p = mainVideoTrack.load(.preferredTransform)
      return try await (n, p)
    }
    let mainBaseTransform = mainVideoAspectFitBaseTransform(
      naturalSize: mainNatural,
      preferredTransform: mainPreferred,
      renderSize: target.size
    )
    let mainSourceSize = ExportVideoGeometry.orientedSourceSize(
      naturalSize: mainNatural,
      preferredTransform: mainPreferred
    )
    let pipGeometry: (natural: CGSize, preferred: CGAffineTransform)? = try {
      guard let pipVideoTrack else { return nil }
      let (pipNatural, pipPreferred) = try ExportAsyncBridge.runSync {
        async let n = pipVideoTrack.load(.naturalSize)
        async let p = pipVideoTrack.load(.preferredTransform)
        return try await (n, p)
      }
      return (pipNatural, pipPreferred)
    }()
    let pipBaseTransform: CGAffineTransform? = {
      guard let pipGeometry, let pipAttachment else { return nil }
      return pipVideoAspectFillTransform(
        pipNaturalSize: pipGeometry.natural,
        pipPreferredTransform: pipGeometry.preferred,
        attachment: pipAttachment,
        renderSize: target.size
      )
    }()

    let densifiedCursorSamples = densifyLinearCursorSamples(
      cursorSamples,
      maxGapSeconds: ExportAnimationConstants.cursorInterpolationMaxGapSeconds
    )

    let builderInput = ArcShotCompositionInstructionBuilder.Input(
      mainVideoTrack: mainVideoTrack,
      pipVideoTrack: pipVideoTrack,
      timeRange: compositionInstructionsTimeRange,
      mainBaseTransform: mainBaseTransform,
      mainSourceSize: mainSourceSize,
      pipBaseTransform: pipBaseTransform,
      pipAttachment: pipAttachment,
      pipNaturalSize: pipGeometry?.natural,
      pipPreferredTransform: pipGeometry?.preferred,
      renderSize: target.size,
      zoomFrames: zoomFrames,
      motionPlan: motionPlan,
      cameraLayoutSegments: cameraLayoutSegments,
      cursorSamples: densifiedCursorSamples,
      cursorClickCues: cursorClickCues,
      cursorHighlightRegions: cursorHighlightRegions,
      cursorVisualSettings: cursorVisualSettings,
      textOverlays: textOverlays,
      visualMasks: visualMasks,
      styleSettings: styleSettings,
      exportVisualSettings: exportVisualSettings,
      sourceKind: sourceKind,
      timedDataOffsetSeconds: timedDataOffsetSeconds
    )

    var compositionConfiguration = AVVideoComposition.Configuration()
    compositionConfiguration.renderSize = target.size
    compositionConfiguration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(target.frameRate))
    compositionConfiguration.instructions = ArcShotCompositionInstructionBuilder.build(input: builderInput)
    compositionConfiguration.customVideoCompositorClass = ArcShotVideoCompositor.self
    let composition = AVVideoComposition(configuration: compositionConfiguration)

    var readerTracks = [mainVideoTrack]
    if let pipVideoTrack { readerTracks.append(pipVideoTrack) }

    let output = AVAssetReaderVideoCompositionOutput(videoTracks: readerTracks, videoSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.videoComposition = composition
    output.alwaysCopiesSampleData = false

    let bitrate = target.videoBitrateMbps * 1_000_000
    var compressionProps: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoExpectedSourceFrameRateKey: target.frameRate,
      AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
      AVVideoAllowFrameReorderingKey: true,
    ]
    switch preset.codec {
    case .h264:
      compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    case .hevc:
      compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel
    }

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: preset.codec.avType,
      AVVideoWidthKey: Int(target.size.width),
      AVVideoHeightKey: Int(target.size.height),
      AVVideoCompressionPropertiesKey: compressionProps,
    ])
    videoInput.expectsMediaDataInRealTime = false

    return (output, videoInput)
  }

  static func makeAudioPipeline(
    asset: AVAsset,
    audioSettings: RecordingProject.AudioTrackSettings,
    audioSegments: [RecordingProject.AudioTimelineSegment] = [],
    compositionDurationSeconds: Double = 0
  ) throws -> (AVAssetReaderOutput?, AVAssetWriterInput?) {
    let tracks = try ExportAsyncBridge.runSync { try await asset.loadTracks(withMediaType: .audio) }
    guard !tracks.isEmpty else {
      return (nil, nil)
    }

    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ])
    output.audioMix = audioMix(
      for: tracks,
      settings: audioSettings,
      audioSegments: audioSegments,
      compositionDurationSeconds: compositionDurationSeconds
    )
    output.alwaysCopiesSampleData = false

    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 192_000,
    ])
    input.expectsMediaDataInRealTime = false

    return (output, input)
  }

  static func mainVideoAspectFitBaseTransform(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform,
    renderSize: CGSize
  ) -> CGAffineTransform {
    ExportVideoGeometry.aspectFitBaseTransform(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform,
      renderSize: renderSize
    )
  }

  static func pipVideoAspectFillTransform(
    pipNaturalSize: CGSize,
    pipPreferredTransform: CGAffineTransform,
    attachment: RecordingProject.SecondaryRecordingAttachment,
    renderSize: CGSize,
    isMirrored: Bool = false
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

  /// Linearly upsamples cursor samples so keyframe gaps do not exceed `maxGapSeconds` (export-only; does not change the project file).
  static func densifyLinearCursorSamples(
    _ samples: [RecordingProject.CursorSample],
    maxGapSeconds: Double
  ) -> [RecordingProject.CursorSample] {
    guard samples.count >= 2, maxGapSeconds > 1e-9 else { return samples }
    let sorted = samples.sorted { $0.timeSeconds < $1.timeSeconds }
    var out: [RecordingProject.CursorSample] = []
    out.reserveCapacity(sorted.count * 2)
    out.append(sorted[0])
    for i in 1 ..< sorted.count {
      let p1 = sorted[i]
      let p0 = out[out.count - 1]
      let dt = p1.timeSeconds - p0.timeSeconds
      if dt <= 1e-12 { continue }
      if dt > maxGapSeconds {
        let n = max(1, Int(ceil(dt / maxGapSeconds)))
        for k in 1 ..< n {
          let u = Double(k) / Double(n)
          let t = p0.timeSeconds + u * dt
          let x = p0.x + u * (p1.x - p0.x)
          let y = p0.y + u * (p1.y - p0.y)
          let shape = u < 0.5 ? p0.shape : p1.shape
          out.append(RecordingProject.CursorSample(timeSeconds: t, x: x, y: y, shape: shape))
        }
      }
      let last = out[out.count - 1]
      if abs(p1.timeSeconds - last.timeSeconds) > 1e-9 {
        out.append(p1)
      }
    }
    return out
  }

  private static func audioMix(
    for tracks: [AVAssetTrack],
    settings: RecordingProject.AudioTrackSettings,
    audioSegments: [RecordingProject.AudioTimelineSegment],
    compositionDurationSeconds: Double
  ) -> AVAudioMix? {
    let hasExplicitSettings =
      settings.microphone.isEnabled
      || settings.system.isEnabled
      || settings.backgroundMusic.isEnabled
    guard hasExplicitSettings else { return nil }

    let mix = AVMutableAudioMix()
    mix.inputParameters = RecordingProjectAudioMix.makeInputParameters(
      for: tracks,
      settings: settings,
      audioSegments: audioSegments,
      compositionDurationSeconds: compositionDurationSeconds
    )
    return mix
  }
}

enum ExportAnimationConstants {
  static let fadeEpsilonSeconds = 1e-3
  static let clampedFadeMaxFractionPerEnd: Double = 0.49
  static let cursorSize: CGFloat = 18
  static let ringSize: CGFloat = 42
  static let ringPulsePeriodSeconds: CFTimeInterval = 0.35
  static let ringOpacityPulsePeriodSeconds: CFTimeInterval = 0.6
  static let clickCuePulseLeadMatchSeconds: Double = 0.35
  static let clickCuePulseDurationSeconds: CFTimeInterval = 0.32
  /// Opacity fades for CATextLayer overlays (timeline seconds).
  static let textOverlayEdgeFadeSeconds: Double = 0.05
  static let textOverlayBackgroundAlpha: CGFloat = 0.35
  static let textOverlayCornerRadiusPts: CGFloat = 6
  /// Insert linearly interpolated cursor samples so gaps are at most this long.
  static let cursorInterpolationMaxGapSeconds: Double = 1.0 / 60.0
}
