@preconcurrency import AVFoundation
import SwiftUI

private enum ReviewTrimUIConstants {
  static let minTrimWindowSeconds: Double = 0.1
  static let minZoomSeconds: Double = RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds
  static let minHighlightSeconds: Double = RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds
  static let timelineHeight: CGFloat = 72
  static let highlightTrackHeight: CGFloat = 56
  static let handleWidth: CGFloat = 10
  static let pixelsPerTimelineSecond: CGFloat = 80
  /// Extra vertical space under scroll tracks inside the Timeline group box (labels / padding).
  static let timelineChromeBelowTracks: CGFloat = 56

  /// `AVPlayer` periodic boundary check cadence while looping a selection interval.
  static let playbackLoopPollSeconds: Double = 0.05
  /// How close to selection end triggers a jump back to source start (~one SD frame step).
  static let playbackLoopEndEpsilonSeconds: Double = 0.03
}

struct ReviewTrimView: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppLanguageStore.self) private var languageStore
  @AppStorage(AppIdentifiers.UserDefaultsKeys.reviewLoopTrimSelection) private var loopTrimSelection = true
  private let playheadNudgeSeconds: Double = 0.05

  @State private var timelineUndo = ReviewTimelineUndoController()
  @State private var playheadTicker = ReviewPlayheadTicker()

  @State private var playbackLoopCoordinator = ReviewTrimPlaybackLoopCoordinator()
  @State private var player: AVPlayer?
  @State private var previewThumbnail: NSImage?
  @State private var durationSeconds: Double = 0
  @State private var frameStepSeconds: Double = 1.0 / 60.0
  @State private var waveformBins: [Float] = []
  @State private var startSeconds: Double = 0
  @State private var endSeconds: Double = 0
  @State private var selectedZoomID: RecordingProject.ZoomKeyframe.ID?
  @State private var selectedHighlightID: RecordingProject.CursorHighlightRegion.ID?

  @State private var zoomGestureBaseline: [RecordingProject.ZoomKeyframe]?
  @State private var highlightGestureBaseline: [RecordingProject.CursorHighlightRegion]?
  @State private var zoomInspectorBaseline: [RecordingProject.ZoomKeyframe]?

  var body: some View {
    VStack(alignment: .leading, spacing: AppUIMetrics.contentSpacing) {
      Text("編集（長さ・カーソル・字幕）")
        .font(.largeTitle.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      if let project = projectStore.current {
        Text(project.mediaURL.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        HStack(spacing: AppUIMetrics.groupSpacing) {
          Button("取り消し") {
            timelineUndo.undoManager.undo()
          }
          .keyboardShortcut("z", modifiers: .command)
          .disabled(!timelineUndo.undoManager.canUndo)
          .accessibilityLabel("取り消し")
          .accessibilityHint("直前のタイムライン操作を元に戻します")

          Button("やり直し") {
            timelineUndo.undoManager.redo()
          }
          .keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(!timelineUndo.undoManager.canRedo)
          .accessibilityLabel("やり直し")

          Divider().frame(height: 14)

          Button("アプリ内で再生") {
            InAppVideoPreviewWindowController.shared.show(
              url: project.mediaURL,
              title: languageStore.localizedProjectDisplayTitle(
                storedTitle: project.title,
                createdAt: project.createdAt
              )
            )
          }
          .keyboardShortcut(.space, modifiers: [])
          .accessibilityLabel("保存された録画をアプリ内で再生")

          Button("−0.05秒") {
            nudgePlayhead(by: -playheadNudgeSeconds)
          }
          .keyboardShortcut(.leftArrow, modifiers: [])
          .accessibilityLabel("再生ヘッドを少し戻す")

          Button("+0.05秒") {
            nudgePlayhead(by: playheadNudgeSeconds)
          }
          .keyboardShortcut(.rightArrow, modifiers: [])
          .accessibilityLabel("再生ヘッドを少し進める")

          Button("前のフレーム") {
            stepFrame(byFrames: -1)
          }
          .keyboardShortcut("[", modifiers: [])
          .accessibilityLabel("前のフレーム")

          Button("次のフレーム") {
            stepFrame(byFrames: 1)
          }
          .keyboardShortcut("]", modifiers: [])
          .accessibilityLabel("次のフレーム")

          Spacer()
          Text(languageStore.localizedFormat("Keyboard shortcuts summary %.2f", playheadNudgeSeconds))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("ショートカット一覧はメニューバーのヘルプからも開けます")
        }
        .buttonStyle(.bordered)

        GroupBox("プレビュー") {
          VStack(alignment: .leading, spacing: AppUIMetrics.tightSpacing) {
            Toggle("選択範囲をループ再生", isOn: $loopTrimSelection)
              .accessibilityHint("トリムの開始と終了の間だけ繰り返し再生します")

            if let previewThumbnail {
              Image(nsImage: previewThumbnail)
                .resizable()
                .scaledToFit()
                .frame(minHeight: 360)
                .accessibilityLabel("収録プレビュー")
            } else {
              VStack(spacing: 8) {
                Image(systemName: "film")
                  .font(.system(size: 32, weight: .medium))
                  .foregroundStyle(.secondary)
                Text("プレビューを読み込み中…")
                  .foregroundStyle(.secondary)
              }
                .frame(minHeight: 360)
            }
          }
        }

        GroupBox("トリム") {
          VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
            HStack {
              Text("開始")
              Slider(value: $startSeconds, in: 0...max(0, durationSeconds - ReviewTrimUIConstants.minTrimWindowSeconds))
                .onChange(of: startSeconds) { _, newValue in
                  if newValue > endSeconds - ReviewTrimUIConstants.minTrimWindowSeconds {
                    endSeconds = min(durationSeconds, newValue + ReviewTrimUIConstants.minTrimWindowSeconds)
                  }
                  seekPreview(to: newValue)
                }
              Text(startSeconds, format: .number.precision(.fractionLength(2)))
                .frame(width: 70, alignment: .trailing)
            }

            HStack {
              Text("終了")
              Slider(value: $endSeconds, in: ReviewTrimUIConstants.minTrimWindowSeconds...max(ReviewTrimUIConstants.minTrimWindowSeconds, durationSeconds))
                .onChange(of: endSeconds) { _, newValue in
                  if newValue < startSeconds + ReviewTrimUIConstants.minTrimWindowSeconds {
                    startSeconds = max(0, newValue - ReviewTrimUIConstants.minTrimWindowSeconds)
                  }
                  seekPreview(to: newValue)
                }
              Text(endSeconds, format: .number.precision(.fractionLength(2)))
                .frame(width: 70, alignment: .trailing)
            }

            Button("トリムを保存") {
              guard let beforeProj = projectStore.current else { return }
              var updated = beforeProj
              updated.timeline.ensureSingleEditableClip(
                mediaURL: updated.mediaURL,
                sourceStartSeconds: startSeconds,
                sourceEndSeconds: endSeconds,
                assetDurationSeconds: durationSeconds
              )
              updated.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
                clampZoomKeyframesToTrim(
                  updated.zoomSegments.map(\.asZoomKeyframe),
                  trimStart: startSeconds,
                  selectionEnd: endSeconds,
                  assetDuration: durationSeconds
                ).map(RecordingProject.ZoomSegment.fromKeyframe),
                durationSeconds: durationSeconds
              )
              updated.cursorHighlightRegions = clampHighlightRegionsToTrim(
                updated.cursorHighlightRegions,
                trimStart: startSeconds,
                selectionEnd: endSeconds,
                assetDuration: durationSeconds
              )
              updated.cursorHighlightRegions = sanitizedHighlightRegions(
                updated.cursorHighlightRegions,
                durationSeconds: durationSeconds
              )
              updated.cursorClickCues = clampClickCuesToTrim(
                updated.cursorClickCues,
                trimStart: startSeconds,
                selectionEnd: endSeconds,
                assetDuration: durationSeconds
              )
              updated.textOverlayAnnotations = clampTextOverlayAnnotationsToTrim(
                updated.textOverlayAnnotations,
                trimStart: startSeconds,
                selectionEnd: endSeconds,
                assetDuration: durationSeconds
              )
              updated.cursorClickCues = RecordingProject.clampedSortedClickCueTimes(
                updated.cursorClickCues,
                compositionDurationSeconds: durationSeconds
              )
              updated.textOverlayAnnotations = RecordingProject.TextOverlaySanitizeDefaults.sanitized(
                updated.textOverlayAnnotations,
                durationSeconds: durationSeconds
              )
              timelineUndo.finalizeWholeProjectUndo(undoLabel: "トリムを保存", before: beforeProj, after: updated)
            }

            GroupBox("タイムライン") {
              GeometryReader { geo in
                let timelineWidth = max(
                  geo.size.width,
                  CGFloat(durationSeconds) * ReviewTrimUIConstants.pixelsPerTimelineSecond
                )
                ScrollView(.horizontal) {
                  VStack(alignment: .leading, spacing: 10) {
                    TimelineScrubbingRow(
                      durationSeconds: durationSeconds,
                      playheadSeconds: playheadTicker.seconds,
                      sourceStartSeconds: startSeconds,
                      selectionEndSeconds: endSeconds,
                      waveformPeaksNormalized: waveformBins,
                      snapToFrameQuantizationSeconds: frameStepSeconds,
                      onSeek: { seconds in seekPreview(to: seconds) }
                    )
                    .frame(width: timelineWidth, alignment: .leading)

                    ZoomTrack(
                      durationSeconds: durationSeconds,
                      sourceStartSeconds: startSeconds,
                      selectionEndSeconds: endSeconds,
                      keyframes: project.zoomSegments.map(\.asZoomKeyframe),
                      selectedID: selectedZoomID,
                      onSelect: { selectedZoomID = $0 },
                      onLiveFrames: { frames in
                        let segments = sanitizedZoomKeyframes(frames, durationSeconds: durationSeconds)
                          .map(RecordingProject.ZoomSegment.fromKeyframe)
                        projectStore.applyToCurrent({ $0.zoomSegments = segments }, persist: false)
                      },
                      onGestureBegan: {
                        guard zoomGestureBaseline == nil else { return }
                        zoomGestureBaseline =
                          projectStore.current.map {
                            sanitizedZoomKeyframes($0.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
                          }
                      },
                      onGestureEnded: {
                        finalizeZoomGestureUndo()
                      }
                    )
                    .frame(width: timelineWidth, height: ReviewTrimUIConstants.timelineHeight)

                    CursorHighlightTrack(
                      durationSeconds: durationSeconds,
                      sourceStartSeconds: startSeconds,
                      selectionEndSeconds: endSeconds,
                      regions: project.cursorHighlightRegions,
                      selectedID: selectedHighlightID,
                      onSelect: { selectedHighlightID = $0 },
                      onLiveRegions: { regs in
                        guard var cur = projectStore.current else { return }
                        cur.cursorHighlightRegions = sanitizedHighlightRegions(regs, durationSeconds: durationSeconds)
                        projectStore.applyToCurrent({ $0.cursorHighlightRegions = cur.cursorHighlightRegions }, persist: false)
                      },
                      onGestureBegan: {
                        guard highlightGestureBaseline == nil else { return }
                        highlightGestureBaseline =
                          projectStore.current.map {
                            sanitizedHighlightRegions($0.cursorHighlightRegions, durationSeconds: durationSeconds)
                          }
                      },
                      onGestureEnded: {
                        finalizeHighlightGestureUndo()
                      }
                    )
                    .frame(width: timelineWidth, height: ReviewTrimUIConstants.highlightTrackHeight)
                  }
                  .frame(minHeight: geo.size.height, alignment: .topLeading)
                  .padding(.vertical, 6)
                }
              }
              .frame(
                minHeight: ReviewTrimUIConstants.timelineHeight + ReviewTrimUIConstants.highlightTrackHeight
                  + ReviewTrimUIConstants.timelineChromeBelowTracks
              )

              VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 12) {
                  Button("選択範囲にズームを追加") {
                    guard let proj = projectStore.current else { return }
                    let kf = RecordingProject.ZoomKeyframe(
                      startSeconds: startSeconds,
                      endSeconds: endSeconds,
                      scale: 1.5,
                      anchorX: 0.5,
                      anchorY: 0.5
                    )
                    let beforeKF = sanitizedZoomKeyframes(proj.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
                    let afterKF = sanitizedZoomKeyframes(beforeKF + [kf], durationSeconds: durationSeconds)
                    selectedZoomID = kf.id
                    timelineUndo.replaceZoomKeyframesWithUndo(undoLabel: "ズームを追加", before: beforeKF, after: afterKF)
                  }
                  .disabled(durationSeconds <= 0 || endSeconds <= startSeconds + ReviewTrimUIConstants.minZoomSeconds)

                  Button("カーソルからズーム候補を挿入") {
                    guard let proj = projectStore.current else { return }
                    let beforeSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(proj.zoomSegments, durationSeconds: durationSeconds)
                    let beforeKF = sanitizedZoomKeyframes(beforeSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
                    var proposed = AutoZoomPipeline.generate(
                      from: proj,
                      assetDurationSeconds: durationSeconds
                    ).zoomSegments.filter { segment in
                      !beforeKF.contains { keyframe in
                        max(segment.startSeconds, keyframe.startSeconds) < min(segment.endSeconds, keyframe.endSeconds)
                      }
                    }
                    if proposed.isEmpty {
                      proposed = CursorZoomHeuristics.suggestZoomKeyframes(
                        samples: proj.cursorSamples,
                        clickCues: proj.cursorClickCues,
                        assetDurationSeconds: durationSeconds,
                        existingKeyframes: beforeKF
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
                    guard !proposed.isEmpty else { return }
                    let afterSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(beforeSegments + proposed, durationSeconds: durationSeconds)
                    timelineUndo.replaceZoomSegmentsWithUndo(undoLabel: "候補ズームを挿入", before: beforeSegments, after: afterSegments)
                  }
                  .disabled(project.cursorSamples.count < 2 || durationSeconds <= 0)

                  Button("クリックキューを推測して追加") {
                    guard let proj = projectStore.current else { return }
                    let before = proj.cursorClickCues
                    let proposed = CursorClickHeuristics.suggestClickCues(samples: proj.cursorSamples, existing: proj.cursorClickCues)
                    guard !proposed.isEmpty else { return }
                    var merged = before
                    let minGap = CursorClickHeuristics.Defaults.minSpacingSeconds
                    for c in proposed {
                      guard !merged.contains(where: { abs($0.timeSeconds - c.timeSeconds) < minGap }) else { continue }
                      merged.append(c)
                    }
                    let after = RecordingProject.clampedSortedClickCueTimes(merged, compositionDurationSeconds: durationSeconds)
                    timelineUndo.replaceClickCuesWithUndo(undoLabel: "クリックキューを挿入", before: before, after: after)
                  }
                  .disabled(project.cursorSamples.count < 3 || durationSeconds <= 0)

                  Button("選択範囲にカーソルハイライト") {
                    guard let proj = projectStore.current else { return }
                    let r = RecordingProject.CursorHighlightRegion(
                      startSeconds: startSeconds,
                      endSeconds: endSeconds
                    )
                    let beforeR = sanitizedHighlightRegions(proj.cursorHighlightRegions, durationSeconds: durationSeconds)
                    let afterR = sanitizedHighlightRegions(beforeR + [r], durationSeconds: durationSeconds)
                    selectedHighlightID = r.id
                    timelineUndo.replaceHighlightRegionsWithUndo(undoLabel: "ハイライトを追加", before: beforeR, after: afterR)
                  }
                  .disabled(durationSeconds <= 0 || endSeconds <= startSeconds + ReviewTrimUIConstants.minHighlightSeconds)

                  Button("選択中のズームを削除", role: .destructive) {
                    guard let selectedZoomID,
                      let proj = projectStore.current
                    else { return }
                    let beforeKF = sanitizedZoomKeyframes(proj.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
                    let afterKF = beforeKF.filter { $0.id != selectedZoomID }
                    self.selectedZoomID = nil
                    timelineUndo.replaceZoomKeyframesWithUndo(undoLabel: "ズームを削除", before: beforeKF, after: afterKF)
                  }
                  .disabled(selectedZoomID == nil)

                  Button("選択中のハイライトを削除", role: .destructive) {
                    guard let selectedHighlightID,
                      let proj = projectStore.current
                    else { return }
                    let beforeR = sanitizedHighlightRegions(proj.cursorHighlightRegions, durationSeconds: durationSeconds)
                    let afterR = beforeR.filter { $0.id != selectedHighlightID }
                    self.selectedHighlightID = nil
                    timelineUndo.replaceHighlightRegionsWithUndo(undoLabel: "ハイライトを削除", before: beforeR, after: afterR)
                  }
                  .disabled(selectedHighlightID == nil)

                  Spacer()
                  Text(languageStore.localizedFormat(
                    "ズーム %d · ハイライト %d · クリック %d",
                    project.zoomSegments.count,
                    project.cursorHighlightRegions.count,
                    project.cursorClickCues.count
                  ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                selectedZoomInspector(project: project)
              }
              .padding(.vertical, 6)
            }
          }
          .padding(.vertical, 6)
        }
      } else {
        Text("プロジェクトがありません。左の「キャプチャ」から録画を開始してください。")
          .foregroundStyle(.secondary)
      }

      Spacer()
    }

    .focusable()
    .onAppear {
      timelineUndo.projectStore = projectStore
      playheadTicker.bind(player: player, clampDuration: durationSeconds)
      if selectedZoomID != nil, let cur = projectStore.current {
        zoomInspectorBaseline = sanitizedZoomKeyframes(cur.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
      }
    }
    .onChange(of: selectedZoomID) { _, newID in
      finalizeZoomInspectorIfNeededForSelectionChange(to: newID)
    }
    .onChange(of: player) { _, _ in playheadTicker.bind(player: player, clampDuration: durationSeconds) }
    .onChange(of: durationSeconds) { _, _ in playheadTicker.bind(player: player, clampDuration: durationSeconds) }
    .onDisappear {
      playbackLoopCoordinator.stop()
      player?.pause()
      playheadTicker.detach()
    }
    .onChange(of: loopTrimSelection) { _, _ in syncPlaybackLoop() }
    .onChange(of: startSeconds) { _, _ in syncPlaybackLoop() }
    .onChange(of: endSeconds) { _, _ in syncPlaybackLoop() }
    .onChange(of: durationSeconds) { _, _ in syncPlaybackLoop() }
    .task {
      await loadIfNeeded()
    }
  }

  private func syncPlaybackLoop() {
    playbackLoopCoordinator.update(
      player: player,
      loopEnabled: loopTrimSelection,
      sourceStartSeconds: startSeconds,
      selectionEndSeconds: endSeconds,
      assetDurationSeconds: durationSeconds
    )
  }

  @ViewBuilder
  private func selectedZoomInspector(project: RecordingProject) -> some View {
    if let sid = selectedZoomID,
      project.zoomSegments.contains(where: { $0.id == sid }) {
      GroupBox("選択中のズーム — 倍率・アンカー") {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("倍率")
              .frame(width: 72, alignment: .leading)
            Slider(
              value: zoomScaleBinding(for: sid),
              in: RecordingProject.TimelineKeyframeSanitize.minZoomScale
                ... RecordingProject.TimelineKeyframeSanitize.maxZoomScale
            )
            Text(projectStore.current?.zoomSegments.first { $0.id == sid }?.scale ?? 1, format: .number.precision(.fractionLength(2)))
              .frame(width: 44, alignment: .trailing)
              .monospacedDigit()
          }
          HStack {
            Text("アンカー X")
              .frame(width: 72, alignment: .leading)
            Slider(value: zoomAnchorXBinding(for: sid), in: 0 ... 1)
            Text(projectStore.current?.zoomSegments.first { $0.id == sid }?.anchorX ?? 0.5, format: .number.precision(.fractionLength(2)))
              .frame(width: 44, alignment: .trailing)
              .monospacedDigit()
          }
          HStack {
            Text("アンカー Y")
              .frame(width: 72, alignment: .leading)
            Slider(value: zoomAnchorYBinding(for: sid), in: 0 ... 1)
            Text(projectStore.current?.zoomSegments.first { $0.id == sid }?.anchorY ?? 0.5, format: .number.precision(.fractionLength(2)))
              .frame(width: 44, alignment: .trailing)
              .monospacedDigit()
          }
        }
      }
    }
  }

  private func zoomScaleBinding(for id: RecordingProject.ZoomKeyframe.ID) -> Binding<Double> {
    Binding(
      get: { projectStore.current?.zoomSegments.first { $0.id == id }?.scale ?? 1 },
      set: { v in
        projectStore.applyToCurrent({
          guard let i = $0.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
          $0.zoomSegments[i].scale = v
          $0.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments($0.zoomSegments, durationSeconds: durationSeconds)
        }, persist: false)
      }
    )
  }

  private func zoomAnchorXBinding(for id: RecordingProject.ZoomKeyframe.ID) -> Binding<Double> {
    Binding(
      get: { projectStore.current?.zoomSegments.first { $0.id == id }?.anchorX ?? 0.5 },
      set: { v in
        projectStore.applyToCurrent({
          guard let i = $0.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
          $0.zoomSegments[i].anchorX = v
          $0.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments($0.zoomSegments, durationSeconds: durationSeconds)
        }, persist: false)
      }
    )
  }

  private func zoomAnchorYBinding(for id: RecordingProject.ZoomKeyframe.ID) -> Binding<Double> {
    Binding(
      get: { projectStore.current?.zoomSegments.first { $0.id == id }?.anchorY ?? 0.5 },
      set: { v in
        projectStore.applyToCurrent({
          guard let i = $0.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
          $0.zoomSegments[i].anchorY = v
          $0.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments($0.zoomSegments, durationSeconds: durationSeconds)
        }, persist: false)
      }
    )
  }

  private func finalizeZoomInspectorIfNeededForSelectionChange(to newSelectionID: RecordingProject.ZoomKeyframe.ID?) {
    let previousBaseline = zoomInspectorBaseline
    zoomInspectorBaseline = nil

    if let baseline = previousBaseline, let cur = projectStore.current {
      let after = sanitizedZoomKeyframes(cur.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
      timelineUndo.finalizeZoomKeyframesUndo(undoLabel: "ズームのアンカー／倍率を調整", before: baseline, after: after)
    }

    if newSelectionID != nil, let cur = projectStore.current {
      zoomInspectorBaseline = sanitizedZoomKeyframes(cur.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
    }
  }

  private func finalizeZoomGestureUndo() {
    let before = zoomGestureBaseline
    zoomGestureBaseline = nil
    guard let cur = projectStore.current else { return }
    let after = sanitizedZoomKeyframes(cur.zoomSegments.map(\.asZoomKeyframe), durationSeconds: durationSeconds)
    timelineUndo.finalizeZoomKeyframesUndo(
      undoLabel: "ズーム範囲を調整",
      before: before ?? after,
      after: after
    )
  }

  private func finalizeHighlightGestureUndo() {
    let before = highlightGestureBaseline
    highlightGestureBaseline = nil
    guard let cur = projectStore.current else { return }
    let after = sanitizedHighlightRegions(cur.cursorHighlightRegions, durationSeconds: durationSeconds)
    timelineUndo.finalizeHighlightRegionsUndo(
      undoLabel: "ハイライト範囲を調整",
      before: before ?? after,
      after: after
    )
  }

  private func togglePlayback() {
    guard let player else { return }
    if player.rate > 1e-9 {
      player.pause()
    } else {
      player.play()
      syncPlaybackLoop()
    }
  }

  private func nudgePlayhead(by delta: Double) {
    guard durationSeconds > 0 else { return }
    seekPreview(to: playheadTicker.seconds + delta)
  }

  private func stepFrame(byFrames delta: Int) {
    guard durationSeconds > 0, frameStepSeconds > 1e-12 else { return }
    let q = frameStepSeconds
    let idxRounded = (playheadTicker.seconds / q).rounded(.toNearestOrAwayFromZero)
    let nextSeconds = max(0, min(durationSeconds, (idxRounded + Double(delta)) * q))
    seekPreview(to: nextSeconds)
  }

  private func seekPreview(to seconds: Double) {
    let capped = max(0, min(durationSeconds, seconds))
    seek(to: capped)
    playheadTicker.seconds = capped
  }

  private func loadIfNeeded() async {
    guard let project = projectStore.current else { return }
    let asset = AVURLAsset(url: project.mediaURL)
    do {
      let duration = try await asset.load(.duration)
      let seconds = max(0, duration.seconds)
      durationSeconds = seconds

      if let clip = project.timeline.singleEditableClip {
        startSeconds = min(max(0, clip.sourceStartSeconds), seconds)
        endSeconds = min(max(ReviewTrimUIConstants.minTrimWindowSeconds, clip.sourceStartSeconds + clip.durationSeconds), seconds)
      } else {
        startSeconds = 0
        endSeconds = seconds
      }

      var normalized = project
      let segments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(normalized.zoomSegments, durationSeconds: seconds)
      let hi = sanitizedHighlightRegions(normalized.cursorHighlightRegions, durationSeconds: seconds)
      if segments != normalized.zoomSegments || hi != normalized.cursorHighlightRegions {
        normalized.zoomSegments = segments
        normalized.cursorHighlightRegions = hi
        projectStore.setCurrent(normalized)
        projectStore.saveCurrent()
      }

      let item = AVPlayerItem(asset: asset)
      let av = AVPlayer(playerItem: item)
      player = av
      playheadTicker.bind(player: av, clampDuration: seconds)
      previewThumbnail = try? await Self.makePreviewThumbnail(asset: asset)

      let vtracks = try await asset.loadTracks(withMediaType: .video)
      if let vtrack = vtracks.first {
        let nominalFrameRate = try await vtrack.load(.nominalFrameRate)
        let fr = Double(nominalFrameRate)
        if fr > 1 {
          frameStepSeconds = min(max(1.0 / fr, 1.0 / 240.0), 0.2)
        } else {
          frameStepSeconds = 1.0 / 60.0
        }
      } else {
        frameStepSeconds = 1.0 / 60.0
      }

      let mediaURL = project.mediaURL
      Task { [mediaURL, seconds] in
        let bins = (try? await TimelineAudioWaveformLoader.peakEnvelopeNormalizedBins(
          assetURL: mediaURL,
          assetDurationSeconds: seconds
        )) ?? []
        await MainActor.run {
          guard projectStore.current?.mediaURL == mediaURL else { return }
          waveformBins = bins
        }
      }
    } catch {
      // Fallback: keep view usable even if duration can't be loaded.
      durationSeconds = 0
      frameStepSeconds = 1.0 / 60.0
      waveformBins = []
      previewThumbnail = nil
      let av = AVPlayer(url: project.mediaURL)
      player = av
      playheadTicker.bind(player: av, clampDuration: 0)
    }
  }

  private func seek(to seconds: Double) {
    guard let player else { return }
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  private static func makePreviewThumbnail(asset: AVAsset) async throws -> NSImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 720)
    let image = try await generator.image(at: .zero).image
    return NSImage(cgImage: image, size: .zero)
  }
}

private extension ReviewTrimView {
  func sanitizedZoomKeyframes(_ keyframes: [RecordingProject.ZoomKeyframe], durationSeconds: Double) -> [RecordingProject.ZoomKeyframe] {
    RecordingProject.TimelineKeyframeSanitize.zoomFrames(keyframes, durationSeconds: durationSeconds)
  }

  func sanitizedHighlightRegions(_ regions: [RecordingProject.CursorHighlightRegion], durationSeconds: Double)
    -> [RecordingProject.CursorHighlightRegion]
  {
    RecordingProject.TimelineKeyframeSanitize.highlightRegions(regions, durationSeconds: durationSeconds)
  }

  func clampZoomKeyframesToTrim(
    _ keyframes: [RecordingProject.ZoomKeyframe],
    trimStart: Double,
    selectionEnd: Double,
    assetDuration: Double
  ) -> [RecordingProject.ZoomKeyframe] {
    let trimS = trimStart
    let trimE = selectionEnd
    guard trimE > trimS, assetDuration > 0 else { return keyframes }

    var out: [RecordingProject.ZoomKeyframe] = []
    for var kf in keyframes {
      let s = max(kf.startSeconds, trimS)
      let e = min(kf.endSeconds, trimE)
      guard e > s else { continue }
      if e - s < ReviewTrimUIConstants.minZoomSeconds { continue }
      kf.startSeconds = s
      kf.endSeconds = e
      out.append(kf)
    }
    return out.sorted { $0.startSeconds < $1.startSeconds }
  }

  func clampHighlightRegionsToTrim(
    _ regions: [RecordingProject.CursorHighlightRegion],
    trimStart: Double,
    selectionEnd: Double,
    assetDuration: Double
  ) -> [RecordingProject.CursorHighlightRegion] {
    let trimS = trimStart
    let trimE = selectionEnd
    guard trimE > trimS, assetDuration > 0 else { return regions }

    var out: [RecordingProject.CursorHighlightRegion] = []
    for var r in regions {
      let s = max(r.startSeconds, trimS)
      let e = min(r.endSeconds, trimE)
      guard e > s else { continue }
      if e - s < ReviewTrimUIConstants.minHighlightSeconds { continue }
      r.startSeconds = s
      r.endSeconds = e
      out.append(r)
    }
    return out.sorted { $0.startSeconds < $1.startSeconds }
  }

  func clampClickCuesToTrim(
    _ cues: [RecordingProject.CursorClickCue],
    trimStart: Double,
    selectionEnd: Double,
    assetDuration _: Double
  ) -> [RecordingProject.CursorClickCue] {
    let trimS = trimStart
    let trimE = selectionEnd
    guard trimE > trimS else { return cues }
    return cues.filter { $0.timeSeconds >= trimS - 1e-9 && $0.timeSeconds <= trimE + 1e-9 }
      .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  func clampTextOverlayAnnotationsToTrim(
    _ overlays: [RecordingProject.TextOverlayAnnotation],
    trimStart: Double,
    selectionEnd: Double,
    assetDuration: Double
  ) -> [RecordingProject.TextOverlayAnnotation] {
    let trimS = trimStart
    let trimE = selectionEnd
    guard trimE > trimS, assetDuration > 0 else { return overlays }

    var out: [RecordingProject.TextOverlayAnnotation] = []
    for var o in overlays {
      let s = max(o.startSeconds, trimS)
      let e = min(o.endSeconds, trimE)
      guard e > s else { continue }
      o.startSeconds = s
      o.endSeconds = e
      out.append(o)
    }
    return out.sorted { $0.startSeconds < $1.startSeconds }
  }
}

private struct TimelineScrubbingRow: View {
  @Environment(AppLanguageStore.self) private var languageStore

  var durationSeconds: Double
  var playheadSeconds: Double
  var sourceStartSeconds: Double
  var selectionEndSeconds: Double
  /// Normalized 0…1 peak bins along the asset (may be empty).
  var waveformPeaksNormalized: [Float]
  /// When > 0, release snap quantizes the playhead to this grid (frame step).
  var snapToFrameQuantizationSeconds: Double
  var onSeek: (Double) -> Void

  var body: some View {
    let duration = max(0.001, durationSeconds)

    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geo in
        let w = max(1, geo.size.width)

        ZStack(alignment: .leading) {
          if !waveformPeaksNormalized.isEmpty {
            Canvas { ctx, size in
              let n = waveformPeaksNormalized.count
              guard n > 0 else { return }
              let midY = size.height * 0.55
              let amp = size.height * 0.45
              for i in 0 ..< n {
                let u0 = Double(i) / Double(n)
                let u1 = Double(i + 1) / Double(n)
                let x0 = CGFloat(u0) * size.width
                let x1 = CGFloat(u1) * size.width
                let h = CGFloat(waveformPeaksNormalized[i]) * amp
                let r = CGRect(x: x0, y: midY - h, width: max(1, x1 - x0), height: max(1, h * 2))
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(Color.secondary.opacity(0.35)))
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
          }

          Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 10)

          let trimX0 = CGFloat(sourceStartSeconds / duration) * w
          let selectionW = CGFloat((selectionEndSeconds - sourceStartSeconds) / duration) * w
          Capsule().fill(Color.accentColor.opacity(0.38)).frame(width: max(0, selectionW), height: 10).offset(x: trimX0)

          let px = CGFloat(playheadSeconds / duration) * w
          Rectangle()
            .fill(Color.primary.opacity(0.92))
            .frame(width: 2, height: 18)
            .offset(x: max(0, min(w - 2, px - 1)))
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let ratio = max(0, min(1, value.location.x / w))
              onSeek(ratio * durationSeconds)
            }
            .onEnded { value in
              let ratio = max(0, min(1, value.location.x / w))
              var t = ratio * durationSeconds
              let q = snapToFrameQuantizationSeconds
              if q > 1e-12 {
                t = max(0, min(durationSeconds, (t / q).rounded() * q))
              }
              onSeek(t)
            }
        )
      }
      .frame(height: 26)

      HStack {
        Text(sourceStartSeconds, format: .number.precision(.fractionLength(2)))
        Spacer()
        Text(languageStore.localizedFormat("選択幅: %.2f秒", max(0, selectionEndSeconds - sourceStartSeconds)))
          .foregroundStyle(.secondary)
        Spacer()
        Text(selectionEndSeconds, format: .number.precision(.fractionLength(2)))
      }
      .font(.caption)

      HStack {
        Text("再生ヘッド")
          .foregroundStyle(.secondary)
        Text(playheadSeconds, format: .number.precision(.fractionLength(2)))
          .monospacedDigit()
        Text("ルーラーをドラッグ。離すとフレームグリッドにスナップします。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ZoomTrack: View {
  enum DragMode: Equatable {
    case move
    case resizeLeading
    case resizeTrailing
  }

  var durationSeconds: Double
  var sourceStartSeconds: Double
  var selectionEndSeconds: Double
  var keyframes: [RecordingProject.ZoomKeyframe]
  var selectedID: RecordingProject.ZoomKeyframe.ID?
  var onSelect: (RecordingProject.ZoomKeyframe.ID?) -> Void
  /// Live preview while dragging (`persist: false` updates at call site).
  var onLiveFrames: ([RecordingProject.ZoomKeyframe]) -> Void
  var onGestureBegan: () -> Void
  var onGestureEnded: () -> Void

  var body: some View {
    GeometryReader { geo in
      let w = max(1, geo.size.width)
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 10)
          .fill(.quaternary)

        // Trim window overlay
        let trimX0 = x(for: sourceStartSeconds, width: w)
        let selectionX1 = x(for: selectionEndSeconds, width: w)
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.accentColor.opacity(0.10))
          .frame(width: max(0, selectionX1 - trimX0))
          .offset(x: trimX0)

        ForEach(keyframes) { kf in
          ZoomKeyframeBlock(
            kf: kf,
            isSelected: kf.id == selectedID,
            width: w,
            durationSeconds: durationSeconds,
            onTap: { onSelect(kf.id) },
            onDragBegan: onGestureBegan,
            onDragEnded: onGestureEnded,
            onDrag: { mode, deltaSeconds in
              applyDelta(id: kf.id, mode: mode, deltaSeconds: deltaSeconds)
            }
          )
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onSelect(nil)
      }
    }
  }

  private func applyDelta(id: RecordingProject.ZoomKeyframe.ID, mode: DragMode, deltaSeconds: Double) {
    guard durationSeconds > 0 else { return }
    var frames = keyframes
    guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }

    let minLen: Double = ReviewTrimUIConstants.minZoomSeconds
    let duration = durationSeconds

    var start = frames[idx].startSeconds
    var end = frames[idx].endSeconds

    switch mode {
    case .move:
      let len = max(minLen, end - start)
      start += deltaSeconds
      end = start + len
    case .resizeLeading:
      start += deltaSeconds
    case .resizeTrailing:
      end += deltaSeconds
    }

    if end - start < minLen {
      switch mode {
      case .resizeTrailing:
        end = start + minLen
      case .resizeLeading, .move:
        start = end - minLen
      }
    }

    start = max(0, min(duration - minLen, start))
    end = max(start + minLen, min(duration, end))

    frames[idx].startSeconds = start
    frames[idx].endSeconds = end
    onLiveFrames(frames)
  }

  private func x(for seconds: Double, width: CGFloat) -> CGFloat {
    guard durationSeconds > 0 else { return 0 }
    let t = max(0, min(1, seconds / durationSeconds))
    return width * CGFloat(t)
  }
}

private struct CursorHighlightTrack: View {
  enum DragMode: Equatable {
    case move
    case resizeLeading
    case resizeTrailing
  }

  var durationSeconds: Double
  var sourceStartSeconds: Double
  var selectionEndSeconds: Double
  var regions: [RecordingProject.CursorHighlightRegion]
  var selectedID: RecordingProject.CursorHighlightRegion.ID?
  var onSelect: (RecordingProject.CursorHighlightRegion.ID?) -> Void
  var onLiveRegions: ([RecordingProject.CursorHighlightRegion]) -> Void
  var onGestureBegan: () -> Void
  var onGestureEnded: () -> Void

  var body: some View {
    GeometryReader { geo in
      let w = max(1, geo.size.width)
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 10)
          .fill(.quaternary)

        let trimX0 = x(for: sourceStartSeconds, width: w)
        let selectionX1 = x(for: selectionEndSeconds, width: w)
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.accentColor.opacity(0.10))
          .frame(width: max(0, selectionX1 - trimX0))
          .offset(x: trimX0)

        ForEach(regions) { r in
          HighlightRegionBlock(
            region: r,
            isSelected: r.id == selectedID,
            width: w,
            durationSeconds: durationSeconds,
            onTap: { onSelect(r.id) },
            onDragBegan: onGestureBegan,
            onDragEnded: onGestureEnded,
            onDrag: { mode, deltaSeconds in
              applyDelta(id: r.id, mode: mode, deltaSeconds: deltaSeconds)
            }
          )
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onSelect(nil)
      }
    }
  }

  private func applyDelta(id: RecordingProject.CursorHighlightRegion.ID, mode: DragMode, deltaSeconds: Double) {
    guard durationSeconds > 0 else { return }
    var items = regions
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }

    let minLen: Double = ReviewTrimUIConstants.minHighlightSeconds
    let duration = durationSeconds

    var start = items[idx].startSeconds
    var end = items[idx].endSeconds

    switch mode {
    case .move:
      let len = max(minLen, end - start)
      start += deltaSeconds
      end = start + len
    case .resizeLeading:
      start += deltaSeconds
    case .resizeTrailing:
      end += deltaSeconds
    }

    if end - start < minLen {
      switch mode {
      case .resizeTrailing:
        end = start + minLen
      case .resizeLeading, .move:
        start = end - minLen
      }
    }

    start = max(0, min(duration - minLen, start))
    end = max(start + minLen, min(duration, end))

    items[idx].startSeconds = start
    items[idx].endSeconds = end
    onLiveRegions(items)
  }

  private func x(for seconds: Double, width: CGFloat) -> CGFloat {
    guard durationSeconds > 0 else { return 0 }
    let t = max(0, min(1, seconds / durationSeconds))
    return width * CGFloat(t)
  }
}

private struct HighlightRegionBlock: View {
  var region: RecordingProject.CursorHighlightRegion
  var isSelected: Bool
  var width: CGFloat
  var durationSeconds: Double
  var onTap: () -> Void
  var onDragBegan: () -> Void
  var onDragEnded: () -> Void
  var onDrag: (CursorHighlightTrack.DragMode, Double) -> Void

  @State private var lastTranslationWidth: CGFloat = 0

  var body: some View {
    let x0 = x(for: region.startSeconds)
    let x1 = x(for: region.endSeconds)
    let blockW = max(12, x1 - x0)

    return ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(isSelected ? Color.orange.opacity(0.75) : Color.orange.opacity(0.42))
      HStack(spacing: 0) {
        DragHandle()
          .frame(width: ReviewTrimUIConstants.handleWidth)
          .highPriorityGesture(dragGesture(mode: .resizeLeading))
        Spacer(minLength: 0)
        DragHandle()
          .frame(width: ReviewTrimUIConstants.handleWidth)
          .highPriorityGesture(dragGesture(mode: .resizeTrailing))
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 2)
    }
    .frame(width: blockW)
    .offset(x: x0)
    .onTapGesture { onTap() }
    .gesture(dragGesture(mode: .move))
    .accessibilityLabel("Cursor highlight region")
  }

  private func x(for seconds: Double) -> CGFloat {
    guard durationSeconds > 0 else { return 0 }
    let t = max(0, min(1, seconds / durationSeconds))
    return width * CGFloat(t)
  }

  private func dragGesture(mode: CursorHighlightTrack.DragMode) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        guard durationSeconds > 0 else { return }
        if lastTranslationWidth == 0 {
          onDragBegan()
        }
        let tw = value.translation.width
        let incr = Double(tw - lastTranslationWidth) / max(1, width) * durationSeconds
        lastTranslationWidth = tw
        onDrag(mode, incr)
      }
      .onEnded { _ in
        lastTranslationWidth = 0
        onDragEnded()
      }
  }
}

