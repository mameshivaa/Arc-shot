import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  @Environment(WorkflowNavigator.self) private var workflowNav
  @Environment(AppLanguageStore.self) private var languageStore

  @State private var playback = EditorPlaybackController()
  @State private var exporter = Exporter()
  @State private var captionGenerator = CaptionGenerator()
  @State private var timelineUndo = ReviewTimelineUndoController()

  @State private var selectedInspector: EditorInspectorSection = .background
  @State private var backgroundMode: EditorBackgroundMode = .wallpaper
  @State private var previewScale: Double = 1
  @State private var timelinePaneHeight = EditorLayout.loadStoredTimelinePaneHeight()
  @State private var trimProjectID: UUID?
  @State private var clipStartSeconds: Double = 0
  @State private var clipEndSeconds: Double = 0
  @State private var selectedTimelineClipID: UUID?
  @State private var selectedTimelineEffect: EditorTimelineEffectSelection?
  @State private var liveZoomPreviewRange: EditorLiveZoomPreviewRange?
  @State private var lastExportOutputURL: URL?
  @State private var previewAudioTrackSettings = RecordingProject.AudioTrackSettings()
  @State private var showingCommandMenu = false

  private var selectedTimelineZoomID: UUID? {
    guard case .zoom(let id) = selectedTimelineEffect else { return nil }
    return id
  }

  private var selectedTimelineMaskID: UUID? {
    guard case .mask(let id) = selectedTimelineEffect else { return nil }
    return id
  }

  private var selectedTimelineCameraID: UUID? {
    guard case .camera(let id) = selectedTimelineEffect else { return nil }
    return id
  }

  var body: some View {
    Group {
      if let project = projectStore.current {
        editorWorkspace(project: project)
      } else {
        editorEmptyState
      }
    }
    .onDisappear {
      playback.pause()
    }
    .onChange(of: exporter.state) { _, state in
      guard case .failed(let message) = state else { return }
      alertCenter.present(message)
    }
  }

  private func editorWorkspace(project: RecordingProject) -> some View {
    VStack(spacing: 0) {
      EditorTopBar(
        title: languageStore.localizedProjectDisplayTitle(
          storedTitle: project.title,
          createdAt: project.createdAt
        ),
        metadata: project.mediaURL.lastPathComponent,
        isExporting: isExporting,
        commandAction: { showingCommandMenu = true },
        exportAction: { export(project: project) }
      )

      if shouldShowExportStatus {
        ExportStatusBanner(
          state: exporter.state,
          progress: exporter.progress,
          outputURL: lastExportOutputURL,
          cancelAction: { exporter.stop() },
          revealAction: revealLastExport,
          retryAction: { retryLastExport(project: projectStore.current ?? project) },
          chooseDestinationAction: { export(project: projectStore.current ?? project) }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }

      HStack(spacing: 0) {
        VStack(spacing: 0) {
          EditorPreviewTimelineSplit(
            timelinePaneHeight: $timelinePaneHeight,
            onTimelinePaneHeightCommitted: { EditorLayout.saveTimelinePaneHeight($0) },
            preview: {
              StyledVideoPreview(
                project: project,
                player: playback.player,
                currentSeconds: playback.currentTimeSeconds,
                durationSeconds: playback.durationSeconds,
                sourceDurationSeconds: playback.sourceDurationSeconds,
                isPlaying: playback.isPlaying,
                sourceVideoSize: playback.sourceVideoSize,
                previewScale: $previewScale,
                backgroundMode: backgroundMode,
                selectedZoomID: selectedTimelineZoomID,
                selectedMaskID: selectedTimelineMaskID,
                selectedCameraID: selectedTimelineCameraID,
                liveZoomPreviewRange: liveZoomPreviewRange,
                usesStandaloneChrome: false,
                onUpdateZoomTargetRegion: updateZoomTargetRegion,
                onUpdateMaskRegion: updateMaskRegion,
                onUpdateCameraRegion: updateCameraRegion
              )
            },
            timeline: {
              EditorTimelineView(
                project: project,
                durationSeconds: editorTimelineDuration(project: project),
                sourceDurationSeconds: playback.sourceDurationSeconds,
                currentSeconds: playback.currentTimeSeconds,
                isPlaying: playback.isPlaying,
                clipStartSeconds: $clipStartSeconds,
                clipEndSeconds: $clipEndSeconds,
                selectedClipID: $selectedTimelineClipID,
                selectedEffect: $selectedTimelineEffect,
                usesStandaloneChrome: false,
                onSeek: { seconds, completion in playback.seek(to: seconds, completion: completion) },
                onTogglePlayback: { playback.togglePlayback() },
                onSeekBy: { playback.seek(by: $0) },
                onTrimDragBegan: { playback.beginTimelineInteraction() },
                onTrimDragEnded: { playback.endTimelineInteraction() },
                onTrimCommit: { completion in
                  persistClipBounds(reloadPlayer: false, completion: completion)
                },
                onUndo: undoTimelineEdit,
                onRedo: redoTimelineEdit,
                onDeleteClip: deleteSelectedTimelineClip,
                onDeleteEffect: deleteSelectedTimelineEffect,
                onSetClipSpeed: setSelectedTimelineClipSpeed,
                onSetTrimInAtPlayhead: setTrimInAtPlayhead,
                onSetTrimOutAtPlayhead: setTrimOutAtPlayhead,
                onPlayheadDragBegan: { playback.beginTimelineInteraction() },
                onPlayheadDragEnded: { playback.endTimelineInteraction() },
                onMoveClip: moveTimelineClip,
                onSelectEffect: selectTimelineEffect,
                onPreviewZoomEffectRange: previewZoomEffectRange,
                onEndPreviewZoomEffectRange: { liveZoomPreviewRange = nil },
                onCommitZoomEffectRange: commitZoomEffectRange,
                onCommitCaptionEffectRange: commitCaptionEffectRange,
                onCommitMaskEffectRange: commitMaskEffectRange,
                onCommitCameraEffectRange: commitCameraEffectRange,
                onCommitAudioEffectRange: commitAudioEffectRange,
                onCommitUnifiedAudioEffectRange: commitUnifiedAudioEffectRange
              )
            }
          )
        }
        .padding(.horizontal, EditorLayout.workspaceMargin)
        .padding(.top, EditorLayout.workspaceMargin)
        .padding(.bottom, EditorLayout.workspaceBottomMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        EditorInspectorPanel(
          project: project,
          durationSeconds: editorSourceDurationSeconds,
          currentPlayheadSeconds: sourceSecondsForCurrentPreview(project: project),
          selectedSection: $selectedInspector,
          selectedTimelineEffect: $selectedTimelineEffect,
          backgroundMode: $backgroundMode,
          updateVisuals: updateExportVisuals,
          onAddZoom: addZoomAtCurrentPlayhead,
          onCommitZoomEffectRange: commitZoomEffectRange,
          onCommitCaptionEffectRange: commitCaptionEffectRange,
          onCommitMaskEffectRange: commitMaskEffectRange,
          isExporting: isExporting,
          exportAction: { export(project: projectStore.current ?? project) },
          captionGenerator: captionGenerator
        )
        .frame(width: EditorLayout.inspectorWidth)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(EditorPalette.windowBackground)
    .overlay(alignment: .topLeading) {
      EditorKeyboardShortcuts(
        onTogglePlayback: { playback.togglePlayback() },
        onUndo: undoTimelineEdit,
        onRedo: redoTimelineEdit,
        onSeekBack: { playback.seek(by: -0.05) },
        onSeekForward: { playback.seek(by: 0.05) },
        onPreviousFrame: { playback.seek(by: -1.0 / 60.0) },
        onNextFrame: { playback.seek(by: 1.0 / 60.0) },
        onCommandMenu: { showingCommandMenu = true }
      )
    }
    .task(id: project.id) {
      timelineUndo.projectStore = projectStore
      let duration = max(playback.sourceDurationSeconds, playback.durationSeconds)
      if duration > RecordingProject.TimelineMediaEditing.minAudioSpanSeconds {
        projectStore.applyToCurrent { current in
          RecordingProject.ensureAudioTimelineSegments(
            &current,
            durationSeconds: duration
          )
          RecordingProject.ensureCameraLayoutSegments(
            &current,
            durationSeconds: duration
          )
        }
      }
      syncPlaybackPreviewRange(project: project)
      playback.load(project: project)
      previewAudioTrackSettings = project.audioTrackSettings
      syncClipBoundaryState(project: project, force: true)
      backgroundMode = EditorBackgroundMode(settings: project.exportVisualSettings)
    }
    .onChange(of: playback.sourceDurationSeconds) { _, seconds in
      guard seconds > RecordingProject.TimelineMediaEditing.minAudioSpanSeconds, let current = projectStore.current else { return }
      projectStore.applyToCurrent { project in
        RecordingProject.ensureAudioTimelineSegments(&project, durationSeconds: seconds)
        RecordingProject.ensureCameraLayoutSegments(&project, durationSeconds: seconds)
      }
      let shouldReload = !current.timeline.hasActiveClips
      ensureTimelineClipForEditor(project: current, assetDurationSeconds: seconds)
      let updated = projectStore.current ?? current
      syncClipBoundaryState(project: updated, force: true)
      syncPlaybackPreviewRange(project: updated)
      if shouldReload, let updated = projectStore.current {
        playback.load(project: updated, force: true)
      }
    }
    .onChange(of: playback.durationSeconds) { _, seconds in
      let current = projectStore.current ?? project
      guard current.timeline.singleEditableClip == nil else { return }
      if playback.sourceDurationSeconds <= 0, clipEndSeconds <= 0 || clipEndSeconds > seconds {
        clipEndSeconds = max(0, seconds)
      }
    }
    .onChange(of: backgroundMode) { _, mode in
      applyBackgroundMode(mode)
    }
    .onChange(of: project) { _, updatedProject in
      clearMissingTimelineEffectSelection(project: updatedProject)
      syncPlaybackPreviewRange(project: updatedProject)
    }
    .onChange(of: project.audioTrackSettings) { _, settings in
      applyAudioSettingsToPreview(settings, project: projectStore.current ?? project)
    }
    .onChange(of: project.audioTimelineSegments) { _, _ in
      if let current = projectStore.current {
        playback.applyAudioSettings(project: current)
      }
    }
    .sheet(isPresented: $showingCommandMenu) {
      EditorCommandMenu(
        project: projectStore.current ?? project,
        isExporting: isExporting,
        dismiss: { showingCommandMenu = false },
        perform: performCommand
      )
      .environment(projectStore)
      .environment(alertCenter)
      .frame(width: 460, height: 420)
    }
    .sheet(isPresented: quickShareBinding(projectID: project.id)) {
      QuickSharePanel(
        project: projectStore.current ?? project,
        onEdit: {
          projectStore.dismissQuickShare()
        },
        onDiscard: {
          projectStore.deleteProject(id: project.id)
          workflowNav.sidebarTab = .capture
        }
      )
      .environment(projectStore)
      .environment(alertCenter)
      .frame(width: 420)
    }
  }

  private var editorEmptyState: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("編集できるプロジェクトがありません")
        .font(.title3.weight(.semibold))
      Text("録画を停止すると、ここに編集画面が開きます。")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(24)
  }

  private var isExporting: Bool {
    if case .exporting = exporter.state { return true }
    return false
  }

  private var shouldShowExportStatus: Bool {
    switch exporter.state {
    case .idle:
      return false
    case .exporting, .finished, .failed:
      return true
    }
  }

  private func syncClipBoundaryState(project: RecordingProject, force: Bool = false) {
    guard force || trimProjectID != project.id else { return }
    trimProjectID = project.id
    if let clip = project.timeline.singleEditableClip {
      let sourceRange = project.timeline.sourceRange(for: clip)
      clipStartSeconds = max(0, clip.sourceStartSeconds)
      clipEndSeconds = max(clipStartSeconds, sourceRange.endSeconds)
    } else {
      clipStartSeconds = 0
      clipEndSeconds = max(0, playback.sourceDurationSeconds)
    }
  }

  private func ensureTimelineClipForEditor(project: RecordingProject, assetDurationSeconds: Double) {
    guard assetDurationSeconds > RecordingProject.TimelineEditing.minInteractiveClipDurationSeconds else { return }
    guard !project.timeline.hasActiveClips else { return }
    projectStore.applyToCurrent { project in
      project.timeline.ensureSingleEditableClip(
        mediaURL: project.mediaURL,
        assetDurationSeconds: assetDurationSeconds
      )
    }
  }

  private func persistClipBounds(
    reloadPlayer: Bool = false,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    let assetDuration = max(playback.sourceDurationSeconds, clipEndSeconds)
    guard assetDuration > RecordingProject.TimelineEditing.minInteractiveClipDurationSeconds else {
      completion()
      return
    }
    let start = max(0, min(clipStartSeconds, assetDuration))
    let end = max(start, min(clipEndSeconds, assetDuration))
    projectStore.applyToCurrent { project in
      project.timeline.ensureSingleEditableClip(
        mediaURL: project.mediaURL,
        assetDurationSeconds: assetDuration
      )
      _ = project.timeline.setSingleClipLeadingSourceSeconds(start, assetDurationSeconds: assetDuration)
      _ = project.timeline.setSingleClipTrailingSourceSeconds(end, assetDurationSeconds: assetDuration)
    }
    if let current = projectStore.current {
      syncPlaybackPreviewRange(project: current)
    }
    guard reloadPlayer, let current = projectStore.current else {
      completion()
      return
    }
    playback.load(project: current, force: true, completion: completion)
  }

  private func editorTimelineDuration(project: RecordingProject) -> Double {
    if project.timeline.singleEditableClip != nil,
      playback.sourceDurationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds {
      return playback.sourceDurationSeconds
    }
    let timelineDuration = project.timeline.activeDurationSeconds
    return timelineDuration > RecordingProject.TimelineEditing.minClipDurationSeconds
      ? timelineDuration
      : playback.durationSeconds
  }

  private func syncPlaybackPreviewRange(project: RecordingProject) {
    if let clip = project.timeline.singleEditableClip {
      let sourceRange = project.timeline.sourceRange(for: clip)
      playback.updatePreviewRange(
        sourceStartSeconds: sourceRange.startSeconds,
        sourceEndSeconds: sourceRange.endSeconds,
        playbackRate: project.timeline.speedRate(for: clip)
      )
    } else {
      playback.clearPreviewRange()
    }
  }

  private func applyAudioSettingsToPreview(
    _ settings: RecordingProject.AudioTrackSettings,
    project: RecordingProject
  ) {
    let needsCompositionReload =
      previewAudioTrackSettings.backgroundMusic.isEnabled != settings.backgroundMusic.isEnabled
      || previewAudioTrackSettings.backgroundMusicURL != settings.backgroundMusicURL
    previewAudioTrackSettings = settings
    if needsCompositionReload {
      playback.load(project: project, force: true)
    } else {
      playback.applyAudioSettings(project: project)
    }
  }

  private var editorSourceDurationSeconds: Double {
    max(playback.sourceDurationSeconds, playback.durationSeconds)
  }

  private func sourceSecondsForCurrentPreview(project: RecordingProject) -> Double {
    project.sourceSecondsForPreviewPlayback(playback.currentTimeSeconds)
  }

  private func undoTimelineEdit() {
    timelineUndo.undoManager.undo()
    if let current = projectStore.current {
      playback.load(project: current, force: true)
    }
  }

  private func redoTimelineEdit() {
    timelineUndo.undoManager.redo()
    if let current = projectStore.current {
      playback.load(project: current, force: true)
    }
  }

  private func deleteSelectedTimelineClip() {
    guard let selectedTimelineClipID,
      let before = projectStore.current
    else { return }
    var after = before
    guard after.timeline.deleteClip(id: selectedTimelineClipID) else { return }
    self.selectedTimelineClipID = after.timeline.activeClips.first?.id
    timelineUndo.finalizeWholeProjectUndo(undoLabel: "クリップを削除", before: before, after: after)
    syncPlaybackPreviewRange(project: after)
    playback.load(project: after, force: true)
  }

  private func deleteSelectedTimelineEffect() {
    guard let selectedTimelineEffect,
      let before = projectStore.current
    else { return }
    var after = before
    guard EditorTimelineEffectSelection.remove(
      selectedTimelineEffect,
      from: &after,
      durationSeconds: editorSourceDurationSeconds
    ) else { return }
    self.selectedTimelineEffect = nil
    liveZoomPreviewRange = nil
    timelineUndo.finalizeWholeProjectUndo(undoLabel: "効果を削除", before: before, after: after)
    playback.load(project: after, force: true)
  }

  private func commitZoomEffectRange(
    id: UUID,
    startSeconds: Double,
    inEndSeconds: Double,
    outStartSeconds: Double,
    endSeconds: Double
  ) {
    guard let before = projectStore.current,
      let index = before.zoomSegments.firstIndex(where: { $0.id == id })
    else { return }

    var after = before
    after.zoomSegments[index].startSeconds = startSeconds
    after.zoomSegments[index].inEndSeconds = inEndSeconds
    after.zoomSegments[index].outStartSeconds = outStartSeconds
    after.zoomSegments[index].endSeconds = endSeconds
    after.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
      after.zoomSegments,
      durationSeconds: editorSourceDurationSeconds,
      resolvingSegmentID: id,
      mode: .move,
      moveReferenceStart: before.zoomSegments[index].startSeconds
    )
    guard before != after else { return }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: "ズーム範囲を調整", before: before, after: after)
  }

  private func previewZoomEffectRange(
    id: UUID,
    startSeconds: Double,
    inEndSeconds: Double,
    outStartSeconds: Double,
    endSeconds: Double
  ) {
    liveZoomPreviewRange = EditorLiveZoomPreviewRange(
      id: id,
      startSeconds: startSeconds,
      inEndSeconds: inEndSeconds,
      outStartSeconds: outStartSeconds,
      endSeconds: endSeconds
    )
  }

  private func updateMaskRegion(id: UUID, originXN: Double, originYN: Double, widthN: Double, heightN: Double) {
    projectStore.applyToCurrent { project in
      guard let index = project.visualMasks.firstIndex(where: { $0.id == id }) else { return }
      project.visualMasks[index].originXN = originXN
      project.visualMasks[index].originYN = originYN
      project.visualMasks[index].widthN = widthN
      project.visualMasks[index].heightN = heightN
      project.visualMasks = RecordingProject.sanitizedVisualMasks(
        project.visualMasks,
        durationSeconds: editorSourceDurationSeconds
      )
    }
  }

  private func updateZoomTargetRegion(id: UUID, targetX: Double, targetY: Double, targetWidth: Double, targetHeight: Double) {
    projectStore.applyToCurrent { project in
      guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
      project.zoomSegments[index].targetX = targetX
      project.zoomSegments[index].targetY = targetY
      project.zoomSegments[index].targetWidth = targetWidth
      project.zoomSegments[index].targetHeight = targetHeight
      project.zoomSegments[index].syncLegacyZoomFromTargetRegion()
      project.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
        project.zoomSegments,
        durationSeconds: editorSourceDurationSeconds
      )
    }
  }

  private func commitCaptionEffectRange(id: UUID, startSeconds: Double, endSeconds: Double) {
    guard let before = projectStore.current,
      let index = before.captionTrack.segments.firstIndex(where: { $0.id == id })
    else { return }

    var after = before
    let range = TimelineEditableRange(
      id: id,
      kind: .caption,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    .sanitized(durationSeconds: editorSourceDurationSeconds)
    after.captionTrack.segments[index].startSeconds = range.startSeconds
    after.captionTrack.segments[index].endSeconds = range.endSeconds
    guard before != after else { return }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: "字幕範囲を調整", before: before, after: after)
  }

  private func commitMaskEffectRange(id: UUID, startSeconds: Double, endSeconds: Double) {
    guard let before = projectStore.current,
      let index = before.visualMasks.firstIndex(where: { $0.id == id })
    else { return }

    var after = before
    after.visualMasks[index].startSeconds = startSeconds
    after.visualMasks[index].endSeconds = endSeconds
    after.visualMasks = RecordingProject.sanitizedVisualMasks(
      after.visualMasks,
      durationSeconds: editorSourceDurationSeconds
    )
    guard before != after else { return }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: "マスク範囲を調整", before: before, after: after)
  }

  private func commitCameraEffectRange(id: UUID, startSeconds: Double, endSeconds: Double) {
    guard let before = projectStore.current,
      let index = before.cameraLayoutSegments.firstIndex(where: { $0.id == id })
    else { return }

    var after = before
    let range = TimelineEditableRange(
      id: id,
      kind: .camera,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      minDuration: RecordingProject.TimelineMediaEditing.minCameraSpanSeconds,
      canTrim: true,
      canMove: false
    )
    .sanitized(durationSeconds: editorSourceDurationSeconds)
    after.cameraLayoutSegments[index].startSeconds = range.startSeconds
    after.cameraLayoutSegments[index].endSeconds = range.endSeconds
    after.cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
      after.cameraLayoutSegments,
      durationSeconds: editorSourceDurationSeconds
    )
    guard before != after else { return }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: "カメラ範囲を調整", before: before, after: after)
  }

  private func commitAudioEffectRange(id: UUID, startSeconds: Double, endSeconds: Double) {
    guard let before = projectStore.current,
      let index = before.audioTimelineSegments.firstIndex(where: { $0.id == id })
    else { return }

    var after = before
    let range = TimelineEditableRange(
      id: id,
      kind: .audio,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      minDuration: RecordingProject.TimelineMediaEditing.minAudioSpanSeconds,
      canTrim: true,
      canMove: false
    )
    .sanitized(durationSeconds: editorSourceDurationSeconds)
    after.audioTimelineSegments[index].startSeconds = range.startSeconds
    after.audioTimelineSegments[index].endSeconds = range.endSeconds
    after.audioTimelineSegments = RecordingProject.sanitizedAudioTimelineSegments(
      after.audioTimelineSegments,
      durationSeconds: editorSourceDurationSeconds,
      settings: after.audioTrackSettings
    )
    guard before != after else { return }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: "音声範囲を調整", before: before, after: after)
    playback.applyAudioSettings(project: after)
  }

  private func commitUnifiedAudioEffectRange(startSeconds: Double, endSeconds: Double) {
    guard let before = projectStore.current else { return }
    var after = before
    let duration = editorSourceDurationSeconds
    let range = TimelineEditableRange(
      id: UUID(),
      kind: .audio,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      minDuration: RecordingProject.TimelineMediaEditing.minAudioSpanSeconds,
      canTrim: true,
      canMove: false
    )
    .sanitized(durationSeconds: duration)
    guard !after.audioTimelineSegments.isEmpty else { return }

    for index in after.audioTimelineSegments.indices {
      after.audioTimelineSegments[index].startSeconds = range.startSeconds
      after.audioTimelineSegments[index].endSeconds = range.endSeconds
    }
    after.audioTimelineSegments = RecordingProject.sanitizedAudioTimelineSegments(
      after.audioTimelineSegments,
      durationSeconds: duration,
      settings: after.audioTrackSettings
    )
    guard before.audioTimelineSegments != after.audioTimelineSegments else { return }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: "音声範囲を調整", before: before, after: after)
    playback.applyAudioSettings(project: after)
  }

  private func updateCameraRegion(id: UUID, originXN: Double, originYN: Double, widthN: Double, heightN: Double) {
    projectStore.applyToCurrent { project in
      guard let index = project.cameraLayoutSegments.firstIndex(where: { $0.id == id }) else { return }
      project.cameraLayoutSegments[index].originXN = originXN
      project.cameraLayoutSegments[index].originYN = originYN
      project.cameraLayoutSegments[index].widthN = widthN
      project.cameraLayoutSegments[index].heightN = heightN
      project.cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
        project.cameraLayoutSegments,
        durationSeconds: editorSourceDurationSeconds
      )
    }
  }

  private func setSelectedTimelineClipSpeed(_ rate: Double) {
    guard let selectedTimelineClipID,
      let before = projectStore.current
    else { return }
    var after = before
    guard after.timeline.setSpeed(rate: rate, forClipID: selectedTimelineClipID) else { return }
    timelineUndo.finalizeWholeProjectUndo(undoLabel: "クリップ速度を変更", before: before, after: after)
    syncPlaybackPreviewRange(project: after)
    playback.load(project: after, force: true)
  }

  private func setTrimInAtPlayhead() {
    if setSelectedMediaSegmentTrimBoundaryAtPlayhead(.leading) { return }
    setSingleClipTrimBoundaryAtPlayhead(.leading)
  }

  private func setTrimOutAtPlayhead() {
    if setSelectedMediaSegmentTrimBoundaryAtPlayhead(.trailing) { return }
    setSingleClipTrimBoundaryAtPlayhead(.trailing)
  }

  @discardableResult
  private func setSelectedMediaSegmentTrimBoundaryAtPlayhead(_ boundary: EditorTimelineActiveTrimHandle) -> Bool {
    guard let before = projectStore.current,
      let selection = selectedTimelineEffect
    else { return false }

    let playhead = sourceSecondsForCurrentPreview(project: before)
    let duration = editorSourceDurationSeconds
    var after = before
    let undoLabel: String
    let didChange: Bool

    switch selection {
    case .audio:
      guard !after.audioTimelineSegments.isEmpty else { return false }
      let minSpan = RecordingProject.TimelineMediaEditing.minAudioSpanSeconds
      var newStart: Double?
      var newEnd: Double?
      switch boundary {
      case .leading:
        let candidate = max(0, min(playhead, after.audioTimelineSegments.map(\.endSeconds).max() ?? playhead - minSpan))
        guard after.audioTimelineSegments.contains(where: { abs($0.startSeconds - candidate) > 1e-9 }) else { return false }
        newStart = candidate
        undoLabel = "音声 In点を移動"
      case .trailing:
        let candidate = min(duration, max(playhead, (after.audioTimelineSegments.map(\.startSeconds).min() ?? 0) + minSpan))
        guard after.audioTimelineSegments.contains(where: { abs($0.endSeconds - candidate) > 1e-9 }) else { return false }
        newEnd = candidate
        undoLabel = "音声 Out点を移動"
      }
      for index in after.audioTimelineSegments.indices {
        if let newStart { after.audioTimelineSegments[index].startSeconds = newStart }
        if let newEnd { after.audioTimelineSegments[index].endSeconds = newEnd }
      }
      after.audioTimelineSegments = RecordingProject.sanitizedAudioTimelineSegments(
        after.audioTimelineSegments,
        durationSeconds: duration,
        settings: after.audioTrackSettings
      )
      didChange = before.audioTimelineSegments != after.audioTimelineSegments
    case .camera(let id):
      guard let index = after.cameraLayoutSegments.firstIndex(where: { $0.id == id }) else { return false }
      let minSpan = RecordingProject.TimelineMediaEditing.minCameraSpanSeconds
      var segment = after.cameraLayoutSegments[index]
      switch boundary {
      case .leading:
        let newStart = max(0, min(playhead, segment.endSeconds - minSpan))
        guard abs(newStart - segment.startSeconds) > 1e-9 else { return false }
        segment.startSeconds = newStart
        undoLabel = "カメラ In点を移動"
      case .trailing:
        let newEnd = min(duration, max(playhead, segment.startSeconds + minSpan))
        guard abs(newEnd - segment.endSeconds) > 1e-9 else { return false }
        segment.endSeconds = newEnd
        undoLabel = "カメラ Out点を移動"
      }
      after.cameraLayoutSegments[index] = segment
      after.cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
        after.cameraLayoutSegments,
        durationSeconds: duration
      )
      didChange = before.cameraLayoutSegments != after.cameraLayoutSegments
    default:
      return false
    }

    guard didChange else { return false }

    timelineUndo.finalizeWholeProjectUndo(undoLabel: undoLabel, before: before, after: after)
    if case .audio = selection {
      playback.applyAudioSettings(project: after)
    }
    return true
  }

  private func setSingleClipTrimBoundaryAtPlayhead(_ boundary: EditorTimelineActiveTrimHandle) {
    guard let before = projectStore.current else { return }
    guard !before.timeline.hasActiveClips || before.timeline.singleEditableClip != nil else {
      return
    }

    var after = before
    let assetDuration = max(playback.sourceDurationSeconds, playback.durationSeconds, clipEndSeconds)
    after.timeline.ensureSingleEditableClip(
      mediaURL: after.mediaURL,
      assetDurationSeconds: assetDuration
    )

    let sourceSeconds = sourceSecondsForCurrentPreview(project: before)
    let didChange: Bool
    switch boundary {
    case .leading:
      didChange = after.timeline.setSingleClipLeadingSourceSeconds(sourceSeconds, assetDurationSeconds: assetDuration)
    case .trailing:
      didChange = after.timeline.setSingleClipTrailingSourceSeconds(sourceSeconds, assetDurationSeconds: assetDuration)
    }
    guard didChange else { return }

    let undoLabel = boundary == .leading ? "In点を移動" : "Out点を移動"
    timelineUndo.finalizeWholeProjectUndo(undoLabel: undoLabel, before: before, after: after)
    syncClipBoundaryState(project: after, force: true)
    syncPlaybackPreviewRange(project: after)
    playback.load(project: after, force: true)
  }

  private func moveTimelineClip(id: UUID, toIndex: Int) {
    guard let before = projectStore.current else { return }
    var after = before
    guard after.timeline.moveClip(id: id, toIndex: toIndex) else { return }
    selectedTimelineClipID = id
    timelineUndo.finalizeWholeProjectUndo(undoLabel: "クリップを並べ替え", before: before, after: after)
    syncPlaybackPreviewRange(project: after)
    playback.load(project: after, force: true)
  }

  private func selectTimelineEffect(_ selection: EditorTimelineEffectSelection) {
    selectedTimelineEffect = selection
    selectedTimelineClipID = nil
    switch selection {
    case .zoom:
      selectedInspector = .zoom
    case .caption:
      selectedInspector = .captions
    case .mask:
      selectedInspector = .mask
    case .camera:
      selectedInspector = .camera
    case .audio:
      selectedInspector = .audio
    }
  }

  private func clearMissingTimelineEffectSelection(project: RecordingProject) {
    guard let selectedTimelineEffect else { return }
    switch selectedTimelineEffect {
    case .zoom(let id):
      if !project.zoomSegments.contains(where: { $0.id == id }) {
        self.selectedTimelineEffect = nil
      }
    case .caption(let id):
      if !project.captionTrack.segments.contains(where: { $0.id == id }) {
        self.selectedTimelineEffect = nil
      }
    case .mask(let id):
      if !project.visualMasks.contains(where: { $0.id == id }) {
        self.selectedTimelineEffect = nil
      }
    case .camera(let id):
      if !project.cameraLayoutSegments.contains(where: { $0.id == id }) {
        self.selectedTimelineEffect = nil
      }
    case .audio(let id):
      if !project.audioTimelineSegments.contains(where: { $0.id == id }) {
        self.selectedTimelineEffect = nil
      }
    }
  }

  private func updateExportVisuals(_ mutate: (inout RecordingProject.ExportVisualSettings) -> Void) {
    projectStore.applyToCurrent { project in
      var visuals = project.exportVisualSettings
      mutate(&visuals)
      visuals.stageStyle = .roundedCard
      visuals.enabledForDisplayCapture = true
      project.exportVisualSettings = visuals
    }
  }

  private func addZoomAtCurrentPlayhead() {
    guard let before = projectStore.current else { return }
    let sourceSeconds = sourceSecondsForCurrentPreview(project: before)
    let peers = TimelineZoomOverlapPolicy.peerIntervals(excludingID: UUID(), segments: before.zoomSegments)
    guard let range = EditorSegmentRange.playheadBasedAvoidingZoomOverlaps(
      at: sourceSeconds,
      preferredDuration: 2.5,
      totalDuration: editorSourceDurationSeconds,
      minimumDuration: RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds,
      peers: peers
    ) else {
      alertCenter.present(title: "ズームを追加できません", "この位置には重ならない隙間がありません。タイムライン上の空いている位置に移動してから追加してください。")
      return
    }

    let timing = TimelineEditableRange.screenStudioTiming(startSeconds: range.start, endSeconds: range.end)
    let center = defaultZoomTargetCenter(project: before, sourceSeconds: sourceSeconds)
    let segmentID = UUID()
    let segment = RecordingProject.ZoomSegment(
      id: segmentID,
      startSeconds: range.start,
      inEndSeconds: timing.inEndSeconds,
      outStartSeconds: timing.outStartSeconds,
      endSeconds: range.end,
      mode: .manual,
      scale: 2.0,
      anchorX: center.x,
      anchorY: center.y
    )

    var after = before
    after.zoomSegments.append(segment)
    after.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
      after.zoomSegments,
      durationSeconds: editorSourceDurationSeconds
    )
    guard before != after else { return }

    selectedInspector = .zoom
    selectedTimelineClipID = nil
    selectedTimelineEffect = .zoom(segmentID)
    timelineUndo.finalizeWholeProjectUndo(undoLabel: "ズームを追加", before: before, after: after)
    playback.load(project: after, force: true)
  }

  private func defaultZoomTargetCenter(
    project: RecordingProject,
    sourceSeconds: Double
  ) -> (x: Double, y: Double) {
    guard let nearest = project.cursorSamples.min(by: {
      abs($0.timeSeconds - sourceSeconds) < abs($1.timeSeconds - sourceSeconds)
    }), abs(nearest.timeSeconds - sourceSeconds) <= 0.5 else {
      return (0.5, 0.5)
    }
    return (
      max(0, min(1, nearest.x)),
      max(0, min(1, nearest.y))
    )
  }

  private func applyBackgroundMode(_ mode: EditorBackgroundMode) {
    updateExportVisuals { visuals in
      switch mode {
      case .wallpaper:
        visuals.backgroundKind = .linearGradientVertical
        visuals.backgroundGradientStyle = .wallpaper
        visuals.backgroundColorHex = RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageBackgroundFallbackHex
        visuals.gradientEndColorHex = RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageGradientEndFallbackHex
      case .gradient:
        visuals.backgroundKind = .linearGradientVertical
        visuals.backgroundGradientStyle = .vertical
      case .color:
        visuals.backgroundKind = .solid
      case .image:
        visuals.backgroundKind = .linearGradientVertical
      }
    }
  }

  private func export(project: RecordingProject) {
    guard !isExporting else { return }
    ExportSavePanelPresenter.chooseDestination(
      allowedContentTypes: [.mpeg4Movie],
      defaultFilename: "ArcShot Export.mp4"
    ) { url in
      lastExportOutputURL = url
      exporter.export(project: projectStore.current ?? project, to: url)
    }
  }

  private func retryLastExport(project: RecordingProject) {
    guard !isExporting, let url = lastExportOutputURL else {
      export(project: project)
      return
    }
    exporter.export(project: projectStore.current ?? project, to: url)
  }

  private func revealLastExport() {
    guard case .finished(let url) = exporter.state else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func performCommand(_ command: EditorCommandMenu.CommandKind, project: RecordingProject) {
    switch command {
    case .addZoom:
      addZoomAtCurrentPlayhead()
    case .addAutoZooms:
      insertAutoZoomSuggestions()
      selectedInspector = .zoom
    case .addBlurMask:
      addMask(kind: .blur)
      selectedInspector = .mask
    case .addHighlightMask:
      addMask(kind: .highlight)
      selectedInspector = .mask
    case .addCaption:
      addManualCaption(project: project)
      selectedInspector = .captions
    case .toggleCursor:
      projectStore.applyToCurrent { project in
        var settings = project.cursorVisualSettings
        settings.isVisible.toggle()
        project.cursorVisualSettings = settings
      }
      selectedInspector = .cursor
    case .export:
      export(project: projectStore.current ?? project)
    }
  }

  private func insertAutoZoomSuggestions() {
    guard let project = projectStore.current else { return }
    let existingKeyframes = project.zoomSegments.map(\.asZoomKeyframe)
    var proposed = AutoZoomPipeline.generate(
      from: project,
      assetDurationSeconds: editorSourceDurationSeconds
    ).zoomSegments.filter { segment in
      !existingKeyframes.contains { keyframe in
        max(segment.startSeconds, keyframe.startSeconds) < min(segment.endSeconds, keyframe.endSeconds)
      }
    }
    if proposed.isEmpty {
      proposed = CursorZoomHeuristics.suggestZoomKeyframes(
        samples: project.cursorSamples,
        clickCues: project.cursorClickCues,
        assetDurationSeconds: editorSourceDurationSeconds,
        existingKeyframes: existingKeyframes
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
    }
    guard !proposed.isEmpty else {
      alertCenter.present("自動ズーム候補が見つかりませんでした")
      return
    }
    projectStore.applyToCurrent { project in
      project.zoomSegments.append(contentsOf: proposed)
      project.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
        project.zoomSegments,
        durationSeconds: editorSourceDurationSeconds
      )
    }
  }

  private func addMask(kind: RecordingProject.VisualMask.Kind) {
    guard let current = projectStore.current else { return }
    guard current.visualMasks.count < RecordingProject.TimelineKeyframeSanitize.maxVisualMaskCount else {
      alertCenter.present(
        languageStore.localizedFormat(
          "Masks are limited to %d.",
          RecordingProject.TimelineKeyframeSanitize.maxVisualMaskCount
        )
      )
      return
    }
    let sourceSeconds = sourceSecondsForCurrentPreview(project: current)
    guard let range = EditorSegmentRange.playheadBased(
      at: sourceSeconds,
      preferredDuration: 2,
      totalDuration: editorSourceDurationSeconds,
      minimumDuration: RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds
    ) else {
      alertCannotAddSegment()
      return
    }
    let newID = UUID()
    projectStore.applyToCurrent { project in
      project.visualMasks.append(
        RecordingProject.VisualMask(
          id: newID,
          startSeconds: range.start,
          endSeconds: range.end,
          kind: kind
        )
      )
      project.visualMasks = RecordingProject.sanitizedVisualMasks(
        project.visualMasks,
        durationSeconds: editorSourceDurationSeconds
      )
    }
    selectedTimelineEffect = .mask(newID)
  }

  private func addManualCaption(project: RecordingProject) {
    let sourceSeconds = sourceSecondsForCurrentPreview(project: project)
    guard let range = EditorSegmentRange.playheadBased(
      at: sourceSeconds,
      preferredDuration: 2,
      totalDuration: editorSourceDurationSeconds,
      minimumDuration: 0.05
    ) else {
      alertCannotAddSegment()
      return
    }
    projectStore.applyToCurrent { project in
      var track = project.captionTrack
      track.isEnabled = true
      track.segments.append(
        RecordingProject.CaptionTrack.Segment(
          startSeconds: range.start,
          endSeconds: range.end,
          text: "New caption"
        )
      )
      project.captionTrack = track
    }
  }

  private func alertCannotAddSegment() {
    alertCenter.present("追加できる範囲がありません")
  }

  private func quickShareBinding(projectID: UUID) -> Binding<Bool> {
    Binding(
      get: { projectStore.pendingQuickShareProjectID == projectID },
      set: { isPresented in
        if !isPresented {
          projectStore.dismissQuickShare()
        }
      }
    )
  }
}

