import AppKit
import AVFoundation
import CoreMedia
import OSLog
import SwiftUI

/// メインウィンドウの `RecordView` とフローティングランチャーで共有する「停止→プロジェクト化→編集」のフロー。
@MainActor
enum RecordingSessionFinalization {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.arcshot.ArcShot",
    category: "CapturePipeline"
  )

  private enum Constants {
    /// アセット直下の_duration_が未定義になりがちでも、ビデオトラック側で実尺がある場合がある。
    static let minimumPlayableRecordingSeconds = 0.1
    /// メタ読みだけ欠けるとき、UI クロックで「十分録っている」とみなせる下限。
    static let reliableRecordedClockSecondsHint: Double = 0.85
    static let minBytesWhenUsingClockFallback: Int64 = 128_000
    static let minReasonableRecordedFileBytes: Int64 = 768
  }

  /// 録画停止後にプロジェクトを作成し、編集タブへ移動する（フローティングバーの「停止」および `RecordView` の録画終了）。
  @MainActor
  static func finalizeAfterUserStoppedRecording(
    coordinator: RecordingCoordinator,
    projectStore: ProjectStore,
    workflowNav: WorkflowNavigator,
    alertCenter: AppAlertCenter,
    selectedSource: CaptureSource?
  ) async {
    guard coordinator.state == .finished, let url = coordinator.lastOutputURL else {
      logger.error("postStopFinalizeSkipped state=\(coordinator.state.rawValue, privacy: .public) hasOutput=\((coordinator.lastOutputURL != nil), privacy: .public)")
      return
    }
    guard coordinator.tryAcquirePostStopFinalizeSlot() else {
      logger.debug("postStopFinalizeSkipped reason=slot-already-held")
      return
    }
    logger.info("postStopFinalizeStarted output=\(url.lastPathComponent, privacy: .public)")

    ArcShotRuntime.shared.hideCaptureSurfacesForEditor()
    coordinator.setFinalizingStoppedRecording(true)
    defer {
      coordinator.setFinalizingStoppedRecording(false)
      coordinator.releasePostStopFinalizeSlot()
    }

    let finalizeStartedAt = CFAbsoluteTimeGetCurrent()
    let recorderElapsedSeconds = coordinator.recordingElapsedSeconds
    let fileSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

    let canTrustRecorderClock =
      recorderElapsedSeconds >= Constants.reliableRecordedClockSecondsHint
      && Int64(fileSizeBytes) >= Constants.minBytesWhenUsingClockFallback

    if !canTrustRecorderClock {
      let isPlayable = await isPlayableRecording(
        url: url,
        recorderElapsedSeconds: recorderElapsedSeconds
      )
      guard isPlayable else {
        alertCenter.present(
          "録画ファイルを読み込めませんでした（映像トラックまたは長さを認識できません）。「画面収録」の許可とディスク容量を確認し、あらためて数秒録画してから停止してください。"
        )
        coordinator.resetCaptureOutputsAfterFailedFinalize()
        return
      }
    }

    let src = makeSourceDescriptor(from: selectedSource)
    var project = RecordingProject.default(mediaURL: url, source: src)
    project.cursorSamples = coordinator.takeCursorSamples()
    project.inputEvents = coordinator.takeInputEvents()
    project.audioTrackSettings = coordinator.makeAudioTrackSettingsForLastRecording()
    let durationSeconds: Double
    let orientedVideoSize: CGSize
    async let orientedVideoSizeTask = loadOrientedVideoSize(url: url)
    if canTrustRecorderClock {
      durationSeconds = recorderElapsedSeconds
    } else {
      durationSeconds = await loadDurationSeconds(
        url: url,
        recorderElapsedFallback: recorderElapsedSeconds
      )
    }
    orientedVideoSize = await orientedVideoSizeTask
    let stagedCameraSourceURL = coordinator.stagedCameraURLForProjectHandoff
    project.timeline = RecordingProject.TimelineModel.singleClip(
      mediaURL: url,
      assetDurationSeconds: durationSeconds
    )
    project.cursorClickCues = realClickCues(from: project.inputEvents, fallbackSamples: project.cursorSamples)
    if let camURL = stagedCameraSourceURL {
      let videoWidth = Double(orientedVideoSize.width)
      let videoHeight = Double(orientedVideoSize.height)
      project.secondaryRecording = RecordingProject.SecondaryRecordingAttachment.defaultedBottomTrailingPiP(
        mediaURL: camURL,
        videoWidth: videoWidth,
        videoHeight: videoHeight
      )
      project.cameraLayoutSegments = [
        RecordingProject.CameraLayoutSegment.defaultPIP(
          durationSeconds: durationSeconds,
          videoWidth: videoWidth,
          videoHeight: videoHeight
        ),
      ]
    }
    RecordingProject.ensureAudioTimelineSegments(
      &project,
      durationSeconds: durationSeconds
    )
    RecordingProject.ensureCameraLayoutSegments(
      &project,
      durationSeconds: durationSeconds,
      videoWidth: Double(orientedVideoSize.width),
      videoHeight: Double(orientedVideoSize.height)
    )
    projectStore.setCurrent(project)
    workflowNav.sidebarTab = .edit
    UserDefaults.standard.set(true, forKey: AppIdentifiers.UserDefaultsKeys.recordingPermissionIntroCompleted)

    coordinator.resetAfterProjectHandoff()
    NSApp.activate(ignoringOtherApps: true)
    MainWorkspaceWindow.presentKey()

    let editorOpenMs = Int((CFAbsoluteTimeGetCurrent() - finalizeStartedAt) * 1000)
    logger.info("postStopFinalizeEditorPresented output=\(url.lastPathComponent, privacy: .public) ms=\(editorOpenMs, privacy: .public)")

    let projectID = project.id
    let cameraSourceForPersist = stagedCameraSourceURL
    Task { @MainActor in
      var updated = projectStore.current
      guard updated?.id == projectID else { return }

      if let cameraSourceForPersist {
        if let durableURL = await coordinator.persistStagedCameraRecordingIfNeeded(from: cameraSourceForPersist),
          durableURL != cameraSourceForPersist {
          updated?.secondaryRecording = RecordingProject.SecondaryRecordingAttachment.defaultedBottomTrailingPiP(
            mediaURL: durableURL,
            videoWidth: Double(orientedVideoSize.width),
            videoHeight: Double(orientedVideoSize.height)
          )
        }
        coordinator.consumeStagedCameraAttachment()
      }

      let suggestedZoomSegments = CursorZoomHeuristics.suggestZoomKeyframes(
        samples: updated?.cursorSamples ?? [],
        clickCues: updated?.cursorClickCues ?? [],
        assetDurationSeconds: durationSeconds,
        existingKeyframes: []
      ).map { keyframe in
        RecordingProject.ZoomSegment(
          id: keyframe.id,
          startSeconds: keyframe.startSeconds,
          endSeconds: keyframe.endSeconds,
          mode: .auto,
          scale: keyframe.scale,
          anchorX: keyframe.anchorX,
          anchorY: keyframe.anchorY,
          followsClick: true
        )
      }
      updated?.zoomSegments = RecordingProject.sanitizedZoomSegments(
        suggestedZoomSegments,
        durationSeconds: durationSeconds
      )
      if let updated {
        projectStore.setCurrent(updated)
        projectStore.saveCurrent()
        projectStore.presentQuickShare(for: updated.id)
      }
    }

  }

  static func makeSourceDescriptor(from source: CaptureSource?) -> RecordingProject.Source {
    switch source {
    case .systemPickerSelection(let selection):
      let kind: RecordingProject.SourceKind = selection.style == .display ? .display : .window
      return .init(kind: kind, displayID: nil, windowID: nil)
    case .none:
      return .init(kind: .window, displayID: nil, windowID: nil)
    }
  }

  private static func realClickCues(
    from inputEvents: [RecordingProject.InputEvent],
    fallbackSamples: [RecordingProject.CursorSample]
  ) -> [RecordingProject.CursorClickCue] {
    let real = inputEvents
      .filter { $0.kind == .mouseDown }
      .map { RecordingProject.CursorClickCue(timeSeconds: $0.timeSeconds) }
    if !real.isEmpty {
      return RecordingProject.clampedSortedClickCueTimes(
        real,
        compositionDurationSeconds: inputEvents.last?.timeSeconds ?? 0
      )
    }
    return CursorClickHeuristics.suggestClickCues(samples: fallbackSamples, existing: [])
  }

  /// メタ読み込みモードにより `duration` とトラックの `timeRange` が未定義になりにくくする。
  private static func makeVerificationAsset(url: URL) -> AVURLAsset {
    AVURLAsset(
      url: url,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
  }

  private static func loadOrientedVideoSize(url: URL) async -> CGSize {
    let asset = makeVerificationAsset(url: url)
    do {
      let tracks = try await asset.loadTracks(withMediaType: .video)
      guard let track = tracks.first else {
        return CGSize(width: 1920, height: 1080)
      }
      let naturalSize = try await track.load(.naturalSize)
      let preferredTransform = try await track.load(.preferredTransform)
      return ExportVideoGeometry.orientedSourceSize(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      )
    } catch {
      return CGSize(width: 1920, height: 1080)
    }
  }

  /// `duration.isNumeric` が false に落ちやすくても、`CMTime` が妥当な値を返すことがあるため二段構えにする。
  private static func bestEffortPositiveSeconds(for time: CMTime) -> Double? {
    if time.isNumeric, time.seconds.isFinite, !time.seconds.isNaN {
      let s = time.seconds
      guard s >= 0 else { return nil }
      return s
    }
    if time.isIndefinite || time == .invalid { return nil }
    let s = CMTimeGetSeconds(time)
    guard s.isFinite, !s.isNaN, s >= 0 else { return nil }
    return s
  }

  /// `AVAsset.duration` が非 numeric（NaN／不定）になりがちでも、書き込み済みビデオトラックから実尺が取れるケースがある。
  private static func resolvedVideoDurationSeconds(
    assetDuration: CMTime,
    videoTrackDuration: CMTime
  ) -> Double? {
    let values = [bestEffortPositiveSeconds(for: assetDuration),
                  bestEffortPositiveSeconds(for: videoTrackDuration)]
      .compactMap(\.self)
    guard !values.isEmpty else { return nil }
    return values.max()
  }

  private static func isPlayableRecording(url: URL, recorderElapsedSeconds: Double) async -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }

    let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard Int64(sizeBytes) > Constants.minReasonableRecordedFileBytes else { return false }

    let asset = makeVerificationAsset(url: url)
    do {
      let assetDuration = try await asset.load(.duration)
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let primaryVideoTrack = videoTracks.first else {
        return false
      }

      let timeRange = try await primaryVideoTrack.load(.timeRange)
      let seconds = resolvedVideoDurationSeconds(
        assetDuration: assetDuration,
        videoTrackDuration: timeRange.duration
      )

      if let seconds, seconds >= Constants.minimumPlayableRecordingSeconds {
        return true
      }

      // メタだけ欠けるが実データは書けているときの保険：ビデオトラックがある＋十分なサイズ＋クロック経過時間。
      if recorderElapsedSeconds >= Constants.reliableRecordedClockSecondsHint,
        Int64(sizeBytes) >= Constants.minBytesWhenUsingClockFallback {
        let formatDescriptions = try await primaryVideoTrack.load(.formatDescriptions)
        if !formatDescriptions.isEmpty {
          return true
        }
      }

      return false
    } catch {
      return false
    }
  }

  private static func loadDurationSeconds(url: URL, recorderElapsedFallback: Double) async -> Double {
    let asset = makeVerificationAsset(url: url)
    do {
      let assetDuration = try await asset.load(.duration)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      guard let primary = tracks.first else {
        return max(0, recorderElapsedFallback)
      }
      let timeRange = try await primary.load(.timeRange)
      let merged = resolvedVideoDurationSeconds(
        assetDuration: assetDuration,
        videoTrackDuration: timeRange.duration
      )

      if let merged, merged >= Constants.minimumPlayableRecordingSeconds {
        return merged
      }

      if recorderElapsedFallback >= Constants.minimumPlayableRecordingSeconds {
        return recorderElapsedFallback
      }

      return merged ?? 0
    } catch {
      return max(0, recorderElapsedFallback)
    }
  }
}