private struct ZoomKeyframeBlock: View {
  var kf: RecordingProject.ZoomKeyframe
  var isSelected: Bool
  var width: CGFloat
  var durationSeconds: Double
  var onTap: () -> Void
  var onDragBegan: () -> Void
  var onDragEnded: () -> Void
  var onDrag: (ZoomTrack.DragMode, Double) -> Void

  @State private var lastTranslationWidth: CGFloat = 0

  var body: some View {
    let x0 = x(for: kf.startSeconds)
    let x1 = x(for: kf.endSeconds)
    let blockW = max(12, x1 - x0)

    return ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(isSelected ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.45))
      HStack(spacing: 0) {
        DragHandle()
          .frame(width: 10)
          .highPriorityGesture(dragGesture(mode: .resizeLeading))
        Spacer(minLength: 0)
        DragHandle()
          .frame(width: 10)
          .highPriorityGesture(dragGesture(mode: .resizeTrailing))
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 2)
    }
    .frame(width: blockW)
    .offset(x: x0)
    .onTapGesture { onTap() }
    .gesture(dragGesture(mode: .move))
    .accessibilityLabel("ズームキーフレーム")
  }

  private func x(for seconds: Double) -> CGFloat {
    guard durationSeconds > 0 else { return 0 }
    let t = max(0, min(1, seconds / durationSeconds))
    return width * CGFloat(t)
  }

  private func dragGesture(mode: ZoomTrack.DragMode) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        guard durationSeconds > 0 else { return }
        if lastTranslationWidth == 0 {
          onDragBegan()
        }
        let tw = value.translation.width
        let incr = Double(tw - lastTranslationWidth) / max(1, width) * durationSeconds
        lastTranslationWidth = tw
        onDrag(mode, incr)
      }
      .onEnded { _ in
        lastTranslationWidth = 0
        onDragEnded()
      }
  }
}