private struct CameraPiPPlayerView: NSViewRepresentable {
  var url: URL
  var timeSeconds: Double
  var isPlaying: Bool
  var playbackRate: Double

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.playerLayer.videoGravity = .resizeAspectFill
    updateView(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ view: PlayerLayerView, context: Context) {
    updateView(view, coordinator: context.coordinator)
  }

  static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
    coordinator.player?.pause()
    coordinator.player = nil
    coordinator.url = nil
    view.playerLayer.player = nil
  }

  private func updateView(_ view: PlayerLayerView, coordinator: Coordinator) {
    if coordinator.url != url {
      coordinator.player?.pause()
      let player = AVPlayer(url: url)
      player.isMuted = true
      player.actionAtItemEnd = .pause
      coordinator.url = url
      coordinator.player = player
      view.playerLayer.player = player
      coordinator.lastSeekSeconds = nil
    }

    guard let player = coordinator.player else { return }
    let targetSeconds = max(0, timeSeconds.isFinite ? timeSeconds : 0)
    let seekThreshold = isPlaying ? 0.45 : 0.08
    let playerSeconds = player.currentTime().seconds
    let currentPlayerSeconds = playerSeconds.isFinite ? playerSeconds : coordinator.lastSeekSeconds
    if currentPlayerSeconds.map({ abs($0 - targetSeconds) > seekThreshold }) ?? true {
      player.seek(
        to: CMTime(seconds: targetSeconds, preferredTimescale: 600),
        toleranceBefore: CMTime(seconds: 0.04, preferredTimescale: 600),
        toleranceAfter: CMTime(seconds: 0.04, preferredTimescale: 600)
      )
      coordinator.lastSeekSeconds = targetSeconds
    }

    if isPlaying {
      let safeRate = max(0.25, min(8, playbackRate.isFinite ? playbackRate : 1))
      player.rate = Float(safeRate)
    } else {
      player.pause()
    }
  }

  final class Coordinator {
    var url: URL?
    var player: AVPlayer?
    var lastSeekSeconds: Double?
  }

  final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer = CALayer()
      layer?.backgroundColor = NSColor.black.cgColor
      layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
      super.layout()
      playerLayer.frame = bounds
    }
  }
}

private struct ZoomTargetRegionOverlay: View {
  var segment: RecordingProject.ZoomSegment
  var sourceVideoSize: CGSize
  var previewTransform: (scale: CGFloat, offset: CGSize)
  var onUpdate: (UUID, Double, Double, Double, Double) -> Void

  @GestureState private var dragBaseline: RecordingProject.ZoomSegment?
  @GestureState private var resizeBaseline: RecordingProject.ZoomSegment?

  private enum ResizeHandle: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: Self { self }

    var xSign: Double {
      switch self {
      case .topLeft, .bottomLeft: -1
      case .topRight, .bottomRight: 1
      }
    }

    var ySign: Double {
      switch self {
      case .topLeft, .topRight: 1
      case .bottomLeft, .bottomRight: -1
      }
    }

    func point(in rect: CGRect) -> CGPoint {
      switch self {
      case .topLeft:
        return CGPoint(x: rect.minX, y: rect.minY)
      case .topRight:
        return CGPoint(x: rect.maxX, y: rect.minY)
      case .bottomLeft:
        return CGPoint(x: rect.minX, y: rect.maxY)
      case .bottomRight:
        return CGPoint(x: rect.maxX, y: rect.maxY)
      }
    }
  }

  var body: some View {
    GeometryReader { geo in
      let videoRect = EditorPreviewLayout.aspectFitRect(sourceSize: sourceVideoSize, in: geo.size)
      let targetRect = transformedTargetRect(in: videoRect, segment: segment)
      let targetPoint = CGPoint(x: targetRect.midX, y: targetRect.midY)

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.white.opacity(0.92), lineWidth: 2)
          .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(EditorPalette.brandStrong.opacity(0.08))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.black.opacity(0.22), lineWidth: 1)
          }
          .frame(width: targetRect.width, height: targetRect.height)
          .position(x: targetRect.midX, y: targetRect.midY)
          .allowsHitTesting(false)

        ForEach(ResizeHandle.allCases) { handle in
          resizeHandle
            .position(handle.point(in: targetRect))
            .gesture(resizeDrag(handle: handle, videoRect: videoRect))
            .help("ドラッグしてズーム倍率を調整")
            .accessibilityLabel("ズーム倍率")
            .accessibilityHint("ドラッグしてズーム枠の大きさを変更します")
        }

        Circle()
          .stroke(Color.white.opacity(0.92), lineWidth: 2)
          .background(Circle().fill(EditorPalette.brandStrong.opacity(0.22)))
          .overlay {
            Circle()
              .stroke(Color.black.opacity(0.24), lineWidth: 1)
          }
          .frame(width: 42, height: 42)
          .overlay {
            Image(systemName: "plus")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(.white)
              .shadow(color: Color.black.opacity(0.32), radius: 1, x: 0, y: 1)
          }
          .contentShape(Circle())
          .position(targetPoint)
          .gesture(centerDrag(videoRect: videoRect))
          .help("ズーム先")
          .accessibilityLabel("ズーム先")
          .accessibilityHint("ドラッグしてズーム枠の中心を移動します")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func centerDrag(videoRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($dragBaseline) { _, state, _ in
        if state == nil {
          state = segment
        }
      }
      .onChanged { value in
        let base = dragBaseline ?? segment
        let displayScale = max(1, previewTransform.scale)
        let dx = Double(value.translation.width / max(1, videoRect.width * displayScale))
        let dy = Double(-value.translation.height / max(1, videoRect.height * displayScale))
        let center = base.targetCenter
        var next = base
        next.setTargetCenter(x: center.x + dx, y: center.y + dy)
        let region = next.sanitizedTargetRegion()
        onUpdate(segment.id, region.x, region.y, region.width, region.height)
      }
  }

  private var resizeHandle: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white.opacity(0.96))
        .frame(width: 14, height: 14)
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.black.opacity(0.28), lineWidth: 1)
        }
    }
    .frame(width: 28, height: 28)
    .contentShape(Rectangle())
  }

  private func resizeDrag(handle: ResizeHandle, videoRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($resizeBaseline) { _, state, _ in
        if state == nil {
          state = segment
        }
      }
      .onChanged { value in
        let base = resizeBaseline ?? segment
        let displayScale = max(1, previewTransform.scale)
        let dx = Double(value.translation.width / max(1, videoRect.width * displayScale))
        let dy = Double(-value.translation.height / max(1, videoRect.height * displayScale))
        let projectedDelta = max(handle.xSign * dx, handle.ySign * dy)
        let baseRegion = base.sanitizedTargetRegion()
        let nextSize = max(
          RecordingProject.ZoomSegment.minTargetRegionSize,
          min(1, baseRegion.width + projectedDelta * 2)
        )
        let center = base.targetCenter
        var next = base
        next.setTargetRegion(centerX: center.x, centerY: center.y, zoomLevel: 1 / nextSize)
        let region = next.sanitizedTargetRegion()
        onUpdate(segment.id, region.x, region.y, region.width, region.height)
      }
  }

  private func targetRect(in videoRect: CGRect, segment: RecordingProject.ZoomSegment) -> CGRect {
    let rect = segment.sanitizedTargetRegion()
    return CGRect(
      x: videoRect.minX + rect.x * videoRect.width,
      y: videoRect.maxY - (rect.y + rect.height) * videoRect.height,
      width: rect.width * videoRect.width,
      height: rect.height * videoRect.height
    )
  }

  private func transformedTargetRect(in videoRect: CGRect, segment: RecordingProject.ZoomSegment) -> CGRect {
    let targetRect = targetRect(in: videoRect, segment: segment)
    return CGRect(
      x: targetRect.minX * previewTransform.scale + previewTransform.offset.width,
      y: targetRect.minY * previewTransform.scale + previewTransform.offset.height,
      width: targetRect.width * previewTransform.scale,
      height: targetRect.height * previewTransform.scale
    )
  }
}