private struct DragHandle: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(.white.opacity(0.65))
      .frame(maxHeight: 28)
      .padding(.vertical, 8)
  }
}

private final class ReviewTrimPlaybackLoopCoordinator: @unchecked Sendable {
  private weak var observedPlayer: AVPlayer?
  private var periodicToken: Any?
  private var endPlaybackObserver: NSObjectProtocol?

  private var loopEnabled = false
  private var trimStart: Double = 0
  private var selectionEnd: Double = 0

  func update(
    player: AVPlayer?,
    loopEnabled: Bool,
    sourceStartSeconds: Double,
    selectionEndSeconds: Double,
    assetDurationSeconds: Double
  ) {
    trimStart = sourceStartSeconds
    selectionEnd = selectionEndSeconds
    self.loopEnabled = loopEnabled

    stop(resetFlags: false)

    guard loopEnabled, let player, assetDurationSeconds > 0 else { return }
    guard selectionEndSeconds - sourceStartSeconds > ReviewTrimUIConstants.minTrimWindowSeconds else { return }

    observedPlayer = player

    let interval = CMTime(
      seconds: ReviewTrimUIConstants.playbackLoopPollSeconds,
      preferredTimescale: 600
    )

    periodicToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
      guard let self, let player, self.loopEnabled else { return }
      let epsilon = ReviewTrimUIConstants.playbackLoopEndEpsilonSeconds
      guard time.seconds >= max(0, self.selectionEnd - epsilon) else { return }

      player.seek(
        to: CMTime(seconds: self.trimStart, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      ) { _ in player.play() }
    }

    if let item = player.currentItem {
      endPlaybackObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self, weak player] _ in
        guard let self, let player, self.loopEnabled else { return }

        player.seek(
          to: CMTime(seconds: self.trimStart, preferredTimescale: 600),
          toleranceBefore: .zero,
          toleranceAfter: .zero
        ) { _ in player.play() }
      }
    }
  }

  /// Use `resetFlags:false` inside `update` so selection / loop bookkeeping is retained while observers are recreated.
  func stop(resetFlags: Bool = true) {
    if let p = observedPlayer, let observation = periodicToken {
      p.removeTimeObserver(observation)
    }
    periodicToken = nil
    observedPlayer = nil

    if let endPlaybackObserver {
      NotificationCenter.default.removeObserver(endPlaybackObserver)
      self.endPlaybackObserver = nil
    }

    if resetFlags {
      loopEnabled = false
    }
  }
}