private struct CameraRegionOverlay: View {
  var segment: RecordingProject.CameraLayoutSegment
  var containerSize: CGSize
  var onUpdate: (UUID, Double, Double, Double, Double) -> Void

  @GestureState private var dragBaseline: RecordingProject.CameraLayoutSegment?
  @GestureState private var resizeBaseline: RecordingProject.CameraLayoutSegment?

  private enum ResizeHandle: CaseIterable, Identifiable {
    case bottomRight

    var id: Self { self }

    func point(in rect: CGRect) -> CGPoint {
      CGPoint(x: rect.maxX, y: rect.maxY)
    }
  }

  var body: some View {
    let presentation = EditorPreviewCameraPresentation.presentation(for: segment, isZoomActive: false)
    let regionRect = EditorPreviewCameraPresentation.previewRect(for: presentation, in: containerSize)

    if segment.layout == .pip, regionRect.width > 1, regionRect.height > 1 {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
          .stroke(Color.white.opacity(0.92), lineWidth: 2)
          .background {
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
              .fill(EditorPalette.brandStrong.opacity(0.10))
          }
          .frame(width: regionRect.width, height: regionRect.height)
          .position(x: regionRect.midX, y: regionRect.midY)
          .allowsHitTesting(false)

        Circle()
          .stroke(Color.white.opacity(0.92), lineWidth: 2)
          .background(Circle().fill(EditorPalette.brandStrong.opacity(0.18)))
          .frame(width: 42, height: 42)
          .overlay {
            Image(systemName: "video.fill")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(.white)
          }
          .position(x: regionRect.midX, y: regionRect.midY)
          .gesture(centerDrag())
          .accessibilityLabel("Camera position")

        ForEach(ResizeHandle.allCases) { handle in
          Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .position(handle.point(in: regionRect))
            .gesture(resizeDrag())
            .accessibilityLabel("Camera size")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func centerDrag() -> some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($dragBaseline) { _, state, _ in
        if state == nil { state = segment }
      }
      .onChanged { value in
        let baseline = dragBaseline ?? segment
        let deltaXN = Double(value.translation.width / max(containerSize.width, 1))
        let deltaYN = Double(value.translation.height / max(containerSize.height, 1))
        onUpdate(
          baseline.id,
          max(0, min(1 - baseline.widthN, baseline.originXN + deltaXN)),
          max(0, min(1 - baseline.heightN, baseline.originYN + deltaYN)),
          baseline.widthN,
          baseline.heightN
        )
      }
  }

  private func resizeDrag() -> some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($resizeBaseline) { _, state, _ in
        if state == nil { state = segment }
      }
      .onChanged { value in
        let baseline = resizeBaseline ?? segment
        let deltaWN = Double(value.translation.width / max(containerSize.width, 1))
        let deltaHN = Double(value.translation.height / max(containerSize.height, 1))
        onUpdate(
          baseline.id,
          baseline.originXN,
          baseline.originYN,
          max(0.08, min(1 - baseline.originXN, baseline.widthN + deltaWN)),
          max(0.08, min(1 - baseline.originYN, baseline.heightN + deltaHN))
        )
      }
  }
}

private struct MaskRegionOverlay: View {
  var mask: RecordingProject.VisualMask
  var sourceVideoSize: CGSize
  var previewTransform: (scale: CGFloat, offset: CGSize)
  var onUpdate: (UUID, Double, Double, Double, Double) -> Void

  @GestureState private var dragBaseline: RecordingProject.VisualMask?
  @GestureState private var resizeBaseline: RecordingProject.VisualMask?

  private enum ResizeHandle: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: Self { self }

    func point(in rect: CGRect) -> CGPoint {
      switch self {
      case .topLeft:
        return CGPoint(x: rect.minX, y: rect.minY)
      case .topRight:
        return CGPoint(x: rect.maxX, y: rect.minY)
      case .bottomLeft:
        return CGPoint(x: rect.minX, y: rect.maxY)
      case .bottomRight:
        return CGPoint(x: rect.maxX, y: rect.maxY)
      }
    }
  }

  var body: some View {
    GeometryReader { geo in
      let videoRect = EditorPreviewLayout.aspectFitRect(sourceSize: sourceVideoSize, in: geo.size)
      let regionRect = EditorPreviewLayout.maskRect(
        mask: mask,
        in: geo.size,
        sourceSize: sourceVideoSize,
        previewTransform: previewTransform
      )
      let regionPoint = CGPoint(x: regionRect.midX, y: regionRect.midY)
      let strokeColor = mask.kind == .blur ? Color.white.opacity(0.92) : Color.yellow.opacity(0.92)
      let fillColor = mask.kind == .blur ? EditorPalette.brandStrong.opacity(0.10) : Color.yellow.opacity(0.12)

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(strokeColor, lineWidth: 2)
          .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(fillColor)
          }
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.black.opacity(0.22), lineWidth: 1)
          }
          .frame(width: regionRect.width, height: regionRect.height)
          .position(x: regionRect.midX, y: regionRect.midY)
          .allowsHitTesting(false)

        ForEach(ResizeHandle.allCases) { handle in
          resizeHandle
            .position(handle.point(in: regionRect))
            .gesture(resizeDrag(handle: handle, videoRect: videoRect))
            .help("ドラッグしてマスクの大きさを調整")
            .accessibilityLabel("マスクサイズ")
            .accessibilityHint("ドラッグしてマスク枠の大きさを変更します")
        }

        Circle()
          .stroke(strokeColor, lineWidth: 2)
          .background(Circle().fill(fillColor))
          .overlay {
            Circle()
              .stroke(Color.black.opacity(0.24), lineWidth: 1)
          }
          .frame(width: 42, height: 42)
          .overlay {
            Image(systemName: mask.kind == .blur ? "eye.slash" : "highlighter")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(.white)
              .shadow(color: Color.black.opacity(0.32), radius: 1, x: 0, y: 1)
          }
          .contentShape(Circle())
          .position(regionPoint)
          .gesture(centerDrag(videoRect: videoRect))
          .help("マスク位置")
          .accessibilityLabel("マスク位置")
          .accessibilityHint("ドラッグしてマスク枠を移動します")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func centerDrag(videoRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($dragBaseline) { _, state, _ in
        if state == nil {
          state = mask
        }
      }
      .onChanged { value in
        let base = dragBaseline ?? mask
        let displayScale = max(1, previewTransform.scale)
        let dx = Double(value.translation.width / max(1, videoRect.width * displayScale))
        let dy = Double(value.translation.height / max(1, videoRect.height * displayScale))
        let region = sanitizedMaskRegion(
          originXN: base.originXN + dx,
          originYN: base.originYN + dy,
          widthN: base.widthN,
          heightN: base.heightN
        )
        onUpdate(mask.id, region.originXN, region.originYN, region.widthN, region.heightN)
      }
  }

  private var resizeHandle: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white.opacity(0.96))
        .frame(width: 14, height: 14)
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.black.opacity(0.28), lineWidth: 1)
        }
    }
    .frame(width: 28, height: 28)
    .contentShape(Rectangle())
  }

  private func resizeDrag(handle: ResizeHandle, videoRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($resizeBaseline) { _, state, _ in
        if state == nil {
          state = mask
        }
      }
      .onChanged { value in
        let base = resizeBaseline ?? mask
        let displayScale = max(1, previewTransform.scale)
        let dx = Double(value.translation.width / max(1, videoRect.width * displayScale))
        let dy = Double(value.translation.height / max(1, videoRect.height * displayScale))

        var originXN = base.originXN
        var originYN = base.originYN
        var widthN = base.widthN
        var heightN = base.heightN

        switch handle {
        case .topLeft:
          originXN += dx
          originYN += dy
          widthN -= dx
          heightN -= dy
        case .topRight:
          originYN += dy
          widthN += dx
          heightN -= dy
        case .bottomLeft:
          originXN += dx
          widthN -= dx
          heightN += dy
        case .bottomRight:
          widthN += dx
          heightN += dy
        }

        let region = sanitizedMaskRegion(
          originXN: originXN,
          originYN: originYN,
          widthN: widthN,
          heightN: heightN
        )
        onUpdate(mask.id, region.originXN, region.originYN, region.widthN, region.heightN)
      }
  }

  private func sanitizedMaskRegion(
    originXN: Double,
    originYN: Double,
    widthN: Double,
    heightN: Double
  ) -> (originXN: Double, originYN: Double, widthN: Double, heightN: Double) {
    let minSize = 0.02
    let width = max(minSize, min(1, widthN))
    let height = max(minSize, min(1, heightN))
    let x = max(0, min(1 - width, originXN))
    let y = max(0, min(1 - height, originYN))
    return (x, y, width, height)
  }
}

private struct EditorTopBar: View {
  @Environment(AppLanguageStore.self) private var languageStore

  var title: String
  var metadata: String
  var isExporting: Bool
  var commandAction: () -> Void
  var exportAction: () -> Void

  var body: some View {
    ZStack {
      HStack {
        EditorTrafficLightReserve()
        Button(action: commandAction) {
          Label(languageStore.localized("Command"), systemImage: "command")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("k", modifiers: .command)
        .help("コマンドメニュー")
        Spacer()
        Button(action: exportAction) {
          Label(languageStore.localized(isExporting ? "Exporting" : "Export"), systemImage: "square.and.arrow.up")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isExporting)
      }

      VStack(spacing: 2) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        Text(metadata)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 360)
      }
    }
    .frame(height: 56)
    .padding(.horizontal, 16)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(EditorPalette.separator)
        .frame(height: 1)
    }
  }
}

private struct EditorTrafficLightReserve: View {
  var body: some View {
    // 実際のmacOSウィンドウ操作ボタンが重ならないよう左上を空ける。
    Color.clear
    .frame(width: 86, alignment: .leading)
    .frame(height: 20)
    .accessibilityHidden(true)
  }
}

private struct ExportStatusBanner: View {
  var state: Exporter.ExportState
  var progress: Double
  var outputURL: URL?
  var cancelAction: () -> Void
  var revealAction: () -> Void
  var retryAction: () -> Void
  var chooseDestinationAction: () -> Void
  @Environment(AppLanguageStore.self) private var languageStore

  var body: some View {
    HStack(spacing: 12) {
      statusIcon
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(title)
            .font(.callout.weight(.semibold))
          if let detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        if case .exporting = state {
          ProgressView(value: max(0, min(1, progress)))
            .frame(maxWidth: 360)
        }
      }

      Spacer()

      switch state {
      case .idle:
        EmptyView()
      case .exporting:
        Button(languageStore.localized("中止"), role: .destructive, action: cancelAction)
      case .finished:
        Button(languageStore.localized("Finderで表示"), action: revealAction)
        Button(languageStore.localized("再書き出し"), action: retryAction)
      case .failed:
        Button(languageStore.localized("再試行"), action: retryAction)
        Button(languageStore.localized("保存先を選ぶ"), action: chooseDestinationAction)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(.regularMaterial)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(EditorPalette.separator)
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var statusIcon: some View {
    Group {
      switch state {
      case .idle:
        Image(systemName: "square.and.arrow.up")
          .foregroundStyle(.secondary)
      case .exporting:
        ProgressView()
          .controlSize(.small)
      case .finished:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
  }

  private var title: String {
    switch state {
    case .idle:
      return languageStore.localized("書き出し待機中")
    case .exporting:
      return languageStore.localizedFormat("書き出し中 %d%%", Int(max(0, min(1, progress)) * 100))
    case .finished:
      return languageStore.localized("書き出し完了")
    case .failed:
      return languageStore.localized("書き出しに失敗しました")
    }
  }

  private var detail: String? {
    switch state {
    case .idle:
      return outputURL?.lastPathComponent
    case .exporting:
      return outputURL.map { languageStore.localizedFormat("保存先: %@", $0.lastPathComponent) }
    case .finished(let url):
      return url.lastPathComponent
    case .failed(let message):
      return message
    }
  }

  private var accessibilityText: String {
    [title, detail].compactMap(\.self).joined(separator: "、")
  }
}

private struct EditorKeyboardShortcuts: View {
  var onTogglePlayback: () -> Void
  var onUndo: () -> Void
  var onRedo: () -> Void
  var onSeekBack: () -> Void
  var onSeekForward: () -> Void
  var onPreviousFrame: () -> Void
  var onNextFrame: () -> Void
  var onCommandMenu: () -> Void

  var body: some View {
    VStack {
      shortcut(.space, modifiers: [], action: onTogglePlayback)
      shortcut("z", modifiers: .command, action: onUndo)
      shortcut("z", modifiers: [.command, .shift], action: onRedo)
      shortcut(.leftArrow, modifiers: [], action: onSeekBack)
      shortcut(.rightArrow, modifiers: [], action: onSeekForward)
      shortcut("[", modifiers: [], action: onPreviousFrame)
      shortcut("]", modifiers: [], action: onNextFrame)
      shortcut("k", modifiers: .command, action: onCommandMenu)
    }
    .frame(width: 1, height: 1)
    .opacity(0.001)
    .accessibilityHidden(true)
  }

  private func shortcut(
    _ key: KeyEquivalent,
    modifiers: EventModifiers,
    action: @escaping () -> Void
  ) -> some View {
    Button("", action: action)
      .keyboardShortcut(key, modifiers: modifiers)
  }
}

private struct CursorPreviewView: View {
  var sizeScale: CGFloat
  var pointerStyle: RecordingProject.CursorVisualSettings.PointerStyle
  var clickProgress: CGFloat?
  var ringPhase: CGFloat

  private let style = CursorRenderer.Style()

  var body: some View {
    let clampedScale = max(0.5, min(3, sizeScale))
    let dotSize = style.dotSize * clampedScale
    let ringSize = style.ringSize * clampedScale
    let ringScale = 0.96 + 0.04 * (0.5 + 0.5 * sin(ringPhase * .pi * 2))
    let ringAlpha = 0.22 + 0.18 * (0.5 + 0.5 * cos(ringPhase * .pi * 2))

    ZStack {
      if pointerStyle == .spotlight || pointerStyle == .arrowWithRing {
        Circle()
          .stroke(
            Color(nsColor: style.ringStrokeColor).opacity(ringAlpha),
            lineWidth: style.ringLineWidth
          )
          .frame(width: ringSize * ringScale, height: ringSize * ringScale)
      }

      if pointerStyle == .arrow || pointerStyle == .arrowWithRing {
        CursorArrowShape()
          .fill(Color.white.opacity(0.96))
          .frame(width: 20 * clampedScale, height: 30 * clampedScale)
          .overlay {
            CursorArrowShape()
              .stroke(Color.black.opacity(0.58), lineWidth: max(1.1, 1.5 * clampedScale))
              .frame(width: 20 * clampedScale, height: 30 * clampedScale)
          }
          .offset(x: 10 * clampedScale, y: 15 * clampedScale)
      } else {
        Circle()
          .fill(Color(nsColor: style.dotColor).opacity(style.dotAlpha))
          .frame(width: dotSize, height: dotSize)
      }

      if let clickProgress, clickProgress >= 0, clickProgress <= 1 {
        let radius = style.ringSize * clampedScale * 1.35 * clickProgress
        Circle()
          .stroke(Color.white.opacity(0.32 * (1 - clickProgress)), lineWidth: 1.6 * clampedScale)
          .frame(width: radius * 2, height: radius * 2)
      }
    }
    .shadow(
      color: Color(nsColor: style.shadowColor),
      radius: style.shadowRadius,
      x: 0,
      y: style.shadowOffsetY
    )
  }
}

private struct CursorArrowShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let sx = rect.width / 20
    let sy = rect.height / 30
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 24 * sy))
    path.addLine(to: CGPoint(x: rect.minX + 6.2 * sx, y: rect.minY + 18.2 * sy))
    path.addLine(to: CGPoint(x: rect.minX + 10.9 * sx, y: rect.minY + 29.3 * sy))
    path.addLine(to: CGPoint(x: rect.minX + 16.4 * sx, y: rect.minY + 26.9 * sy))
    path.addLine(to: CGPoint(x: rect.minX + 11.6 * sx, y: rect.minY + 16.0 * sy))
    path.addLine(to: CGPoint(x: rect.minX + 19.8 * sx, y: rect.minY + 16.0 * sy))
    path.closeSubpath()
    return path
  }
}

private struct EditorLiveZoomPreviewRange: Equatable {
  var id: UUID
  var startSeconds: Double
  var inEndSeconds: Double
  var outStartSeconds: Double
  var endSeconds: Double
}

struct EditorPreviewZoomState: Equatable {
  var id: UUID
  var scale: Double
  var anchorX: Double
  var anchorY: Double
  var visibleX: Double
  var visibleY: Double
  var visibleWidth: Double
  var visibleHeight: Double

  var compositionZoomState: ArcShotCompositionInstruction.ZoomState {
    ArcShotCompositionInstruction.ZoomState(
      scale: scale,
      anchorX: anchorX,
      anchorY: anchorY,
      visibleX: visibleX,
      visibleY: visibleY,
      visibleWidth: visibleWidth,
      visibleHeight: visibleHeight
    )
  }
}

enum EditorPreviewZoomResolver {
  static func state(
    for segment: RecordingProject.ZoomSegment,
    at seconds: Double
  ) -> EditorPreviewZoomState? {
    state(
      id: segment.id,
      startSeconds: segment.startSeconds,
      inEndSeconds: segment.inEndSeconds,
      outStartSeconds: segment.outStartSeconds,
      endSeconds: segment.endSeconds,
      targetX: segment.targetX,
      targetY: segment.targetY,
      targetWidth: segment.targetWidth,
      targetHeight: segment.targetHeight,
      at: seconds
    )
  }

  static func state(
    id: UUID,
    startSeconds: Double,
    inEndSeconds: Double,
    outStartSeconds: Double,
    endSeconds: Double,
    targetX: Double,
    targetY: Double,
    targetWidth: Double,
    targetHeight: Double,
    at seconds: Double
  ) -> EditorPreviewZoomState? {
    guard seconds >= startSeconds - 1e-9, seconds <= endSeconds + 1e-9 else {
      return nil
    }

    let minSize = max(RecordingProject.ZoomSegment.minTargetRegionSize, 1 / RecordingProject.ZoomSegment.maxZoomLevel)
    let size = max(minSize, min(1, min(targetWidth, targetHeight)))
    let x = max(0, min(1 - size, targetX))
    let y = max(0, min(1 - size, targetY))
    let target = EditorPreviewZoomState(
      id: id,
      scale: RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(1 / size),
      anchorX: x + size / 2,
      anchorY: y + size / 2,
      visibleX: x,
      visibleY: y,
      visibleWidth: size,
      visibleHeight: size
    )

    if inEndSeconds <= startSeconds + 1e-6, seconds <= outStartSeconds {
      return target
    }

    let identity = EditorPreviewZoomState(
      id: id,
      scale: 1,
      anchorX: 0.5,
      anchorY: 0.5,
      visibleX: 0,
      visibleY: 0,
      visibleWidth: 1,
      visibleHeight: 1
    )
    if seconds < inEndSeconds {
      let progress = easeOut(normalized(seconds, start: startSeconds, end: inEndSeconds))
      return blend(from: identity, to: target, progress: progress)
    }

    if seconds <= outStartSeconds {
      return target
    }

    let progress = easeIn(normalized(seconds, start: outStartSeconds, end: endSeconds))
    return blend(from: target, to: identity, progress: progress)
  }

  static func resolvedState(
    segments: [RecordingProject.ZoomSegment],
    at seconds: Double,
    excludingSegmentID: UUID? = nil
  ) -> EditorPreviewZoomState? {
    let sorted = segments
      .filter { $0.id != excludingSegmentID }
      .sorted { lhs, rhs in
        if abs(lhs.startSeconds - rhs.startSeconds) > 1e-9 {
          return lhs.startSeconds < rhs.startSeconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    guard !sorted.isEmpty else { return nil }

    for index in sorted.indices {
      let segment = sorted[index]
      guard let next = index + 1 < sorted.count ? sorted[index + 1] : nil,
            areAdjacent(segment, next),
            seconds >= segment.outStartSeconds - 1e-9,
            seconds <= next.inEndSeconds + 1e-9,
            seconds >= segment.startSeconds - 1e-9,
            seconds <= next.endSeconds + 1e-9
      else { continue }

      if seconds < segment.outStartSeconds - 1e-9 {
        return state(for: segment, at: seconds)
      }

      let progress = smoothStep(
        normalized(seconds, start: segment.outStartSeconds, end: next.inEndSeconds)
      )
      return blend(
        from: holdTarget(for: segment),
        to: holdTarget(for: next),
        progress: progress
      )
    }

    return sorted
      .compactMap { segment -> (startSeconds: Double, stableID: String, state: EditorPreviewZoomState)? in
        guard let state = state(for: segment, at: seconds) else { return nil }
        return (segment.startSeconds, segment.id.uuidString, state)
      }
      .sorted { lhs, rhs in
        if abs(lhs.startSeconds - rhs.startSeconds) > 1e-9 {
          return lhs.startSeconds < rhs.startSeconds
        }
        return lhs.stableID < rhs.stableID
      }
      .last?.state
  }

  static func resolvedState(
    keyframes: [RecordingProject.ZoomKeyframe],
    at seconds: Double
  ) -> EditorPreviewZoomState? {
    resolvedState(
      segments: keyframes.map(RecordingProject.ZoomSegment.fromKeyframe),
      at: seconds
    )
  }

  private static func areAdjacent(
    _ outgoing: RecordingProject.ZoomSegment,
    _ incoming: RecordingProject.ZoomSegment
  ) -> Bool {
    abs(outgoing.endSeconds - incoming.startSeconds) <= 1e-6
  }

  private static func holdTarget(for segment: RecordingProject.ZoomSegment) -> EditorPreviewZoomState {
    holdTarget(
      id: segment.id,
      targetX: segment.targetX,
      targetY: segment.targetY,
      targetWidth: segment.targetWidth,
      targetHeight: segment.targetHeight
    )
  }

  private static func holdTarget(
    id: UUID,
    targetX: Double,
    targetY: Double,
    targetWidth: Double,
    targetHeight: Double
  ) -> EditorPreviewZoomState {
    let minSize = max(RecordingProject.ZoomSegment.minTargetRegionSize, 1 / RecordingProject.ZoomSegment.maxZoomLevel)
    let size = max(minSize, min(1, min(targetWidth, targetHeight)))
    let x = max(0, min(1 - size, targetX))
    let y = max(0, min(1 - size, targetY))
    return EditorPreviewZoomState(
      id: id,
      scale: RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(1 / size),
      anchorX: x + size / 2,
      anchorY: y + size / 2,
      visibleX: x,
      visibleY: y,
      visibleWidth: size,
      visibleHeight: size
    )
  }

  private static func smoothStep(_ value: Double) -> Double {
    let t = max(0, min(1, value))
    return t * t * (3 - 2 * t)
  }

  private static func normalized(_ value: Double, start: Double, end: Double) -> Double {
    guard end > start + 1e-9 else { return 1 }
    return max(0, min(1, (value - start) / (end - start)))
  }

  private static func easeOut(_ value: Double) -> Double {
    1 - pow(1 - max(0, min(1, value)), 3)
  }

  private static func easeIn(_ value: Double) -> Double {
    pow(max(0, min(1, value)), 3)
  }

  private static func blend(
    from: EditorPreviewZoomState,
    to: EditorPreviewZoomState,
    progress: Double
  ) -> EditorPreviewZoomState {
    let progress = max(0, min(1, progress))
    return EditorPreviewZoomState(
      id: to.id,
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

enum EditorPreviewMaskPresentation {
  struct Style: Equatable {
    var cornerRadius: CGFloat
    var fillOpacity: Double
    var strokeOpacity: Double
    var strokeLineWidth: CGFloat

    var usesMaterialProxy: Bool { false }
  }

  static let highlightStyle = Style(
    cornerRadius: VisualMaskStyle.cornerRadius,
    fillOpacity: VisualMaskStyle.highlightFillOpacity,
    strokeOpacity: VisualMaskStyle.highlightStrokeOpacity,
    strokeLineWidth: VisualMaskStyle.highlightStrokeWidth
  )

  static func showsRegionOverlay(isPlaying: Bool, selectedMaskID: UUID?) -> Bool {
    selectedMaskID != nil && !isPlaying
  }

  static func style(for kind: RecordingProject.VisualMask.Kind) -> Style {
    highlightStyle
  }

  static func activeOpacity(at timeSeconds: Double, mask: RecordingProject.VisualMask) -> Double {
    VisualMaskStyle.activeOpacity(at: timeSeconds, mask: mask)
  }

  static func isActive(at timeSeconds: Double, mask: RecordingProject.VisualMask) -> Bool {
    VisualMaskStyle.isActive(at: timeSeconds, mask: mask)
  }
}

enum EditorPreviewZoomPresentation {
  static func allowsImplicitAnimation(isPlaying: Bool, hasLivePreviewRange: Bool) -> Bool {
    !isPlaying && !hasLivePreviewRange
  }

  static func showsTargetOverlay(isPlaying: Bool, selectedZoomID: UUID?) -> Bool {
    selectedZoomID != nil && !isPlaying
  }
}

enum EditorPreviewPlaybackTime {
  static func clamped(currentSeconds: Double, durationSeconds: Double) -> Double {
    let duration = max(0, durationSeconds.isFinite ? durationSeconds : 0)
    let current = max(0, currentSeconds.isFinite ? currentSeconds : 0)
    return min(duration, current)
  }
}

enum EditorPreviewClickPulse {
  static func activeCue(
    at timeSeconds: Double,
    clickCues: [RecordingProject.CursorClickCue],
    showsClickEffects: Bool
  ) -> RecordingProject.CursorClickCue? {
    guard showsClickEffects else { return nil }
    return clickCues.first {
      CursorRenderer.clickPulseProgress(at: timeSeconds, clickCues: [$0]) != nil
    }
  }

  static func pulseCursorTimeSeconds(currentSourceTimeSeconds: Double) -> Double {
    currentSourceTimeSeconds
  }
}

enum EditorPreviewKeyboardShortcut {
  struct Overlay: Equatable {
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var normalizedRect: CGRect
  }

  static let durationSeconds = 1.1
  static let normalizedRect = CGRect(x: 0.34, y: 0.06, width: 0.32, height: 0.075)

  private static let modifierMask =
    UInt64(NSEvent.ModifierFlags.command.rawValue)
    | UInt64(NSEvent.ModifierFlags.option.rawValue)
    | UInt64(NSEvent.ModifierFlags.control.rawValue)

  static func activeOverlay(
    at timeSeconds: Double,
    inputEvents: [RecordingProject.InputEvent],
    showsKeyboardShortcuts: Bool
  ) -> Overlay? {
    guard showsKeyboardShortcuts, timeSeconds.isFinite else { return nil }

    return inputEvents.compactMap { event -> Overlay? in
      guard event.kind == .keyDown,
        event.modifierFlagsRaw & modifierMask != 0,
        let text = event.shortcutDisplayText,
        !text.isEmpty
      else { return nil }

      let start = max(0, event.timeSeconds)
      let end = start + durationSeconds
      guard timeSeconds >= start, timeSeconds <= end else { return nil }
      return Overlay(
        text: text,
        startSeconds: start,
        endSeconds: end,
        normalizedRect: normalizedRect
      )
    }
    .max { $0.startSeconds < $1.startSeconds }
  }

  static func previewRect(in size: CGSize) -> CGRect {
    CGRect(
      x: normalizedRect.origin.x * size.width,
      y: normalizedRect.origin.y * size.height,
      width: normalizedRect.width * size.width,
      height: normalizedRect.height * size.height
    )
  }
}

enum EditorPreviewCaptionPresentation {
  struct Style: Equatable {
    var fontPointSize: Double
    var backgroundOpacity: Double
    var cornerRadius: CGFloat
    var horizontalTextInset: CGFloat
    var verticalTextInset: CGFloat
  }

  struct Overlay: Equatable {
    var renderID: String
    var id: UUID
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var normalizedRect: CGRect
    var opacity: Double
    var style: Style
  }

  static let fadeSeconds = 0.05
  static let backgroundOpacity = 0.35
  static let cornerRadius: CGFloat = 6

  static func activeOverlay(
    at timeSeconds: Double,
    captionTrack: RecordingProject.CaptionTrack
  ) -> Overlay? {
    activeOverlays(at: timeSeconds, textOverlays: captionTrack.asTextOverlays()).last
  }

  static func activeOverlays(
    at timeSeconds: Double,
    textOverlays: [RecordingProject.TextOverlayAnnotation],
    durationSeconds: Double? = nil
  ) -> [Overlay] {
    guard timeSeconds.isFinite else { return [] }

    let sanitizeDuration = durationSeconds.map { max(0, $0) }
      ?? max(0, textOverlays.map(\.endSeconds).max() ?? timeSeconds)
    let sanitizedOverlays = RecordingProject.TextOverlaySanitizeDefaults.sanitized(
      textOverlays,
      durationSeconds: sanitizeDuration
    )

    return sanitizedOverlays.enumerated().compactMap { index, overlay -> Overlay? in
      let opacity = activeOpacity(
        at: timeSeconds,
        startSeconds: overlay.startSeconds,
        endSeconds: overlay.endSeconds
      )
      guard opacity > 0.001, !overlay.text.isEmpty else { return nil }
      let fontPointSize = max(10, overlay.fontPointSize)
      let textInset = max(8, fontPointSize * 0.35)
      return Overlay(
        renderID: "\(index)-\(overlay.id.uuidString)",
        id: overlay.id,
        text: overlay.text,
        startSeconds: overlay.startSeconds,
        endSeconds: overlay.endSeconds,
        normalizedRect: CGRect(
          x: overlay.originXN,
          y: overlay.originYN,
          width: overlay.widthN,
          height: overlay.heightN
        ),
        opacity: opacity,
        style: Style(
          fontPointSize: fontPointSize,
          backgroundOpacity: backgroundOpacity,
          cornerRadius: cornerRadius,
          horizontalTextInset: CGFloat(textInset),
          verticalTextInset: CGFloat(textInset * 0.55)
        )
      )
    }
    .sorted { $0.startSeconds < $1.startSeconds }
  }

  static func previewRect(for overlay: Overlay, in size: CGSize) -> CGRect {
    CGRect(
      x: overlay.normalizedRect.origin.x * size.width,
      y: overlay.normalizedRect.origin.y * size.height,
      width: overlay.normalizedRect.width * size.width,
      height: overlay.normalizedRect.height * size.height
    )
  }

  private static func activeOpacity(
    at timeSeconds: Double,
    startSeconds: Double,
    endSeconds: Double
  ) -> Double {
    guard timeSeconds.isFinite else { return 0 }
    let start = max(0, startSeconds)
    let end = max(start, endSeconds)
    let fade = max(1e-3, fadeSeconds)
    guard timeSeconds >= start - fade, timeSeconds <= end + fade else { return 0 }
    if timeSeconds < start + fade {
      return max(0, min(1, (timeSeconds - (start - fade)) / (fade * 2)))
    }
    if timeSeconds > end - fade {
      return max(0, min(1, ((end + fade) - timeSeconds) / (fade * 2)))
    }
    return 1
  }
}

enum EditorPreviewFade {
  static func opacity(
    timeSeconds: Double,
    durationSeconds: Double,
    styleSettings: RecordingProject.StyleSettings
  ) -> Double {
    guard timeSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
    let time = max(0, min(durationSeconds, timeSeconds))
    var opacity = 0.0

    if styleSettings.introFadeSeconds > 1e-3,
      time < styleSettings.introFadeSeconds {
      opacity = max(opacity, 1 - time / styleSettings.introFadeSeconds)
    }

    let outroStart = durationSeconds - styleSettings.outroFadeSeconds
    if styleSettings.outroFadeSeconds > 1e-3,
      time > outroStart {
      let progress = (time - outroStart) / styleSettings.outroFadeSeconds
      opacity = max(opacity, min(1, progress))
    }

    return max(0, min(1, opacity))
  }
}

enum EditorPreviewCameraPresentation {
  struct Presentation: Equatable {
    var normalizedRect: CGRect
    var cornerRadius: CGFloat
    var isHidden: Bool
  }

  static func presentation(
    for segment: RecordingProject.CameraLayoutSegment,
    isZoomActive: Bool
  ) -> Presentation {
    guard segment.layout != .hidden else {
      return Presentation(normalizedRect: .zero, cornerRadius: 0, isHidden: true)
    }

    let widthN = segment.layout == .fullscreen ? 1 : segment.widthN
    let heightN = segment.layout == .fullscreen ? 1 : segment.heightN
    let centerXN = segment.layout == .fullscreen ? 0.5 : segment.originXN + segment.widthN / 2
    let centerYN = segment.layout == .fullscreen ? 0.5 : segment.originYN + segment.heightN / 2
    let originXN = segment.layout == .fullscreen ? 0 : max(0, min(1 - widthN, centerXN - widthN / 2))
    let originYN = segment.layout == .fullscreen ? 0 : max(0, min(1 - heightN, centerYN - heightN / 2))

    return Presentation(
      normalizedRect: CGRect(x: originXN, y: originYN, width: widthN, height: heightN),
      cornerRadius: segment.layout == .fullscreen ? 0 : min(28, CGFloat(segment.cornerRadiusPts) * 0.55),
      isHidden: false
    )
  }

  static func previewRect(for presentation: Presentation, in size: CGSize, sourceVideoSize: CGSize = .zero) -> CGRect {
    let bounds: CGRect
    if sourceVideoSize.width > 1, sourceVideoSize.height > 1 {
      bounds = EditorPreviewLayout.aspectFitRect(sourceSize: sourceVideoSize, in: size)
    } else {
      bounds = CGRect(origin: .zero, size: size)
    }
    return CGRect(
      x: bounds.minX + presentation.normalizedRect.origin.x * bounds.width,
      y: bounds.minY + presentation.normalizedRect.origin.y * bounds.height,
      width: presentation.normalizedRect.width * bounds.width,
      height: presentation.normalizedRect.height * bounds.height
    )
  }

  static func showsRegionOverlay(isPlaying: Bool, selectedCameraID: UUID?) -> Bool {
    !isPlaying && selectedCameraID != nil
  }

  static func playbackRate(atTimelineSeconds seconds: Double, timeline: RecordingProject.TimelineModel) -> Double {
    guard let clip = timeline.activeClips.first(where: {
      seconds >= $0.timelineStartSeconds - 1e-9
        && seconds <= $0.timelineStartSeconds + $0.durationSeconds + 1e-9
    }) else {
      return RecordingProject.TimelineEditing.defaultSpeedRate
    }
    return timeline.speedRate(
      forTimelineRangeStart: clip.timelineStartSeconds,
      end: clip.timelineStartSeconds + clip.durationSeconds
    )
  }
}

private struct StyledVideoPreview: View {
  @Environment(AppLanguageStore.self) private var languageStore

  var project: RecordingProject
  var player: AVPlayer?
  var currentSeconds: Double
  var durationSeconds: Double
  var sourceDurationSeconds: Double
  var isPlaying: Bool
  var sourceVideoSize: CGSize
  @Binding var previewScale: Double
  var backgroundMode: EditorBackgroundMode
  var selectedZoomID: UUID?
  var selectedMaskID: UUID?
  var selectedCameraID: UUID?
  var liveZoomPreviewRange: EditorLiveZoomPreviewRange?
  var usesStandaloneChrome: Bool = true
  var onUpdateZoomTargetRegion: (UUID, Double, Double, Double, Double) -> Void
  var onUpdateMaskRegion: (UUID, Double, Double, Double, Double) -> Void
  var onUpdateCameraRegion: (UUID, Double, Double, Double, Double) -> Void

  private var visuals: RecordingProject.ExportVisualSettings {
    project.exportVisualSettings
  }

  private var activePreviewZoomState: EditorPreviewZoomState? {
    let sourceSeconds = sourcePreviewTimeSeconds
    if let liveZoomPreviewRange,
      let segment = project.zoomSegments.first(where: { $0.id == liveZoomPreviewRange.id }),
      let state = previewZoomState(for: segment, range: liveZoomPreviewRange, at: sourceSeconds) {
      return state
    }

    let liveEditingID = liveZoomPreviewRange?.id
    return EditorPreviewZoomResolver.resolvedState(
      segments: project.zoomSegments,
      at: sourceSeconds,
      excludingSegmentID: liveEditingID
    )
  }

  private var sourcePreviewTimeSeconds: Double {
    project.sourceSecondsForPreviewPlayback(previewTimeSeconds)
  }

  private var activePreviewMotion: RecordingProject.AutoZoomMotionFrame? {
    guard activePreviewZoomState == nil, project.stylePreset == .cursorFocus else { return nil }
    return project.autoZoomMotionFrame(atSourceSeconds: sourcePreviewTimeSeconds)
  }

  private var selectedZoomSegment: RecordingProject.ZoomSegment? {
    guard let selectedZoomID else { return nil }
    return project.zoomSegments.first { $0.id == selectedZoomID }
  }

  private var selectedMask: RecordingProject.VisualMask? {
    guard let selectedMaskID else { return nil }
    return project.visualMasks.first { $0.id == selectedMaskID }
  }

  private var activePreviewZoomSignature: String {
    if let activePreviewZoomState {
      return [
        activePreviewZoomState.id.uuidString,
        String(format: "%.4f", activePreviewZoomState.scale),
        String(format: "%.4f", activePreviewZoomState.visibleX),
        String(format: "%.4f", activePreviewZoomState.visibleY),
        String(format: "%.4f", activePreviewZoomState.visibleWidth),
        String(format: "%.4f", activePreviewZoomState.visibleHeight),
      ].joined(separator: ":")
    }
    guard let activePreviewMotion else { return "none" }
    return [
      "motion",
      String(format: "%.3f", activePreviewMotion.timeSeconds),
      String(format: "%.3f", activePreviewMotion.scale),
      String(format: "%.3f", activePreviewMotion.anchorX),
      String(format: "%.3f", activePreviewMotion.anchorY),
    ].joined(separator: ":")
  }

  private var activePreviewZoomAnimation: Animation? {
    EditorPreviewZoomPresentation.allowsImplicitAnimation(
      isPlaying: isPlaying,
      hasLivePreviewRange: liveZoomPreviewRange != nil
    )
      ? .easeInOut(duration: 0.18)
      : nil
  }

  private func previewZoomState(
    for segment: RecordingProject.ZoomSegment,
    at seconds: Double
  ) -> EditorPreviewZoomState? {
    EditorPreviewZoomResolver.state(for: segment, at: seconds)
  }

  private func previewZoomState(
    for segment: RecordingProject.ZoomSegment,
    range: EditorLiveZoomPreviewRange,
    at seconds: Double
  ) -> EditorPreviewZoomState? {
    EditorPreviewZoomResolver.state(
      id: segment.id,
      startSeconds: range.startSeconds,
      inEndSeconds: range.inEndSeconds,
      outStartSeconds: range.outStartSeconds,
      endSeconds: range.endSeconds,
      targetX: segment.targetX,
      targetY: segment.targetY,
      targetWidth: segment.targetWidth,
      targetHeight: segment.targetHeight,
      at: seconds
    )
  }

  private func activePreviewTransform(in containerSize: CGSize) -> (scale: CGFloat, offset: CGSize) {
    // ズーム領域の編集中（選択 + 非再生）は、プレビューを引き（等倍・全体）に固定する。
    // 拡大後の絵のままでは対象範囲の枠が画面いっぱいになり、位置や大きさを調整できないため。
    // 全体表示にすることで枠を「引きの画面」上に置いて拡大領域を自由に指定できる。
    if EditorPreviewZoomPresentation.showsTargetOverlay(isPlaying: isPlaying, selectedZoomID: selectedZoomID) {
      return (1, .zero)
    }
    if EditorPreviewMaskPresentation.showsRegionOverlay(isPlaying: isPlaying, selectedMaskID: selectedMaskID) {
      return (1, .zero)
    }
    if EditorPreviewCameraPresentation.showsRegionOverlay(isPlaying: isPlaying, selectedCameraID: selectedCameraID) {
      return (1, .zero)
    }
    if let activePreviewZoomState {
      return previewTransform(for: activePreviewZoomState, in: containerSize)
    }

    guard let activePreviewMotion else {
      return (1, .zero)
    }

    let scale = CGFloat(max(1, min(3, activePreviewMotion.scale)))
    let anchor = EditorPreviewLayout.zoomAnchorPoint(
      anchorX: activePreviewMotion.anchorX,
      anchorY: activePreviewMotion.anchorY,
      in: containerSize,
      sourceSize: sourceVideoSize
    )
    return (
      scale,
      CGSize(width: anchor.x * (1 - scale), height: anchor.y * (1 - scale))
    )
  }

  private func previewTransform(
    for state: EditorPreviewZoomState,
    in containerSize: CGSize
  ) -> (scale: CGFloat, offset: CGSize) {
    EditorPreviewLayout.previewZoomTransform(
      visibleSourceRect: CGRect(
        x: state.visibleX,
        y: state.visibleY,
        width: state.visibleWidth,
        height: state.visibleHeight
      ),
      in: containerSize,
      sourceSize: sourceVideoSize
    )
  }

  private func applyingActivePreviewTransform(to point: CGPoint, in containerSize: CGSize) -> CGPoint {
    let transform = activePreviewTransform(in: containerSize)
    return CGPoint(
      x: point.x * transform.scale + transform.offset.width,
      y: point.y * transform.scale + transform.offset.height
    )
  }

  private var previewTimeSeconds: Double {
    EditorPreviewPlaybackTime.clamped(
      currentSeconds: currentSeconds,
      durationSeconds: durationSeconds
    )
  }

  private var activeCaptionOverlays: [EditorPreviewCaptionPresentation.Overlay] {
    EditorPreviewCaptionPresentation.activeOverlays(
      at: sourcePreviewTimeSeconds,
      textOverlays: project.textOverlayAnnotations + project.captionTrack.asTextOverlays(),
      durationSeconds: max(sourceDurationSeconds, durationSeconds)
    )
  }

  private var activeBlurMasks: [RecordingProject.VisualMask] {
    activeMasks.filter { $0.kind == .blur }
  }

  private var activeHighlightMasks: [RecordingProject.VisualMask] {
    activeMasks.filter { $0.kind == .highlight }
  }

  private var activeMasks: [RecordingProject.VisualMask] {
    project.visualMasks.filter {
      EditorPreviewMaskPresentation.isActive(at: sourcePreviewTimeSeconds, mask: $0)
    }
  }

  private var activeShortcutOverlay: EditorPreviewKeyboardShortcut.Overlay? {
    EditorPreviewKeyboardShortcut.activeOverlay(
      at: sourcePreviewTimeSeconds,
      inputEvents: project.inputEvents,
      showsKeyboardShortcuts: project.cursorVisualSettings.showKeyboardShortcuts
    )
  }

  private var activeClickCue: RecordingProject.CursorClickCue? {
    EditorPreviewClickPulse.activeCue(
      at: sourcePreviewTimeSeconds,
      clickCues: project.cursorClickCues,
      showsClickEffects: project.cursorVisualSettings.showClickEffects
    )
  }

  private var selectedCameraSegment: RecordingProject.CameraLayoutSegment? {
    guard let selectedCameraID else { return nil }
    return project.cameraLayoutSegments.first(where: { $0.id == selectedCameraID })
  }

  private var activeCameraSegment: RecordingProject.CameraLayoutSegment? {
    guard project.secondaryRecording != nil else { return nil }
    if let selectedCameraSegment,
      sourcePreviewTimeSeconds >= selectedCameraSegment.startSeconds,
      sourcePreviewTimeSeconds <= selectedCameraSegment.endSeconds {
      return selectedCameraSegment
    }
    return project.cameraLayoutSegments
      .filter { sourcePreviewTimeSeconds >= $0.startSeconds && sourcePreviewTimeSeconds <= $0.endSeconds }
      .max { $0.startSeconds < $1.startSeconds }
  }

  var body: some View {
    VStack(spacing: 14) {
      previewToolbar
        .frame(height: 36)

      GeometryReader { geo in
        let aspect = project.outputAspectRatio.editorPreviewAspectRatio
        let stageSize = EditorPreviewLayout.stageSize(
          container: geo.size,
          aspectRatio: aspect,
          horizontalInset: EditorLayout.panelInset * 2,
          verticalInset: EditorLayout.panelInset
        )
        let baseStageSize = CGSize(
          width: max(240, stageSize.width),
          height: max(160, stageSize.height)
        )
        let scaledStageSize = CGSize(
          width: baseStageSize.width * CGFloat(previewScale),
          height: baseStageSize.height * CGFloat(previewScale)
        )

        ScrollView([.horizontal, .vertical]) {
          ZStack {
            // 拡大後の占有サイズを明示し、ズーム時にプレビューがタイムラインへはみ出さないようにする。
            stagePreview
              .frame(width: baseStageSize.width, height: baseStageSize.height)
              .scaleEffect(previewScale)
          }
          .frame(
            width: max(geo.size.width, scaledStageSize.width),
            height: max(geo.size.height, scaledStageSize.height)
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .frame(minHeight: usesStandaloneChrome ? 300 : 0)
      .layoutPriority(usesStandaloneChrome ? 1 : 0)
    }
    .modifier(StyledVideoPreviewChromeModifier(usesStandaloneChrome: usesStandaloneChrome))
  }

  private struct StyledVideoPreviewChromeModifier: ViewModifier {
    var usesStandaloneChrome: Bool

    func body(content: Content) -> some View {
      if usesStandaloneChrome {
        content
          .padding(EditorLayout.panelInset)
          .background(.thinMaterial, in: RoundedRectangle(cornerRadius: EditorLayout.panelCornerRadius, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: EditorLayout.panelCornerRadius, style: .continuous)
              .stroke(Color.primary.opacity(0.08), lineWidth: 1)
          }
      } else {
        content
          .padding(.horizontal, EditorLayout.panelInset)
          .padding(.top, EditorLayout.panelInset)
          .padding(.bottom, EditorLayout.panelInset / 2)
          .frame(maxHeight: .infinity, alignment: .top)
          .clipped()
      }
    }
  }

  private var previewToolbar: some View {
    HStack(spacing: 8) {
      Spacer()
      HStack(spacing: 8) {
        Image(systemName: "minus.magnifyingglass")
        Slider(value: $previewScale, in: 0.75...1.25, step: 0.05)
          .frame(width: 140)
        Image(systemName: "plus.magnifyingglass")
      }
      .foregroundStyle(.secondary)
      .font(.caption)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var stagePreview: some View {
    GeometryReader { geo in
      let scale = EditorPreviewLayout.visualScale(stageSize: geo.size)
      let outerPadding = CGFloat(visuals.backgroundPadding) * scale
      let cornerRadius = CGFloat(visuals.contentCornerRadius) * scale
      let shadowRadius = CGFloat(visuals.shadowRadius) * scale
      let outputAspect = project.outputAspectRatio.editorPreviewAspectRatio
      let contentAspect = EditorPreviewLayout.stageContentAspectRatio(
        outputAspectRatio: outputAspect,
        sourceKind: project.source.kind,
        sourceVideoSize: sourceVideoSize
      )
      let geometry = ArcShotRenderGeometry.make(
        stageSize: geo.size,
        contentAspectRatio: contentAspect,
        padding: outerPadding,
        contentInset: 0,
        cornerRadius: cornerRadius,
        sourceKind: project.source.kind,
        sourceVideoSize: sourceVideoSize
      )

      ZStack {
        backgroundView
          .blur(radius: CGFloat(visuals.backgroundBlur) * scale)

        floatingVideo(
          cornerRadius: geometry.cardCornerRadius,
          sourceCornerRadius: geometry.sourceCornerRadius,
          windowExportClipRadius: geometry.windowExportClipRadius,
          shadowRadius: shadowRadius,
          shadowYOffset: max(4, abs(CGFloat(visuals.shadowYOffset)) * scale),
          isWindowCapture: project.source.kind == .window
        )
        .frame(width: geometry.cardRect.width, height: geometry.cardRect.height)
        .position(x: geometry.cardRect.midX, y: geometry.cardRect.midY)

        if player == nil {
          Image(systemName: "film")
            .font(.system(size: 42, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.75))
        }

        if let activeShortcutOverlay {
          let shortcutRect = EditorPreviewKeyboardShortcut.previewRect(in: geo.size)
          previewShortcut(activeShortcutOverlay.text)
            .frame(width: max(1, shortcutRect.width), height: max(1, shortcutRect.height))
            .position(x: shortcutRect.midX, y: shortcutRect.midY)
            .allowsHitTesting(false)
        }

        ForEach(activeCaptionOverlays, id: \.renderID) { activeCaptionOverlay in
          let captionRect = EditorPreviewCaptionPresentation.previewRect(
            for: activeCaptionOverlay,
            in: geo.size
          )
          previewCaption(activeCaptionOverlay)
            .frame(width: max(1, captionRect.width), height: max(1, captionRect.height))
            .position(x: captionRect.midX, y: captionRect.midY)
            .allowsHitTesting(false)
        }

        let fadeOpacity = EditorPreviewFade.opacity(
          timeSeconds: previewTimeSeconds,
          durationSeconds: durationSeconds,
          styleSettings: project.styleSettings
        )
        if fadeOpacity > 0.001 {
          Color.black
            .opacity(fadeOpacity)
            .frame(width: geo.size.width, height: geo.size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .allowsHitTesting(false)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(0.22), lineWidth: 1)
      }
    }
  }

  @ViewBuilder
  private func floatingVideo(
    cornerRadius: CGFloat,
    sourceCornerRadius: CGFloat,
    windowExportClipRadius: CGFloat?,
    shadowRadius: CGFloat,
    shadowYOffset: CGFloat,
    isWindowCapture: Bool
  ) -> some View {
    let clipRadius: CGFloat = {
      if isWindowCapture, let windowExportClipRadius {
        return windowExportClipRadius
      }
      return 0
    }()
    let video = ZStack {
      GeometryReader { geo in
        let layoutSize = EditorPreviewLayout.stablePreviewContainerSize(geo.size)
        let previewTransform = activePreviewTransform(in: layoutSize)
        let isEditingMask = EditorPreviewMaskPresentation.showsRegionOverlay(
          isPlaying: isPlaying,
          selectedMaskID: selectedMaskID
        )
        ZStack {
          ZStack {
            EditorPlayerLayer(player: player)

            ForEach(activeBlurMasks) { mask in
              if !isEditingMask || mask.id != selectedMaskID {
                previewBlurMask(mask, in: layoutSize)
              }
            }
          }
          .scaleEffect(previewTransform.scale, anchor: .topLeading)
          .offset(previewTransform.offset)
          .animation(activePreviewZoomAnimation, value: activePreviewZoomSignature)
          .transaction { transaction in
            if isPlaying {
              transaction.animation = nil
            }
          }

          previewOverlays(in: layoutSize, previewTransform: previewTransform)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: clipRadius, style: .continuous))

    if isWindowCapture {
      video
    } else {
      video
        .compositingGroup()
        .shadow(
          color: Color.black.opacity(visuals.dropShadowOpacity * 0.42),
          radius: shadowRadius,
          x: 0,
          y: shadowYOffset
        )
    }
  }

  private func previewOverlays(
    in size: CGSize,
    previewTransform: (scale: CGFloat, offset: CGSize)
  ) -> some View {
    let isEditingMask = EditorPreviewMaskPresentation.showsRegionOverlay(
      isPlaying: isPlaying,
      selectedMaskID: selectedMaskID
    )
    return ZStack(alignment: .topLeading) {
        ForEach(activeHighlightMasks) { mask in
          if !isEditingMask || mask.id != selectedMaskID {
            previewHighlightMask(mask, in: size, previewTransform: previewTransform)
              .allowsHitTesting(false)
          }
        }

        if let activeCameraSegment, activeCameraSegment.layout != .hidden {
          previewCamera(
            activeCameraSegment,
            mediaURL: project.secondaryRecording?.mediaURL,
            in: size
          )
          .allowsHitTesting(
            EditorPreviewCameraPresentation.showsRegionOverlay(
              isPlaying: isPlaying,
              selectedCameraID: selectedCameraID
            )
          )
        }

        if let selectedCameraSegment,
          EditorPreviewCameraPresentation.showsRegionOverlay(
            isPlaying: isPlaying,
            selectedCameraID: selectedCameraID
          ) {
          CameraRegionOverlay(
            segment: selectedCameraSegment,
            containerSize: size,
            onUpdate: onUpdateCameraRegion
          )
        }

        if let point = cursorPoint(at: sourcePreviewTimeSeconds, in: size) {
          previewCursor(at: point)
            .allowsHitTesting(false)
        }

        if let cue = activeClickCue,
          let point = cursorPoint(
            at: EditorPreviewClickPulse.pulseCursorTimeSeconds(
              currentSourceTimeSeconds: sourcePreviewTimeSeconds
            ),
            in: size,
            maxGapSeconds: 0.35
          ) {
          previewClickCue(at: point, cue: cue)
            .allowsHitTesting(false)
        }

        if let selectedZoomSegment,
          EditorPreviewZoomPresentation.showsTargetOverlay(isPlaying: isPlaying, selectedZoomID: selectedZoomID) {
          ZoomTargetRegionOverlay(
            segment: selectedZoomSegment,
            sourceVideoSize: sourceVideoSize,
            previewTransform: previewTransform,
            onUpdate: onUpdateZoomTargetRegion
          )
        }

        if let selectedMask,
          EditorPreviewMaskPresentation.showsRegionOverlay(isPlaying: isPlaying, selectedMaskID: selectedMaskID) {
          MaskRegionOverlay(
            mask: selectedMask,
            sourceVideoSize: sourceVideoSize,
            previewTransform: previewTransform,
            onUpdate: onUpdateMaskRegion
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func previewBlurMask(
    _ mask: RecordingProject.VisualMask,
    in size: CGSize
  ) -> some View {
    let rect = EditorPreviewLayout.maskRect(
      mask: mask,
      in: size,
      sourceSize: sourceVideoSize
    )
    let videoRect = EditorPreviewLayout.aspectFitRect(sourceSize: sourceVideoSize, in: size)
    let blurRadius = VisualMaskStyle.previewBlurRadius(
      sourceSize: sourceVideoSize,
      videoRect: videoRect
    )
    let opacity = VisualMaskStyle.activeOpacity(at: sourcePreviewTimeSeconds, mask: mask)
    let shape = RoundedRectangle(cornerRadius: VisualMaskStyle.cornerRadius, style: .continuous)

    return EditorPlayerLayer(player: player)
      .blur(radius: blurRadius)
      .mask {
        shape
          .frame(width: max(1, rect.width), height: max(1, rect.height))
          .position(x: rect.midX, y: rect.midY)
      }
      .opacity(opacity)
      .allowsHitTesting(false)
  }

  private func previewHighlightMask(
    _ mask: RecordingProject.VisualMask,
    in size: CGSize,
    previewTransform: (scale: CGFloat, offset: CGSize)
  ) -> some View {
    let rect = EditorPreviewLayout.maskRect(
      mask: mask,
      in: size,
      sourceSize: sourceVideoSize,
      previewTransform: previewTransform
    )
    let style = EditorPreviewMaskPresentation.style(for: mask.kind)
    let activeOpacity = EditorPreviewMaskPresentation.activeOpacity(at: sourcePreviewTimeSeconds, mask: mask)
    let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)

    return shape
      .fill(Color.yellow.opacity(style.fillOpacity))
      .overlay {
        shape
          .stroke(Color.yellow.opacity(style.strokeOpacity), lineWidth: style.strokeLineWidth)
      }
      .opacity(activeOpacity)
      .frame(width: max(1, rect.width), height: max(1, rect.height))
      .position(x: rect.midX, y: rect.midY)
      .animation(activePreviewZoomAnimation, value: activePreviewZoomSignature)
  }

  private func previewCursor(at point: CGPoint) -> some View {
    CursorPreviewView(
      sizeScale: CGFloat(project.cursorVisualSettings.sizeScale),
      pointerStyle: project.cursorVisualSettings.pointerStyle,
      clickProgress: nil,
      ringPhase: CGFloat(sourcePreviewTimeSeconds.truncatingRemainder(dividingBy: 0.6) / 0.6)
    )
      .position(x: point.x, y: point.y)
      .animation(activePreviewZoomAnimation, value: activePreviewZoomSignature)
  }

  private func previewCamera(
    _ segment: RecordingProject.CameraLayoutSegment,
    mediaURL: URL?,
    in size: CGSize
  ) -> some View {
    let presentation = EditorPreviewCameraPresentation.presentation(
      for: segment,
      isZoomActive: activePreviewZoomState != nil
    )
    let rect = EditorPreviewCameraPresentation.previewRect(
      for: presentation,
      in: size,
      sourceVideoSize: sourceVideoSize
    )

    return ZStack {
      if !presentation.isHidden {
        ZStack {
          if let mediaURL {
            CameraPiPPlayerView(
              url: mediaURL,
              timeSeconds: sourcePreviewTimeSeconds,
              isPlaying: isPlaying,
              playbackRate: EditorPreviewCameraPresentation.playbackRate(
                atTimelineSeconds: previewTimeSeconds,
                timeline: project.timeline
              )
            )
            .scaleEffect(x: segment.isMirrored ? -1 : 1, y: 1)
          } else {
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
              .fill(Color.black.opacity(0.36))
              .overlay {
                LinearGradient(
                  colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              }
              .overlay {
                Image(systemName: "video.fill")
                  .font(.system(size: segment.layout == .fullscreen ? 34 : 16, weight: .semibold))
                  .foregroundStyle(.white.opacity(0.72))
                  .scaleEffect(x: segment.isMirrored ? -1 : 1, y: 1)
              }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous))
        .overlay {
          RoundedRectangle(
            cornerRadius: presentation.cornerRadius,
            style: .continuous
          )
          .stroke(Color.white.opacity(0.30), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)
      }
    }
    .opacity(presentation.isHidden ? 0 : 1)
    .frame(width: max(1, rect.width), height: max(1, rect.height))
    .position(x: rect.midX, y: rect.midY)
  }

  private func previewClickCue(at point: CGPoint, cue: RecordingProject.CursorClickCue) -> some View {
    let progress = CursorRenderer.clickPulseProgress(
      at: sourcePreviewTimeSeconds,
      clickCues: [cue]
    )
    return CursorPreviewView(
      sizeScale: CGFloat(project.cursorVisualSettings.sizeScale),
      pointerStyle: project.cursorVisualSettings.pointerStyle,
      clickProgress: progress,
      ringPhase: CGFloat(sourcePreviewTimeSeconds.truncatingRemainder(dividingBy: 0.6) / 0.6)
    )
      .position(x: point.x, y: point.y)
      .animation(activePreviewZoomAnimation, value: activePreviewZoomSignature)
  }

  private func previewShortcut(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 17, weight: .semibold, design: .rounded))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))
      .overlay {
        Capsule(style: .continuous)
          .stroke(Color.white.opacity(0.24), lineWidth: 1)
      }
  }

  private func previewCaption(_ overlay: EditorPreviewCaptionPresentation.Overlay) -> some View {
    Text(overlay.text)
      .font(.custom("Helvetica", size: CGFloat(overlay.style.fontPointSize)))
      .foregroundStyle(.white)
      .multilineTextAlignment(.center)
      .padding(.horizontal, overlay.style.horizontalTextInset)
      .padding(.vertical, overlay.style.verticalTextInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        Color.black.opacity(overlay.style.backgroundOpacity),
        in: RoundedRectangle(cornerRadius: overlay.style.cornerRadius, style: .continuous)
      )
      .opacity(overlay.opacity)
  }

  private func cursorPoint(
    at timeSeconds: Double,
    in size: CGSize,
    maxGapSeconds: Double? = nil
  ) -> CGPoint? {
    guard project.cursorVisualSettings.isVisible, !project.cursorSamples.isEmpty else { return nil }
    let maxGap = maxGapSeconds ?? (project.cursorVisualSettings.hideWhenIdle ? 0.18 : 0.45)
    let nearestDistance = project.cursorSamples
      .map { abs($0.timeSeconds - timeSeconds) }
      .min() ?? .infinity
    guard nearestDistance <= maxGap else { return nil }

    let interpolated = CursorRenderer.interpolateCursorPosition(
      at: timeSeconds,
      samples: project.cursorSamples.sorted { $0.timeSeconds < $1.timeSeconds }
    )
    let basePoint = EditorPreviewLayout.cursorPoint(
      sample: RecordingProject.CursorSample(
        timeSeconds: timeSeconds,
        x: interpolated.x,
        y: interpolated.y
      ),
      in: size,
      sourceSize: sourceVideoSize
    )
    let finalPoint = applyingActivePreviewTransform(to: basePoint, in: size)
    return finalPoint
  }

  @ViewBuilder
  private var backgroundView: some View {
    switch visuals.backgroundKind {
    case .solid:
      Color(nsColor: EditorHexColor.nsColor(rgbHex: visuals.backgroundColorHex))
    case .linearGradientVertical:
      LinearGradient(
        colors: [
          Color(nsColor: EditorHexColor.nsColor(rgbHex: visuals.backgroundColorHex)),
          Color(nsColor: EditorHexColor.nsColor(rgbHex: visuals.gradientEndColorHex)),
        ],
        startPoint: backgroundMode == .wallpaper ? .topLeading : .top,
        endPoint: backgroundMode == .wallpaper ? .bottomTrailing : .bottom
      )
      .overlay {
        if backgroundMode == .wallpaper {
          LinearGradient(
            colors: [
              Color.white.opacity(0.20),
              Color.clear,
              EditorPalette.brand.opacity(0.18),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
        }
      }
    }
  }
}
