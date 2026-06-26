import AppKit
import AVFoundation
import SwiftUI

struct EditorTimelineView: View {
  var project: RecordingProject
  var durationSeconds: Double
  var sourceDurationSeconds: Double
  var currentSeconds: Double
  var isPlaying: Bool
  @Binding var clipStartSeconds: Double
  @Binding var clipEndSeconds: Double
  @Binding var selectedClipID: UUID?
  @Binding var selectedEffect: EditorTimelineEffectSelection?
  var usesStandaloneChrome: Bool = true
  var onSeek: (Double, (@MainActor @Sendable () -> Void)?) -> Void
  var onTogglePlayback: () -> Void
  var onSeekBy: (Double) -> Void
  var onTrimDragBegan: () -> Void
  var onTrimDragEnded: () -> Void
  var onTrimCommit: (@escaping @MainActor @Sendable () -> Void) -> Void
  var onUndo: () -> Void
  var onRedo: () -> Void
  var onDeleteClip: () -> Void
  var onDeleteEffect: () -> Void
  var onSetClipSpeed: (Double) -> Void
  var onSetTrimInAtPlayhead: () -> Void
  var onSetTrimOutAtPlayhead: () -> Void
  var onPlayheadDragBegan: () -> Void
  var onPlayheadDragEnded: () -> Void
  var onMoveClip: (UUID, Int) -> Void
  var onSelectEffect: (EditorTimelineEffectSelection) -> Void
  var onPreviewZoomEffectRange: (UUID, Double, Double, Double, Double) -> Void
  var onEndPreviewZoomEffectRange: () -> Void
  var onCommitZoomEffectRange: (UUID, Double, Double, Double, Double) -> Void
  var onCommitCaptionEffectRange: (UUID, Double, Double) -> Void
  var onCommitMaskEffectRange: (UUID, Double, Double) -> Void
  var onCommitCameraEffectRange: (UUID, Double, Double) -> Void
  var onCommitAudioEffectRange: (UUID, Double, Double) -> Void
  var onCommitUnifiedAudioEffectRange: (Double, Double) -> Void
  @Environment(AppLanguageStore.self) private var languageStore

  @State private var timelineZoomScale: Double = TimelineViewport.minZoomScale
  @State private var timelineSnapEnabled = true
  @State private var leadingDragBaseline: Double?
  @State private var trailingDragBaseline: Double?
  @State private var liveTrimStartSeconds: Double = 0
  @State private var liveTrimEndSeconds: Double = 0
  @State private var isDraggingTrim = false
  @State private var lastTrimSeekDispatchUptime: TimeInterval = 0
  @State private var lastTrimSeekSeconds: Double?
  @State private var isHoveringLeadingTrim = false
  @State private var isHoveringTrailingTrim = false
  @State private var hidesSwiftUITrimHandlesDuringLiveDrag = false
  @State private var hidesSwiftUIPlayheadDuringTrimDrag = false
  @State private var trimInteractionToken = UUID()
  @State private var isFullRecordingSelected = false
  @State private var timelineScrollState = TimelineScrollState()
  @State private var timelineSnapFeedback: TimelineSnapFeedback?
  @State private var timelineWaveformState: TimelineWaveformModel.State = .empty
  @State private var timelineWaveformRoleData: [(role: RecordingProject.AudioTrackSettings.Role, bins: [Float])] = []
  @State private var draggingClipID: UUID?
  @State private var pendingClipDropIndex: Int?
  @State private var effectRangeEditSession: TimelineEffectRangeEditSession?
  @State private var hidesSwiftUIEffectDuringLiveDrag = false
  @State private var liveMediaTrimStartSeconds: Double = 0
  @State private var liveMediaTrimEndSeconds: Double = 0
  @State private var isDraggingMediaTrim = false
  @State private var mediaTrimSegmentSelection: EditorTimelineEffectSelection?
  @State private var hidesSwiftUIMediaTrimHandlesDuringLiveDrag = false
  @State private var isHoveringMediaLeadingTrim = false
  @State private var isHoveringMediaTrailingTrim = false
  @State private var mediaTrimInteractionToken = UUID()

  private var singleClip: RecordingProject.TimelineModel.Clip? {
    project.timeline.singleEditableClip
  }

  private var primaryAudioWaveformBins: [Float] {
    timelineWaveformRoleData.first?.bins ?? []
  }

  private var unifiedAudioLaneSegment: EditorTimelineEffectSegment? {
    let segments = audioEffectSegments
    guard let anchor = segments.first else { return nil }
    let mergedStart = segments.map(\.startSeconds).min() ?? anchor.startSeconds
    let mergedEnd = segments.map(\.endSeconds).max() ?? anchor.endSeconds
    return EditorTimelineEffectSegment(
      id: "audio-unified-\(anchor.id)",
      startSeconds: mergedStart,
      endSeconds: mergedEnd,
      kind: .audio,
      selection: anchor.selection
    )
  }

  private func croppedWaveformBins(forMediaStart start: Double, end: Double) -> [Float] {
    let bins = primaryAudioWaveformBins
    guard !bins.isEmpty, end > start else { return bins }
    let duration = max(durationSeconds, sourceDurationSeconds, end, 1e-6)
    let count = bins.count
    let startIndex = min(count - 1, max(0, Int((start / duration) * Double(count))))
    let endIndex = min(count, max(startIndex + 1, Int(ceil((end / duration) * Double(count)))))
    return Array(bins[startIndex..<endIndex])
  }

  private var dynamicTimelineTrackHeight: CGFloat {
    EditorLayout.timelineRulerHeight
      + EditorLayout.timelineClipLaneHeight
      + (includesCameraLane ? EditorLayout.timelineClipLaneHeight + EditorLayout.timelineLaneGap : 0)
      + EditorLayout.timelineClipLaneHeight
      + EditorLayout.timelineEffectLaneHeight
      + dynamicMaskLaneHeight
      + EditorLayout.timelineLaneGap * (includesCameraLane ? 5 : 4)
  }

  private var lanesHeightBeforeClipLane: CGFloat {
    EditorLayout.timelineRulerHeight
      + EditorLayout.timelineLaneGap
      + EditorLayout.timelineClipLaneHeight
      + (includesCameraLane ? EditorLayout.timelineLaneGap + EditorLayout.timelineClipLaneHeight : 0)
      + EditorLayout.timelineLaneGap
  }

  /// 再生ヘッドのゴースト掴みはルーラーのみ。音声・カメラ・クリップのトリム面にイベントを通す。
  private var playheadGhostTrackMaxY: CGFloat {
    EditorLayout.timelineRulerHeight + EditorLayout.timelineLaneGap
  }

  private var includesBackgroundMusicWaveform: Bool {
    let settings = project.audioTrackSettings
    return settings.backgroundMusic.isEnabled && settings.backgroundMusicURL != nil
  }

  private var maskEffectSegments: [EditorTimelineEffectSegment] {
    EditorTimelineEffectSegment.segments(project: project, duration: durationSeconds)
      .filter { $0.kind == .mask }
  }

  private var maskLaneRowCount: Int {
    TimelineEffectRowLayout.displayRowCount(
      for: maskEffectSegments,
      maxRows: EditorLayout.timelineMaskLaneMaxRows
    )
  }

  private var maskLaneDetailText: String? {
    let count = maskEffectSegments.count
    guard count > 0 else { return nil }
    let rows = maskLaneRowCount
    switch (count > 1, rows > 1) {
    case (true, true):
      return languageStore.localizedFormat("%d masks · %d rows", count, rows)
    case (true, false):
      return languageStore.localizedFormat("%d masks", count)
    case (false, true):
      return languageStore.localizedFormat("%d rows", rows)
    case (false, false):
      return nil
    }
  }

  private var dynamicMaskLaneHeight: CGFloat {
    EditorLayout.timelineMaskLaneHeight(rowCount: maskLaneRowCount)
  }

  private var includesCameraLane: Bool {
    project.secondaryRecording != nil
  }

  private var mediaTimelineSegments: [EditorTimelineEffectSegment] {
    EditorTimelineEffectSegment.segments(project: project, duration: durationSeconds)
  }

  private var cameraEffectSegments: [EditorTimelineEffectSegment] {
    mediaTimelineSegments.filter { $0.kind == .camera }
  }

  private var audioEffectSegments: [EditorTimelineEffectSegment] {
    mediaTimelineSegments.filter { $0.kind == .audio }
  }

  private var dynamicTimelineGridHeight: CGFloat {
    EditorLayout.timelineControlHeight + EditorLayout.timelineControlBottomGap + dynamicTimelineTrackHeight
  }

  private var displayMode: RecordingProject.TimelineModel.ClipDisplayMode {
    singleClip == nil ? .timeline : .singleSource
  }

  private var isDraggingTrimBoundary: Bool {
    isDraggingTrim || isDraggingMediaTrim || leadingDragBaseline != nil || trailingDragBaseline != nil
  }

  private var isDraggingZoomMotion: Bool {
    effectRangeEditSession?.live.kind == .zoom
  }

  private var displayedTrimStartSeconds: Double {
    isDraggingTrim ? liveTrimStartSeconds : clipStartSeconds
  }

  private var displayedTrimEndSeconds: Double {
    isDraggingTrim ? liveTrimEndSeconds : clipEndSeconds
  }

  private var currentTimelineSeconds: Double {
    min(max(0, displaySecondsForCurrentPreviewSecond(currentSeconds)), max(0, durationSeconds))
  }

  private var currentPreviewSeconds: Double {
    let previewDuration = singleClip?.durationSeconds ?? durationSeconds
    return min(max(0, currentSeconds), max(0, previewDuration))
  }

  private var headerDurationSeconds: Double {
    singleClip?.durationSeconds ?? durationSeconds
  }

  private var timelineHeaderTimeText: String {
    languageStore.localizedFormat(
      "Preview %@ / %@",
      editorFormatTime(singleClip != nil ? currentPreviewSeconds : currentTimelineSeconds, fractional: true),
      editorFormatTime(headerDurationSeconds, fractional: true)
    )
  }

  private var audioRoleStatuses: [TimelineAudioRoleStatus] {
    TimelineAudioRoleStatus.statuses(for: project.audioTrackSettings)
  }

  private var audioLayerDetailText: String {
    audioRoleStatuses
      .map { localizedAudioRoleValue($0) }
      .joined(separator: " / ")
  }

  private var canUseKeyboardTrim: Bool {
    if let selectedEffect, isMediaTimelineSelection(selectedEffect) {
      return true
    }
    return singleClip != nil || isFullRecordingSelected
  }

  private func isMediaTimelineSelection(_ selection: EditorTimelineEffectSelection) -> Bool {
    switch selection {
    case .audio, .camera:
      return true
    case .zoom, .caption, .mask:
      return false
    }
  }

  private var canEditEffectRanges: Bool {
    if let singleClip {
      return abs(project.timeline.speedRate(for: singleClip) - RecordingProject.TimelineEditing.defaultSpeedRate) < 1e-9
    }
    return !project.timeline.hasActiveClips
  }

  private func canEditMediaEffectRange(_ kind: EditorTimelineEffectSegment.Kind) -> Bool {
    switch kind {
    case .camera:
      return sourceDurationSeconds >= RecordingProject.TimelineMediaEditing.minCameraSpanSeconds
    case .audio:
      return sourceDurationSeconds >= RecordingProject.TimelineMediaEditing.minAudioSpanSeconds
    case .zoom, .caption, .mask:
      return canEditEffectRanges
    }
  }

  private var timelineCommandContext: EditorTimelineCommandContext {
    EditorTimelineCommandContext(
      canDeleteSelection: selectedClipID != nil || selectedEffect != nil,
      canUseSingleClipTrim: canUseKeyboardTrim,
      snapEnabled: timelineSnapEnabled,
      zoomDescription: "\(Int(timelineZoomScale * 100))%",
      togglePlayback: onTogglePlayback,
      deleteSelection: deleteCurrentSelection,
      zoomIn: { setTimelineZoomScale(timelineZoomScale * 1.5) },
      zoomOut: { setTimelineZoomScale(timelineZoomScale / 1.5) },
      zoomToFit: { setTimelineZoomScale(TimelineViewport.minZoomScale) },
      toggleSnap: { timelineSnapEnabled.toggle() },
      setInAtPlayhead: onSetTrimInAtPlayhead,
      setOutAtPlayhead: onSetTrimOutAtPlayhead,
      selectNext: selectNextTimelineItem,
      selectPrevious: selectPreviousTimelineItem,
      clearSelection: clearTimelineSelection
    )
  }

  private func activeTimelineWidth(for contentWidth: CGFloat) -> CGFloat {
    max(1, contentWidth - EditorLayout.timelineLaneInsetX * 2)
  }

  private func timelineViewport(duration: Double, visibleWidth: CGFloat) -> TimelineViewport {
    TimelineViewport(durationSeconds: duration, visibleWidth: visibleWidth, zoomScale: timelineZoomScale)
  }

  private func timelineContentX(
    _ seconds: Double,
    duration: Double,
    activeWidth: CGFloat,
    itemWidth: CGFloat = 0
  ) -> CGFloat {
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: duration,
      previewDurationSeconds: duration,
      timelineDurationSeconds: duration,
      width: activeWidth
    )
    if itemWidth > 0 {
      return EditorLayout.timelineLaneInsetX + space.frameX(for: seconds, itemWidth: itemWidth)
    }
    return EditorLayout.timelineLaneInsetX + space.timelineX(for: seconds)
  }

  private func displaySeconds(forTimelineContentX x: CGFloat, duration: Double, activeWidth: CGFloat) -> Double {
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: duration,
      previewDurationSeconds: duration,
      timelineDurationSeconds: duration,
      width: activeWidth
    )
    return space.timelineSeconds(forX: x - EditorLayout.timelineLaneInsetX)
  }

  private func snapThresholdSeconds(duration: Double, activeWidth: CGFloat) -> Double {
    let secondsPerPixel = max(0, duration) / Double(max(activeWidth, 1))
    return max(0.03, secondsPerPixel * 6)
  }

  private func snappedDisplayResult(_ seconds: Double, duration: Double, activeWidth: CGFloat) -> TimelineSnapResult {
    let policy = TimelineSnapPolicy(
      enabled: timelineSnapEnabled,
      targets: timelineSnapTargets(duration: duration),
      thresholdSeconds: snapThresholdSeconds(duration: duration, activeWidth: activeWidth),
      validRange: 0...max(0, duration)
    )
    return policy.snappedResult(for: seconds)
  }

  private func seekDisplaySeconds(
    _ seconds: Double,
    duration: Double,
    activeWidth: CGFloat,
    showsSnapFeedback: Bool = true
  ) {
    let result = snappedDisplayResult(seconds, duration: duration, activeWidth: activeWidth)
    if showsSnapFeedback {
      timelineSnapFeedback = result.target.map {
        TimelineSnapFeedback(
          seconds: result.seconds,
          label: $0.label.isEmpty ? editorFormatTime(result.seconds, fractional: true) : $0.label
        )
      }
    } else {
      timelineSnapFeedback = nil
    }
    onSeek(seekSeconds(forDisplaySeconds: result.seconds), nil)
  }

  private func seekSeconds(forDisplaySeconds seconds: Double) -> Double {
    if let singleClip {
      return project.timeline.previewSeconds(forSourceSeconds: seconds, in: singleClip)
    }
    if project.timeline.hasActiveClips {
      return seconds
    }
    return project.timeline.sourceSeconds(forTimelineSeconds: seconds) ?? seconds
  }

  private func seekPlayheadAccessibility(toDisplaySeconds seconds: Double, duration: Double) {
    let clampedDisplaySeconds = min(max(0, seconds), max(0, duration))
    onSeek(seekSeconds(forDisplaySeconds: clampedDisplaySeconds), nil)
  }

  private func displaySecondsForCurrentPreviewSecond(_ previewSeconds: Double) -> Double {
    if let singleClip {
      return project.timeline.sourceSeconds(forPreviewSeconds: previewSeconds, in: singleClip)
    }
    if project.timeline.hasActiveClips {
      return previewSeconds
    }
    return project.timeline.timelineSeconds(forSourceSeconds: previewSeconds).first ?? previewSeconds
  }

  private func timelineSnapTargets(duration: Double) -> [TimelineSnapTarget] {
    var targets: [TimelineSnapTarget] = [
      TimelineSnapTarget(seconds: 0, label: "Start"),
      TimelineSnapTarget(seconds: max(0, duration), label: "End"),
      TimelineSnapTarget(seconds: currentTimelineSeconds, label: "Playhead"),
      TimelineSnapTarget(seconds: displayedTrimStartSeconds, label: "In"),
      TimelineSnapTarget(seconds: displayedTrimEndSeconds, label: "Out"),
    ]

    let clips = project.timeline.activeClips
    if let singleClip {
      let range = liveSingleClipDisplayRange(for: singleClip)
      targets.append(contentsOf: [
        TimelineSnapTarget(seconds: range.startSeconds, label: "Clip In"),
        TimelineSnapTarget(seconds: range.endSeconds, label: "Clip Out"),
      ])
    } else {
      for clip in clips {
        let range = project.timeline.displayRange(for: clip, mode: .timeline)
        targets.append(contentsOf: [
          TimelineSnapTarget(seconds: range.startSeconds, label: "Clip In"),
          TimelineSnapTarget(seconds: range.endSeconds, label: "Clip Out"),
        ])
      }
    }

    for segment in EditorTimelineEffectSegment.segments(project: project, duration: duration) {
      let label = effectSegmentKindLabel(segment.kind)
      targets.append(contentsOf: [
        TimelineSnapTarget(seconds: segment.startSeconds, label: "\(label) In"),
        TimelineSnapTarget(seconds: segment.endSeconds, label: "\(label) Out"),
      ])
    }

    var seen: [TimelineSnapTarget] = []
    for target in targets
      .map({ TimelineSnapTarget(seconds: min(max($0.seconds, 0), max(0, duration)), label: $0.label) })
      .sorted(by: { $0.seconds < $1.seconds })
    {
      if !seen.contains(where: { abs($0.seconds - target.seconds) < 1e-6 }) {
        seen.append(target)
      }
    }
    return seen
  }

  private func playheadGhostSnapTargets(duration: Double) -> [TimelineSnapTarget] {
    var targets: [TimelineSnapTarget] = [
      TimelineSnapTarget(seconds: 0, label: "Start"),
      TimelineSnapTarget(seconds: max(0, duration), label: "End"),
    ]

    let clips = project.timeline.activeClips
    if let singleClip {
      let range = liveSingleClipDisplayRange(for: singleClip)
      targets.append(contentsOf: [
        TimelineSnapTarget(seconds: range.startSeconds, label: "Clip In"),
        TimelineSnapTarget(seconds: range.endSeconds, label: "Clip Out"),
      ])
    } else {
      for clip in clips {
        let range = project.timeline.displayRange(for: clip, mode: .timeline)
        targets.append(contentsOf: [
          TimelineSnapTarget(seconds: range.startSeconds, label: "Clip In"),
          TimelineSnapTarget(seconds: range.endSeconds, label: "Clip Out"),
        ])
      }
    }

    var seen: [TimelineSnapTarget] = []
    for target in targets
      .map({ TimelineSnapTarget(seconds: min(max($0.seconds, 0), max(0, duration)), label: $0.label) })
      .sorted(by: { $0.seconds < $1.seconds })
    {
      if !seen.contains(where: { abs($0.seconds - target.seconds) < 1e-6 }) {
        seen.append(target)
      }
    }
    return seen
  }

  private func liveSingleClipDisplayRange(
    for clip: RecordingProject.TimelineModel.Clip
  ) -> RecordingProject.TimelineModel.ClipDisplayRange {
    let canonical = project.timeline.sourceRange(for: clip)
    let rate = max(project.timeline.speedRate(for: clip), 1e-9)
    let minSourceDuration = RecordingProject.TimelineEditing.minInteractiveClipDurationSeconds * rate
    let assetDuration = max(sourceDurationSeconds, durationSeconds, canonical.endSeconds)

    let currentStart = displayedTrimStartSeconds
    let currentEnd = displayedTrimEndSeconds
    let proposedStart = currentEnd > currentStart
      ? currentStart
      : canonical.startSeconds
    let proposedEnd = currentEnd > currentStart
      ? currentEnd
      : canonical.endSeconds
    let end = min(assetDuration, max(proposedStart + minSourceDuration, proposedEnd))
    let start = max(0, min(proposedStart, end - minSourceDuration))

    return RecordingProject.TimelineModel.ClipDisplayRange(
      startSeconds: start,
      endSeconds: end
    )
  }

  private func dispatchTrimPreviewSeek(
    _ seconds: Double,
    force: Bool = false,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let capped = max(0, seconds)
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = now - lastTrimSeekDispatchUptime
    let distance = abs(capped - (lastTrimSeekSeconds ?? -Double.infinity))
    guard force
      || elapsed >= EditorLayout.timelineTrimSeekMinInterval
      || distance >= 0.12
    else {
      completion?()
      return
    }

    lastTrimSeekDispatchUptime = now
    lastTrimSeekSeconds = capped
    onSeek(capped, completion)
  }

  private func beginTrimInteraction() -> UUID {
    let token = UUID()
    trimInteractionToken = token
    onTrimDragBegan()
    return token
  }

  private func finishLiveTrimDrag(
    handle: EditorTimelineActiveTrimHandle,
    start: Double,
    end: Double,
    token: UUID,
    completion: @escaping () -> Void
  ) {
    let finalStart = start
    let finalEnd = end
    let targetSeconds: Double
    switch handle {
    case .leading:
      targetSeconds = 0
    case .trailing:
      let previewTime = singleClip.map {
        project.timeline.previewSeconds(forSourceSeconds: finalEnd, in: $0)
      } ?? max(0, finalEnd - finalStart)
      targetSeconds = max(0, previewTime - 0.001)
    }

    var transaction = Transaction()
    transaction.disablesAnimations = true
    transaction.animation = nil
    withTransaction(transaction) {
      clipStartSeconds = finalStart
      clipEndSeconds = finalEnd
      liveTrimStartSeconds = finalStart
      liveTrimEndSeconds = finalEnd
      isDraggingTrim = false
    }
    leadingDragBaseline = nil
    trailingDragBaseline = nil
    onTrimCommit {
      guard token == trimInteractionToken else { return }
      dispatchTrimPreviewSeek(targetSeconds, force: true) {
        guard token == trimInteractionToken else { return }
        onTrimDragEnded()
        completion()
      }
    }
  }

  var body: some View {
    timelineGrid
      .modifier(EditorTimelineChromeModifier(usesStandaloneChrome: usesStandaloneChrome))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .overlay(alignment: .topLeading) {
      timelineKeyboardTrimShortcuts
    }
    .focusedValue(\.editorTimelineCommandContext, timelineCommandContext)
    .onChange(of: durationSeconds) { _, seconds in
      guard !isDraggingTrim else { return }
      if clipEndSeconds <= 0 || clipEndSeconds > seconds {
        clipEndSeconds = max(0, seconds)
      }
    }
    .onAppear {
      liveTrimStartSeconds = clipStartSeconds
      liveTrimEndSeconds = clipEndSeconds
    }
    .onDisappear {
      finishEffectRangeEditSession()
    }
    .onChange(of: clipStartSeconds) { _, value in
      guard !isDraggingTrim else { return }
      liveTrimStartSeconds = value
    }
    .onChange(of: clipEndSeconds) { _, value in
      guard !isDraggingTrim else { return }
      liveTrimEndSeconds = value
    }
    .onChange(of: isPlaying) { _, playing in
      if playing {
        timelineScrollState.followPlayhead = true
        timelineScrollState.isUserScrolling = false
      }
    }
    .onChange(of: canEditEffectRanges) { _, canEdit in
      if !canEdit {
        finishEffectRangeEditSession()
      }
    }
    .onChange(of: selectedEffect) { _, selection in
      if let session = effectRangeEditSession, !session.matches(selection: selection) {
        finishEffectRangeEditSession()
      }
      if selection == nil || mediaTrimSegmentSelection != selection {
        resetMediaTrimDragState()
      }
    }
  }

  private var timelineKeyboardTrimShortcuts: some View {
    VStack {
      Button("", action: onSetTrimInAtPlayhead)
        .keyboardShortcut("[", modifiers: .option)
        .disabled(!canUseKeyboardTrim)
      Button("", action: onSetTrimOutAtPlayhead)
        .keyboardShortcut("]", modifiers: .option)
        .disabled(!canUseKeyboardTrim)
      Button("", action: clearTimelineSelection)
        .keyboardShortcut(.escape, modifiers: [])
      Button("", action: deleteCurrentSelection)
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(selectedClipID == nil && selectedEffect == nil)
      Button("", action: selectPreviousTimelineItem)
        .keyboardShortcut(.leftArrow, modifiers: .shift)
      Button("", action: selectNextTimelineItem)
        .keyboardShortcut(.rightArrow, modifiers: .shift)
    }
    .frame(width: 1, height: 1)
    .opacity(0.001)
    .accessibilityHidden(true)
  }

  private var timelineGrid: some View {
    GeometryReader { geo in
      let contentWidth = max(1, geo.size.width - EditorLayout.timelineLabelWidth - EditorLayout.timelineLabelGap)
      let duration = max(0.001, durationSeconds)
      let viewport = timelineViewport(duration: duration, visibleWidth: contentWidth)

      VStack(alignment: .leading, spacing: EditorLayout.timelineControlBottomGap) {
        timelineControlRow(contentWidth: contentWidth)

        timelineTrack(visibleWidth: contentWidth, viewport: viewport, duration: duration)
      }
      .frame(width: geo.size.width, height: dynamicTimelineGridHeight, alignment: .topLeading)
    }
    .frame(minHeight: dynamicTimelineGridHeight)
  }

  private func timelineControlRow(contentWidth: CGFloat) -> some View {
    HStack(alignment: .top, spacing: EditorLayout.timelineLabelGap) {
      Color.clear
        .frame(width: EditorLayout.timelineLabelWidth, height: EditorLayout.timelineControlHeight)

      timelineHeader
        .frame(width: contentWidth, height: EditorLayout.timelineControlHeight, alignment: .leading)
    }
    .frame(height: EditorLayout.timelineControlHeight, alignment: .topLeading)
  }

  private var timelineHeader: some View {
    ZStack {
      Rectangle()
        .fill(Color.primary.opacity(EditorLayout.timelineHeaderRowOpacity))

      HStack(spacing: EditorLayout.timelineHeaderItemGap) {
        playPauseButton

        Text(timelineHeaderTimeText)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(Color.primary.opacity(0.72))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(minWidth: 148, alignment: .leading)
          .help("プレビューの再生位置")

        timelineHeaderDivider

        timelineHeaderGroup {
          timelineZoomButton("タイムラインを縮小", systemImage: "minus.magnifyingglass") {
            setTimelineZoomScale(timelineZoomScale / 1.5)
          }
          timelineZoomButton("タイムラインを全体表示", systemImage: "arrow.up.left.and.arrow.down.right") {
            setTimelineZoomScale(TimelineViewport.minZoomScale)
          }
          timelineZoomButton("タイムラインを拡大", systemImage: "plus.magnifyingglass") {
            setTimelineZoomScale(timelineZoomScale * 1.5)
          }
          timelineSnapToggle
        }

        Spacer(minLength: EditorLayout.timelineHeaderSideGap)

        timelineHeaderGroup {
          timelineHeaderButton("取り消し", systemImage: "arrow.uturn.backward") {
            onUndo()
          }
          timelineHeaderButton("やり直し", systemImage: "arrow.uturn.forward") {
            onRedo()
          }
        }

        if let selectedClipID,
           project.timeline.activeClips.contains(where: { $0.id == selectedClipID }) {
          timelineHeaderDivider
          timelineHeaderGroup {
            timelineSpeedMenu
            timelineHeaderButton(
              "選択クリップを削除",
              systemImage: "trash",
              destructive: true
            ) {
              onDeleteClip()
            }
          }
        }

        if let selectedEffect {
          timelineHeaderDivider
          timelineHeaderGroup {
            if let effectInfo = selectedEffectTimeRange(selectedEffect) {
              timelineStaticBadge(localizedEffectKind(effectInfo.kind))
            }
            timelineHeaderButton(
              "選択効果を削除",
              systemImage: "trash",
              destructive: true
            ) {
              onDeleteEffect()
            }
          }
        }
      }
      .frame(height: EditorLayout.timelineHeaderContentHeight, alignment: .center)
      .padding(.horizontal, EditorLayout.timelineLaneInsetX)
    }
    .controlSize(.small)
    .frame(height: EditorLayout.timelineControlHeight)
  }

  private var timelineSpeedMenu: some View {
    Menu {
      ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
        Button {
          onSetClipSpeed(rate)
        } label: {
          HStack {
            Text("\(rate, format: .number.precision(.fractionLength(rate == floor(rate) ? 0 : 2)))x")
            if abs(selectedClipSpeedRate - rate) < 0.001 {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      Text(timelineRateText(selectedClipSpeedRate, maxFractionDigits: 1))
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .frame(minWidth: 34, minHeight: EditorLayout.timelineHeaderControlSize)
        .contentShape(RoundedRectangle(cornerRadius: EditorLayout.timelineRowCornerRadius, style: .continuous))
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .help("選択クリップの速度")
    .accessibilityLabel("選択クリップの速度")
  }

  private func timelineZoomButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: EditorLayout.timelineHeaderControlSize, height: EditorLayout.timelineHeaderControlSize)
        .contentShape(RoundedRectangle(cornerRadius: EditorLayout.timelineRowCornerRadius, style: .continuous))
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Color.primary.opacity(0.62))
    .help(title)
    .accessibilityLabel(title)
    .accessibilityValue("\(Int(timelineZoomScale * 100))%")
  }

  private func setTimelineZoomScale(_ rawScale: Double) {
    let nextScale = TimelineViewport.clampedZoomScale(rawScale)
    let visibleWidth = max(timelineScrollState.visibleWidth, 1)
    let nextViewport = TimelineViewport(durationSeconds: max(0.001, durationSeconds), visibleWidth: visibleWidth, zoomScale: nextScale)
    timelineZoomScale = nextScale
    timelineScrollState.contentOffsetX = nextViewport.offsetX(centeredOn: currentTimelineSeconds)
    timelineScrollState.followPlayhead = true
    timelineScrollState.isUserScrolling = false
  }

  private func deleteCurrentSelection() {
    if selectedClipID != nil {
      onDeleteClip()
    } else if selectedEffect != nil {
      onDeleteEffect()
    }
  }

  private func clearTimelineSelection() {
    selectedClipID = nil
    selectedEffect = nil
    isFullRecordingSelected = false
  }

  private func selectNextTimelineItem() {
    let clips = project.timeline.activeClips
    guard !clips.isEmpty else { return }
    if let selectedClipID,
      let index = clips.firstIndex(where: { $0.id == selectedClipID }) {
      self.selectedClipID = clips[min(index + 1, clips.count - 1)].id
    } else {
      selectedClipID = clips.first?.id
    }
    selectedEffect = nil
    isFullRecordingSelected = false
  }

  private func selectPreviousTimelineItem() {
    let clips = project.timeline.activeClips
    guard !clips.isEmpty else { return }
    if let selectedClipID,
      let index = clips.firstIndex(where: { $0.id == selectedClipID }) {
      self.selectedClipID = clips[max(index - 1, 0)].id
    } else {
      selectedClipID = clips.last?.id
    }
    selectedEffect = nil
    isFullRecordingSelected = false
  }

  private var timelineSnapToggle: some View {
    Toggle(isOn: $timelineSnapEnabled) {
      HStack(spacing: 4) {
        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
          .font(.system(size: 10, weight: .semibold))
        Text(languageStore.localized("端合わせ"))
          .font(.system(size: 10, weight: .semibold))
      }
      .padding(.horizontal, 6)
      .frame(height: EditorLayout.timelineHeaderControlSize)
      .contentShape(RoundedRectangle(cornerRadius: EditorLayout.timelineRowCornerRadius, style: .continuous))
    }
    .toggleStyle(.button)
    .buttonStyle(.borderless)
    .foregroundStyle(timelineSnapEnabled ? EditorPalette.brandStrong : Color.primary.opacity(0.44))
    .help(languageStore.localized("端合わせの説明"))
    .accessibilityLabel(languageStore.localized("端合わせ"))
    .accessibilityHint(languageStore.localized("端合わせの説明"))
    .accessibilityValue(timelineSnapEnabled ? "オン" : "オフ")
  }

  private func localizedEffectKind(_ kind: String) -> String {
    languageStore.localized(kind)
  }

  private func selectedEffectTimeRange(_ selection: EditorTimelineEffectSelection) -> (kind: String, start: Double, end: Double)? {
    switch selection {
    case .zoom(let id):
      if let segment = project.zoomSegments.first(where: { $0.id == id }) {
        return ("Zoom", segment.startSeconds, segment.endSeconds)
      }
    case .caption(let id):
      if let c = project.captionTrack.segments.first(where: { $0.id == id }) {
        return ("Caption", c.startSeconds, c.endSeconds)
      }
    case .mask(let id):
      if let m = project.visualMasks.first(where: { $0.id == id }) {
        return ("Mask", m.startSeconds, m.endSeconds)
      }
    case .camera(let id):
      if let camera = project.cameraLayoutSegments.first(where: { $0.id == id }) {
        return (languageStore.localized("Camera"), camera.startSeconds, camera.endSeconds)
      }
    case .audio(let id):
      if let audio = project.audioTimelineSegments.first(where: { $0.id == id }) {
        return (languageStore.localized("Audio"), audio.startSeconds, audio.endSeconds)
      }
    }
    return nil
  }

  private var selectedClipSpeedRate: Double {
    guard let selectedClipID,
      let clip = project.timeline.activeClips.first(where: { $0.id == selectedClipID })
    else {
      return RecordingProject.TimelineEditing.defaultSpeedRate
    }
    return project.timeline.speedRate(
      forTimelineRangeStart: clip.timelineStartSeconds,
      end: clip.timelineStartSeconds + clip.durationSeconds
    )
  }

  private func timelineRateText(_ rate: Double, maxFractionDigits: Int = 2) -> String {
    if abs(rate - rate.rounded()) < 1e-9 {
      return String(format: "%.0fx", rate)
    }
    if maxFractionDigits <= 1 {
      return String(format: "%.1fx", rate)
    }
    return String(format: "%.2fx", rate)
  }

  private var timelineHeaderDivider: some View {
    Rectangle()
      .fill(Color.primary.opacity(EditorLayout.timelineHeaderDividerOpacity))
      .frame(
        width: EditorLayout.timelineHeaderDividerWidth,
        height: EditorLayout.timelineHeaderDividerHeight
      )
      .allowsHitTesting(false)
  }

  private func timelineTrack(visibleWidth: CGFloat, viewport: TimelineViewport, duration: Double) -> some View {
    let playheadX = timelineContentX(
      currentTimelineSeconds,
      duration: duration,
      activeWidth: viewport.activeContentWidth
    )
    let playheadGhostTopInset = EditorLayout.timelinePlayheadGhostLabelHeight
    // ゴーストサーフェス座標でのクリップレーン上端。ここから下（クリップ／エフェクト帯）では
    // 再生ヘッドの全高さ掴みを無効化し、トリムハンドル等にイベントを通す。
    let playheadGhostClipLaneMinY = playheadGhostTopInset + playheadGhostTrackMaxY
    let shouldFollowPlayhead = isPlaying
      && timelineScrollState.followPlayhead
      && !timelineScrollState.isUserScrolling
      && !isDraggingTrimBoundary
      && !isDraggingZoomMotion
      && draggingClipID == nil
    let targetOffsetX = shouldFollowPlayhead ? viewport.offsetX(centeredOn: currentTimelineSeconds) : nil

    return HStack(alignment: .top, spacing: EditorLayout.timelineLabelGap) {
      timelineLayerLabels
        .frame(width: EditorLayout.timelineLabelWidth, height: dynamicTimelineTrackHeight)

      TimelineScrollContainer(
        scrollState: $timelineScrollState,
        targetOffsetX: targetOffsetX,
        contentWidth: viewport.contentWidth,
        visibleWidth: visibleWidth,
        contentHeight: dynamicTimelineTrackHeight
      ) {
        ZStack(alignment: .topLeading) {
          timelineTrackContent(
            width: viewport.contentWidth,
            activeWidth: viewport.activeContentWidth,
            duration: duration
          )
          .frame(width: viewport.contentWidth, height: dynamicTimelineTrackHeight, alignment: .topLeading)

          if !hidesSwiftUIPlayheadDuringTrimDrag && !isDraggingZoomMotion && !isDraggingMediaTrim {
            timelinePlayhead(x: playheadX, laneHeight: dynamicTimelineTrackHeight, width: viewport.contentWidth, duration: duration)
              .zIndex(6)
            EditorTimelinePlayheadGhostSurface(
              currentDisplaySeconds: currentTimelineSeconds,
              durationSeconds: duration,
              contentWidth: viewport.contentWidth,
              activeWidth: viewport.activeContentWidth,
              snapEnabled: timelineSnapEnabled,
              snapTargets: playheadGhostSnapTargets(duration: duration),
              snapThresholdSeconds: snapThresholdSeconds(duration: duration, activeWidth: viewport.activeContentWidth),
              topHitInsetY: playheadGhostTopInset,
              clipLaneMinY: playheadGhostClipLaneMinY,
              onInteractionBegan: onPlayheadDragBegan,
              onPreview: { displaySeconds in
                onSeek(seekSeconds(forDisplaySeconds: displaySeconds), nil)
              },
              onCommit: { displaySeconds, completion in
                onSeek(seekSeconds(forDisplaySeconds: displaySeconds), completion)
              },
              onInteractionEnded: onPlayheadDragEnded
            )
            // ゴースト面はルーラー帯のみ。音声・カメラ・クリップのトリム NSView にイベントを通す。
            .frame(width: viewport.contentWidth, height: playheadGhostClipLaneMinY)
            .offset(y: -playheadGhostTopInset)
            .zIndex(8)
          }

          if let timelineSnapFeedback {
            snapFeedbackView(
              feedback: timelineSnapFeedback,
              duration: duration,
              activeWidth: viewport.activeContentWidth
            )
            .zIndex(7)
          }
        }
        .frame(width: viewport.contentWidth, height: dynamicTimelineTrackHeight, alignment: .topLeading)
      }
      .frame(width: visibleWidth, height: dynamicTimelineTrackHeight, alignment: .topLeading)
    }
    .frame(height: dynamicTimelineTrackHeight, alignment: .topLeading)
  }

  private struct LiveTrimMetrics {
    var startSeconds: Double
    var endSeconds: Double
    var minSourceDuration: Double
    var assetDuration: Double
  }

  private func liveTrimMetrics(duration: Double) -> LiveTrimMetrics? {
    let activeClips = project.timeline.activeClips
    guard activeClips.count <= 1 else { return nil }

    let singleClip = project.timeline.singleEditableClip
    let singleRange = singleClip.map { liveSingleClipDisplayRange(for: $0) }
    let startSeconds = singleRange?.startSeconds ?? displayedTrimStartSeconds
    let endSeconds = singleRange?.endSeconds ?? displayedTrimEndSeconds
    let rate = max(singleClip.map { project.timeline.speedRate(for: $0) } ?? 1, 1e-9)
    let minSourceDuration = RecordingProject.TimelineEditing.minInteractiveClipDurationSeconds * rate
    let assetDuration = max(sourceDurationSeconds, endSeconds, duration)

    return LiveTrimMetrics(
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      minSourceDuration: minSourceDuration,
      assetDuration: assetDuration
    )
  }

  private func timelineTrackContent(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    VStack(spacing: EditorLayout.timelineLaneGap) {
      timelineRuler(width: width, activeWidth: activeWidth, duration: duration)
        .frame(height: EditorLayout.timelineRulerHeight)

      waveformLane(width: width, activeWidth: activeWidth, duration: duration)
        .frame(height: EditorLayout.timelineClipLaneHeight)

      if includesCameraLane {
        cameraLane(width: width, activeWidth: activeWidth, duration: duration)
          .frame(height: EditorLayout.timelineClipLaneHeight)
      }

      clipLane(width: width, activeWidth: activeWidth, duration: duration)
        .frame(height: EditorLayout.timelineClipLaneHeight)

      motionEffectsLane(width: width, activeWidth: activeWidth, duration: duration)
        .frame(height: EditorLayout.timelineEffectLaneHeight)

      maskEffectsLane(width: width, activeWidth: activeWidth, duration: duration)
        .frame(height: dynamicMaskLaneHeight)
    }
    .frame(width: width, height: dynamicTimelineTrackHeight, alignment: .topLeading)
  }

  private var timelineLayerLabels: some View {
    VStack(spacing: EditorLayout.timelineLaneGap) {
      Color.clear
        .frame(height: EditorLayout.timelineRulerHeight)

      timelineLayerLabel(title: languageStore.localized("音声"), detail: audioLayerDetailText)
        .frame(height: EditorLayout.timelineClipLaneHeight)

      if includesCameraLane {
        timelineLayerLabel(title: languageStore.localized("カメラ"), detail: cameraLayerDetailText)
          .frame(height: EditorLayout.timelineClipLaneHeight)
      }

      timelineLayerLabel(title: languageStore.localized("クリップ"))
        .frame(height: EditorLayout.timelineClipLaneHeight)

      timelineLayerLabel(title: languageStore.localized("ズーム"))
        .frame(height: EditorLayout.timelineEffectLaneHeight)

      timelineLayerLabel(
        title: languageStore.localized("マスク"),
        detail: maskLaneDetailText
      )
        .frame(height: dynamicMaskLaneHeight)
    }
  }

  private func timelineLayerLabel(title: String, detail: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.primary.opacity(0.64))
        .lineLimit(1)

      if let detail {
        Text(detail)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(Color.primary.opacity(EditorLayout.timelineLabelDetailOpacity))
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.top, EditorLayout.timelineLabelTopPadding)
  }

  private var cameraLayerDetailText: String? {
    let count = cameraEffectSegments.count
    guard count > 0 else { return nil }
    return count > 1
      ? languageStore.localizedFormat("%d segments", count)
      : nil
  }

  private func waveformLane(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    let laneSegments = unifiedAudioLaneSegment.map { [$0] } ?? []
    return mediaClipLane(
      width: width,
      activeWidth: activeWidth,
      duration: duration,
      segments: laneSegments,
      emptyState: timelineWaveformState,
      waveformBins: primaryAudioWaveformBins,
      fill: EditorPalette.brand,
      label: languageStore.localized("音声"),
      systemImage: "waveform",
      showsWaveform: true
    )
    .task(id: waveformTaskID) {
      await loadWaveform()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("音声")
    .accessibilityValue(waveformAccessibilityValue)
  }

  private func cameraLane(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    mediaClipLane(
      width: width,
      activeWidth: activeWidth,
      duration: duration,
      segments: cameraEffectSegments,
      emptyState: .empty,
      waveformBins: [],
      fill: Color(red: 0.42, green: 0.58, blue: 0.88),
      label: languageStore.localized("カメラ"),
      systemImage: "video.fill",
      showsWaveform: false
    )
  }

  @ViewBuilder
  private func mediaClipLane(
    width: CGFloat,
    activeWidth: CGFloat,
    duration: Double,
    segments: [EditorTimelineEffectSegment],
    emptyState: TimelineWaveformModel.State,
    waveformBins: [Float],
    fill: Color,
    label: String,
    systemImage: String,
    showsWaveform: Bool
  ) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.primary.opacity(0.050))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.060), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let seconds = displaySeconds(forTimelineContentX: value.location.x, duration: duration, activeWidth: activeWidth)
              seekDisplaySeconds(seconds, duration: duration, activeWidth: activeWidth)
            }
            .onEnded { _ in
              timelineSnapFeedback = nil
            }
        )

      if segments.isEmpty {
        mediaClipLaneEmptyState(emptyState, showsWaveform: showsWaveform)
      } else {
        ForEach(segments) { segment in
          mediaEditableClipLaneContent(
            segment: segment,
            activeWidth: activeWidth,
            duration: duration,
            waveformBins: showsWaveform ? waveformBins : [],
            fill: fill,
            label: label,
            systemImage: systemImage
          )
        }
      }
    }
    .frame(width: width, height: EditorLayout.timelineClipLaneHeight)
    .transaction { transaction in
      if isDraggingMediaTrim {
        transaction.disablesAnimations = true
        transaction.animation = nil
      }
    }
  }

  /// クリップレーンと同じ z 順・ハンドル常時表示・LiveTrim 配置。
  @ViewBuilder
  private func mediaEditableClipLaneContent(
    segment: EditorTimelineEffectSegment,
    activeWidth: CGFloat,
    duration: Double,
    waveformBins: [Float],
    fill: Color,
    label: String,
    systemImage: String
  ) -> some View {
    let displayStart = mediaDisplayedStartSeconds(for: segment)
    let displayEnd = mediaDisplayedEndSeconds(for: segment)
    let startX = timelineContentX(displayStart, duration: duration, activeWidth: activeWidth)
    let endX = timelineContentX(displayEnd, duration: duration, activeWidth: activeWidth)
    let blockWidth = max(EditorLayout.timelineMinimumClipWidth, endX - startX)
    let isSelected = segment.selection == selectedEffect
    let segmentWaveformBins = segment.kind == .audio
      ? croppedWaveformBins(forMediaStart: displayStart, end: displayEnd)
      : waveformBins
    let canEdit = canEditMediaEffectRange(segment.kind)

    ZStack(alignment: .leading) {
      timelineMediaClipBlock(
        width: blockWidth,
        fill: fill,
        isSelected: isSelected,
        waveformBins: segmentWaveformBins,
        label: label,
        systemImage: systemImage,
        startSeconds: displayStart,
        endSeconds: displayEnd
      )
      .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
      .offset(x: max(0, startX))
      .contentShape(Rectangle())
      .onTapGesture {
        guard let selection = segment.selection else { return }
        onSelectEffect(selection)
      }
      .zIndex(1)

      if canEdit {
        if !hidesSwiftUIMediaTrimHandlesDuringLiveDrag {
          mediaTrimHandle(isLeading: true, startSeconds: displayStart, endSeconds: displayEnd)
            .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
            .offset(x: max(0, startX - EditorLayout.timelineTrimHandleHitWidth / 2))
            .zIndex(3)
            .allowsHitTesting(false)
          mediaTrimHandle(isLeading: false, startSeconds: displayStart, endSeconds: displayEnd)
            .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
            .offset(x: max(0, endX - EditorLayout.timelineTrimHandleHitWidth / 2))
            .zIndex(3)
            .allowsHitTesting(false)
        }

        if isDraggingMediaTrim, mediaTrimSegmentSelection == segment.selection {
          mediaTrimTimeLabel(editorFormatTime(displayStart, fractional: true))
            .offset(x: max(0, startX - 22), y: -16)
            .zIndex(5)
          mediaTrimTimeLabel(editorFormatTime(displayEnd, fractional: true))
            .offset(x: max(0, endX - 22), y: -16)
            .zIndex(5)
        }

        if let trimMetrics = mediaLiveTrimMetrics(
          for: segment,
          displayStart: displayStart,
          displayEnd: displayEnd,
          duration: duration
        ) {
          EditorTimelineLiveTrimLayerSurface(
            startSeconds: trimMetrics.startSeconds,
            endSeconds: trimMetrics.endSeconds,
            assetDurationSeconds: trimMetrics.assetDuration,
            minDurationSeconds: trimMetrics.minSourceDuration,
            timelineWidth: activeWidth,
            barHeight: EditorLayout.timelineClipHeight,
            handleWidth: EditorLayout.timelineTrimHandleWidth,
            hitWidth: EditorLayout.timelineTrimHandleHitWidth,
            snapEnabled: timelineSnapEnabled,
            snapTargetsSeconds: timelineSnapTargets(duration: duration).map(\.seconds),
            snapThresholdSeconds: snapThresholdSeconds(duration: duration, activeWidth: activeWidth),
            onHoverLeading: { isHoveringMediaLeadingTrim = $0 },
            onHoverTrailing: { isHoveringMediaTrailingTrim = $0 },
            onDragBegan: { handle, start, end in
              if let selection = segment.selection, selectedEffect != selection {
                onSelectEffect(selection)
              }
              var transaction = Transaction()
              transaction.disablesAnimations = true
              transaction.animation = nil
              withTransaction(transaction) {
                liveMediaTrimStartSeconds = start
                liveMediaTrimEndSeconds = end
                isDraggingMediaTrim = true
                hidesSwiftUIMediaTrimHandlesDuringLiveDrag = true
                hidesSwiftUIPlayheadDuringTrimDrag = true
              }
              _ = beginMediaTrimInteraction(segment: segment)
            },
            onDragEnded: { handle, start, end, completion in
              let token = mediaTrimInteractionToken
              finishMediaTrimDrag(
                segment: segment,
                handle: handle,
                start: start,
                end: end,
                token: token
              ) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                transaction.animation = nil
                withTransaction(transaction) {
                  hidesSwiftUIPlayheadDuringTrimDrag = false
                }
                completion()
              }
            }
          )
          .frame(width: activeWidth, height: EditorLayout.timelineClipLaneHeight)
          .offset(x: EditorLayout.timelineLaneInsetX)
          .zIndex(4)
        }
      }
    }
  }

  @ViewBuilder
  private func mediaClipLaneEmptyState(_ state: TimelineWaveformModel.State, showsWaveform: Bool) -> some View {
    if showsWaveform {
      switch state {
      case .loading:
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(languageStore.localized("読み込み中"))
            .font(.caption2)
            .foregroundStyle(Color.primary.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        Text(message)
          .font(.caption2)
          .foregroundStyle(Color.primary.opacity(0.45))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .empty:
        Text(languageStore.localized("音声なし"))
          .font(.caption2)
          .foregroundStyle(Color.primary.opacity(0.45))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .ready:
        EmptyView()
      }
    }
  }

  private func mediaDisplayedStartSeconds(for segment: EditorTimelineEffectSegment) -> Double {
    if isDraggingMediaTrim, mediaTrimSegmentSelection == segment.selection {
      return liveMediaTrimStartSeconds
    }
    return segment.startSeconds
  }

  private func mediaDisplayedEndSeconds(for segment: EditorTimelineEffectSegment) -> Double {
    if isDraggingMediaTrim, mediaTrimSegmentSelection == segment.selection {
      return liveMediaTrimEndSeconds
    }
    return segment.endSeconds
  }

  private func mediaLiveTrimMetrics(
    for segment: EditorTimelineEffectSegment,
    displayStart: Double,
    displayEnd: Double,
    duration: Double
  ) -> LiveTrimMetrics? {
    guard canEditMediaEffectRange(segment.kind) else { return nil }
    let minDuration: Double
    switch segment.kind {
    case .camera:
      minDuration = RecordingProject.TimelineMediaEditing.minCameraSpanSeconds
    case .audio:
      minDuration = RecordingProject.TimelineMediaEditing.minAudioSpanSeconds
    default:
      return nil
    }
    return LiveTrimMetrics(
      startSeconds: displayStart,
      endSeconds: displayEnd,
      minSourceDuration: minDuration,
      assetDuration: max(sourceDurationSeconds, duration, displayEnd)
    )
  }

  private func beginMediaTrimInteraction(segment: EditorTimelineEffectSegment) -> UUID {
    let token = UUID()
    mediaTrimInteractionToken = token
    mediaTrimSegmentSelection = segment.selection
    onTrimDragBegan()
    return token
  }

  private func finishMediaTrimDrag(
    segment: EditorTimelineEffectSegment,
    handle: EditorTimelineActiveTrimHandle,
    start: Double,
    end: Double,
    token: UUID,
    completion: @escaping () -> Void
  ) {
    guard token == mediaTrimInteractionToken else {
      completion()
      return
    }
    guard let selection = segment.selection else {
      completion()
      return
    }

    var transaction = Transaction()
    transaction.disablesAnimations = true
    transaction.animation = nil
    withTransaction(transaction) {
      liveMediaTrimStartSeconds = start
      liveMediaTrimEndSeconds = end
      isDraggingMediaTrim = false
      hidesSwiftUIMediaTrimHandlesDuringLiveDrag = false
    }

    switch selection {
    case .camera(let id):
      onCommitCameraEffectRange(id, start, end)
    case .audio:
      onCommitUnifiedAudioEffectRange(start, end)
    default:
      break
    }

    resetMediaTrimDragState()
    onTrimDragEnded()
    completion()
  }

  private func resetMediaTrimDragState() {
    isDraggingMediaTrim = false
    hidesSwiftUIMediaTrimHandlesDuringLiveDrag = false
    mediaTrimSegmentSelection = nil
    isHoveringMediaLeadingTrim = false
    isHoveringMediaTrailingTrim = false
  }

  private func mediaTrimHandle(
    isLeading: Bool,
    startSeconds: Double,
    endSeconds: Double
  ) -> some View {
    let isHovering = isLeading ? isHoveringMediaLeadingTrim : isHoveringMediaTrailingTrim
    return ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white.opacity(isHovering ? 0.74 : 0.56))
        .frame(width: EditorLayout.timelineTrimHandleWidth, height: EditorLayout.timelineTrimHandleHeight)
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(isHovering ? EditorPalette.brandStrong.opacity(0.90) : Color.black.opacity(0.10), lineWidth: isHovering ? 1.5 : 1)
        }
        .overlay {
          HStack(spacing: 2) {
            Rectangle().fill(Color.black.opacity(0.18)).frame(width: 1, height: 14)
            Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1, height: 14)
          }
        }
    }
    .frame(width: EditorLayout.timelineTrimHandleHitWidth, height: EditorLayout.timelineTrimHandleHeight)
    .contentShape(Rectangle())
    .accessibilityLabel(isLeading ? "開始トリムハンドル" : "終了トリムハンドル")
    .accessibilityValue(editorFormatTime(isLeading ? startSeconds : endSeconds, fractional: true))
  }

  private func mediaTrimTimeLabel(_ text: String) -> some View {
    trimTimeLabel(text)
  }

  @ViewBuilder
  private func timelineMediaClipBlock(
    width: CGFloat,
    fill: Color,
    isSelected: Bool,
    waveformBins: [Float],
    label: String,
    systemImage: String,
    startSeconds: Double,
    endSeconds: Double
  ) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(fill.opacity(isSelected ? 0.90 : 0.80))

      if !waveformBins.isEmpty, width > 24 {
        timelineWaveformCanvas(bins: waveformBins, color: Color.white.opacity(0.82))
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
      }

      clipFrameMarkers()
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      if width > 52 {
        HStack(spacing: 5) {
          Image(systemName: systemImage)
            .font(.system(size: 9, weight: .semibold))
          Text(
            languageStore.localizedFormat(
              "%@ %@–%@",
              label,
              editorFormatTime(startSeconds, fractional: true),
              editorFormatTime(endSeconds, fractional: true)
            )
          )
          Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.black.opacity(0.60))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, EditorLayout.timelineClipTextLeadingPadding)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: width, height: EditorLayout.timelineClipHeight)
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(
          isSelected ? EditorPalette.brandStrong : Color.black.opacity(0.10),
          lineWidth: isSelected ? 1.5 : 1
        )
    }
  }

  private func timelineWaveformCanvas(bins: [Float], color: Color) -> some View {
    Canvas { context, size in
      let samples = TimelineWaveformModel.downsample(bins, targetCount: max(2, Int(size.width / 2)))
      guard !samples.isEmpty, size.width > 1, size.height > 1 else { return }
      let midY = size.height / 2
      let step = size.width / CGFloat(samples.count)
      var waveformPath = Path()
      waveformPath.move(to: CGPoint(x: 0, y: midY))
      for (sampleIndex, sample) in samples.enumerated() {
        let x = (CGFloat(sampleIndex) + 0.5) * step
        let barHeight = max(1, CGFloat(sample) * midY * 0.88)
        waveformPath.addLine(to: CGPoint(x: x, y: midY - barHeight))
      }
      for (sampleIndex, sample) in samples.enumerated().reversed() {
        let x = (CGFloat(sampleIndex) + 0.5) * step
        let barHeight = max(1, CGFloat(sample) * midY * 0.88)
        waveformPath.addLine(to: CGPoint(x: x, y: midY + barHeight))
      }
      waveformPath.closeSubpath()
      context.fill(waveformPath, with: .color(color))
    }
  }

  private func audioEffectSegment(for role: RecordingProject.AudioTrackSettings.Role) -> EditorTimelineEffectSegment? {
    guard let projectSegment = project.audioTimelineSegments.first(where: { $0.role == role }) else { return nil }
    return audioEffectSegments.first { $0.selection == .audio(projectSegment.id) }
  }

  private func isAudioRoleSelected(_ role: RecordingProject.AudioTrackSettings.Role) -> Bool {
    guard let projectSegment = project.audioTimelineSegments.first(where: { $0.role == role }) else { return false }
    return selectedEffect == .audio(projectSegment.id)
  }

  private func audioRoleBadge(_ status: TimelineAudioRoleStatus, isSelected: Bool) -> some View {
    Text(localizedAudioRoleValue(status))
      .font(.system(size: 9, weight: .semibold, design: .rounded))
      .foregroundStyle(status.isAvailable && status.isEnabled ? Color.primary.opacity(0.70) : Color.primary.opacity(0.42))
      .lineLimit(1)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(
            isSelected
              ? EditorPalette.brand.opacity(0.28)
              : (status.isAvailable && status.isEnabled ? EditorPalette.brand.opacity(0.16) : Color.primary.opacity(0.055))
          )
      )
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(
            isSelected
              ? EditorPalette.brand.opacity(0.55)
              : (status.isAvailable && status.isEnabled ? EditorPalette.brand.opacity(0.22) : Color.primary.opacity(0.070)),
            lineWidth: isSelected ? 1.5 : 1
          )
      }
  }

  private var waveformTaskID: String {
    let clipsHash = project.timeline.activeClips.map { clip in
      let rate = project.timeline.speedRate(for: clip)
      return "\(clip.id.uuidString):\(clip.sourceStartSeconds):\(clip.timelineStartSeconds):\(clip.durationSeconds):\(rate)"
    }.joined(separator: "|")
    let rolesHash = includesBackgroundMusicWaveform ? "mixed+bgm" : "mixed"
    let bgmHash = project.audioTrackSettings.backgroundMusicURL?.absoluteString ?? "none"
    let audioHash = project.audioTimelineSegments.map {
      "\($0.id.uuidString):\($0.role.rawValue):\($0.startSeconds):\($0.endSeconds)"
    }.joined(separator: "|")
    return "\(project.id.uuidString)|\(clipsHash)|\(rolesHash)|\(bgmHash)|\(audioHash)"
  }

  private func visibleTimelineRange(duration: Double) -> TimelineVisibleRange {
    TimelineViewport(
      durationSeconds: duration,
      visibleWidth: max(timelineScrollState.visibleWidth, 1),
      zoomScale: timelineZoomScale
    )
    .visibleRange(forOffsetX: timelineScrollState.contentOffsetX)
  }

  private func loadWaveform() async {
    timelineWaveformState = .loading
    timelineWaveformRoleData = []
    do {
      let clips = project.timeline.activeClips
      let totalDuration = max(sourceDurationSeconds, durationSeconds)
      if clips.count > 1 {
        // マルチクリップは合成波形を単一ロールとして扱う。
        let inputs = clips.map { clip in
          TimelineAudioWaveformLoader.ClipWaveformInput(
            sourceURL: clip.sourceURL,
            sourceStartSeconds: clip.sourceStartSeconds,
            durationSeconds: clip.durationSeconds,
            rate: project.timeline.speedRate(for: clip),
            timelineStartSeconds: clip.timelineStartSeconds
          )
        }
        let bins = try await TimelineAudioWaveformLoader.peakEnvelopeForTimeline(
          clips: inputs,
          totalDuration: totalDuration,
          maxBins: 800
        )
        guard !Task.isCancelled else { return }
        let roleData: [(role: RecordingProject.AudioTrackSettings.Role, bins: [Float])] = bins.isEmpty ? [] : [(.microphone, bins)]
        timelineWaveformRoleData = roleData
        timelineWaveformState = bins.isEmpty ? .empty : .ready(bins)
      } else {
        let assetURL = clips.first?.sourceURL ?? project.mediaURL
        let sourceRange: ClosedRange<Double>? = {
          guard clips.count == 1, let clip = clips.first else { return nil }
          let rate = max(project.timeline.speedRate(for: clip), 1e-9)
          let start = max(0, clip.sourceStartSeconds)
          let end = start + max(0.001, clip.durationSeconds * rate)
          return start ... end
        }()
        var roleData: [(role: RecordingProject.AudioTrackSettings.Role, bins: [Float])] = []
        let mixedBins = try await TimelineAudioWaveformLoader.peakEnvelopeMixed(
          assetURL: assetURL,
          assetDurationSeconds: totalDuration,
          maxBins: 800,
          sourceRange: sourceRange
        )
        if !mixedBins.isEmpty {
          roleData.append((.microphone, mixedBins))
        }
        if includesBackgroundMusicWaveform, let bgmURL = project.audioTrackSettings.backgroundMusicURL {
          let bgmBins = try await TimelineAudioWaveformLoader.peakEnvelopeNormalizedBins(
            assetURL: bgmURL,
            assetDurationSeconds: totalDuration,
            maxBins: 800,
            trackIndex: 0
          )
          if !bgmBins.isEmpty {
            roleData.append((.backgroundMusic, bgmBins))
          }
        }
        guard !Task.isCancelled else { return }
        timelineWaveformRoleData = roleData
        timelineWaveformState = roleData.isEmpty ? .empty : .ready(roleData.first?.bins ?? [])
      }
    } catch {
      guard !Task.isCancelled else { return }
      timelineWaveformRoleData = []
      timelineWaveformState = .failed(error.localizedDescription)
    }
  }

  private var waveformAccessibilityValue: String {
    let roleSummary = audioRoleStatuses.map { localizedAudioRoleValue($0) }.joined(separator: "、")
    switch timelineWaveformState {
    case .empty:
      return "\(languageStore.localized("音声なし"))。\(roleSummary)"
    case .loading:
      return "\(languageStore.localized("読み込み中"))。\(roleSummary)"
    case .ready:
      return "\(languageStore.localized("読み込み済み"))。\(roleSummary)"
    case .failed(let message):
      return "\(message)。\(roleSummary)"
    }
  }

  private func localizedAudioRoleValue(_ status: TimelineAudioRoleStatus) -> String {
    let title = languageStore.localized(status.title)
    guard status.isAvailable else { return languageStore.localizedFormat("%@ 未接続", title) }
    guard status.isEnabled else { return languageStore.localizedFormat("%@ ミュート", title) }
    return languageStore.localizedFormat("%@ 音量 %d%%", title, Int((status.volume * 100).rounded()))
  }

  private func snapFeedbackView(feedback: TimelineSnapFeedback, duration: Double, activeWidth: CGFloat) -> some View {
    let x = timelineContentX(feedback.seconds, duration: duration, activeWidth: activeWidth)
    return VStack(alignment: .leading, spacing: 2) {
      if !feedback.label.isEmpty {
        Text(feedback.label)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.black.opacity(0.70))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(EditorPalette.brand.opacity(0.82), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .offset(x: max(0, x - 14), y: 0)
      }

      Rectangle()
        .fill(EditorPalette.brandStrong.opacity(0.80))
        .frame(width: 1.5, height: dynamicTimelineTrackHeight - 12)
        .offset(x: x, y: 0)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private enum RulerTickKind {
    case endpoint
    case major
    case minor
  }

  private func rulerTickKind(seconds: Double, duration: Double, majorStep: Double) -> RulerTickKind {
    if seconds <= 0.001 || abs(seconds - duration) <= 0.001 {
      return .endpoint
    }
    if abs(seconds.truncatingRemainder(dividingBy: majorStep)) <= 0.001 {
      return .major
    }
    return .minor
  }

  private func rulerTickOpacity(_ kind: RulerTickKind) -> Double {
    switch kind {
    case .endpoint:
      return 0.62
    case .major:
      return 0.36
    case .minor:
      return 0.16
    }
  }

  private func rulerTickHeight(_ kind: RulerTickKind) -> CGFloat {
    switch kind {
    case .endpoint:
      return EditorLayout.timelineRulerMajorTickHeight + 2
    case .major:
      return EditorLayout.timelineRulerMajorTickHeight
    case .minor:
      return EditorLayout.timelineRulerMinorTickHeight
    }
  }

  private func timelineRuler(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    let minorStep = rulerMinorStep(for: duration)
    let majorStep = rulerMajorStep(for: duration)
    let showFraction = rulerShowsFraction(for: duration)
    let count = max(1, Int(ceil(duration / minorStep)))
    let labelWidth: CGFloat = showFraction ? 48 : 38

    return ZStack(alignment: .leading) {
      ForEach(0...count, id: \.self) { index in
        let seconds = min(duration, Double(index) * minorStep)
        let tickKind = rulerTickKind(seconds: seconds, duration: duration, majorStep: majorStep)
        let x = timelineContentX(seconds, duration: duration, activeWidth: activeWidth)

        Rectangle()
          .fill(Color.primary.opacity(rulerTickOpacity(tickKind)))
          .frame(
            width: tickKind == .endpoint ? 1.5 : 1,
            height: rulerTickHeight(tickKind)
          )
          .offset(x: x, y: tickKind == .minor ? 16 : 9)

        if tickKind != .minor {
          Text(editorFormatTime(seconds, fractional: showFraction))
            .font(.system(size: tickKind == .endpoint ? 11 : 10, weight: tickKind == .endpoint ? .bold : .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(tickKind == .endpoint ? 0.82 : 0.58))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .offset(x: max(0, min(width - labelWidth, x - labelWidth / 2)), y: 0)
        }
      }
    }
    .frame(width: width, height: EditorLayout.timelineRulerHeight, alignment: .topLeading)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          let seconds = displaySeconds(forTimelineContentX: value.location.x, duration: duration, activeWidth: activeWidth)
          seekDisplaySeconds(seconds, duration: duration, activeWidth: activeWidth)
        }
        .onEnded { _ in
          timelineSnapFeedback = nil
        }
    )
    .accessibilityHidden(true)
  }

  private func clipLane(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    let activeClips = project.timeline.activeClips
    let trimMetrics = liveTrimMetrics(duration: duration)
    let startSeconds = trimMetrics?.startSeconds ?? displayedTrimStartSeconds
    let endSeconds = trimMetrics?.endSeconds ?? displayedTrimEndSeconds
    let startX = timelineContentX(startSeconds, duration: duration, activeWidth: activeWidth)
    let endX = timelineContentX(endSeconds, duration: duration, activeWidth: activeWidth)
    let singleClip = project.timeline.singleEditableClip

    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.primary.opacity(0.050))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.060), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let seconds = displaySeconds(forTimelineContentX: value.location.x, duration: duration, activeWidth: activeWidth)
              seekDisplaySeconds(seconds, duration: duration, activeWidth: activeWidth)
            }
            .onEnded { _ in
              timelineSnapFeedback = nil
            }
        )

      if activeClips.isEmpty || singleClip != nil {
        singleClipBlock(width: max(EditorLayout.timelineMinimumClipWidth, endX - startX))
          .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
          .offset(x: max(0, startX))
          .zIndex(1)
      } else {
        ForEach(activeClips) { clip in
          let clipX = timelineContentX(clip.timelineStartSeconds, duration: duration, activeWidth: activeWidth)
          timelineClipBlock(clip: clip, duration: duration, width: activeWidth)
            .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
            .opacity(draggingClipID == clip.id ? 0.62 : 1)
            .offset(x: clipX)
            .simultaneousGesture(
              DragGesture(minimumDistance: 0)
                .onChanged { value in
                  let seconds = displaySeconds(forTimelineContentX: clipX + value.location.x, duration: duration, activeWidth: activeWidth)
                  seekDisplaySeconds(seconds, duration: duration, activeWidth: activeWidth)
                }
                .onEnded { _ in
                  timelineSnapFeedback = nil
                }
            )
            .gesture(clipReorderGesture(clip: clip, clips: activeClips, duration: duration, activeWidth: activeWidth, clipX: clipX))
            .zIndex(1)
        }

        if let pendingClipDropIndex {
          clipDropIndicator(index: pendingClipDropIndex, clips: activeClips, duration: duration, activeWidth: activeWidth)
            .zIndex(5)
        }
      }

      if activeClips.count <= 1 {
        if !hidesSwiftUITrimHandlesDuringLiveDrag {
          trimHandle(isLeading: true)
            .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
            .offset(x: max(0, startX - EditorLayout.timelineTrimHandleHitWidth / 2))
            .zIndex(3)
          trimHandle(isLeading: false)
            .frame(height: EditorLayout.timelineClipLaneHeight, alignment: .center)
            .offset(x: max(0, endX - EditorLayout.timelineTrimHandleHitWidth / 2))
            .zIndex(3)
        }
        if isDraggingTrimBoundary {
          trimTimeLabel(editorFormatTime(displayedTrimStartSeconds, fractional: true))
            .offset(x: max(0, startX - 22), y: -16)
            .zIndex(5)
          trimTimeLabel(editorFormatTime(displayedTrimEndSeconds, fractional: true))
            .offset(x: max(0, endX - 22), y: -16)
            .zIndex(5)
        }
        if let trimMetrics {
          EditorTimelineLiveTrimLayerSurface(
            startSeconds: trimMetrics.startSeconds,
            endSeconds: trimMetrics.endSeconds,
            assetDurationSeconds: trimMetrics.assetDuration,
            minDurationSeconds: trimMetrics.minSourceDuration,
            timelineWidth: activeWidth,
            barHeight: EditorLayout.timelineClipHeight,
            handleWidth: EditorLayout.timelineTrimHandleWidth,
            hitWidth: EditorLayout.timelineTrimHandleHitWidth,
            snapEnabled: timelineSnapEnabled,
            snapTargetsSeconds: timelineSnapTargets(duration: duration).map(\.seconds),
            snapThresholdSeconds: snapThresholdSeconds(duration: duration, activeWidth: activeWidth),
            onHoverLeading: { isHoveringLeadingTrim = $0 },
            onHoverTrailing: { isHoveringTrailingTrim = $0 },
            onDragBegan: { handle, start, end in
              var transaction = Transaction()
              transaction.disablesAnimations = true
              transaction.animation = nil
              withTransaction(transaction) {
                liveTrimStartSeconds = start
                liveTrimEndSeconds = end
                isDraggingTrim = true
                hidesSwiftUITrimHandlesDuringLiveDrag = true
                hidesSwiftUIPlayheadDuringTrimDrag = true
              }
              _ = beginTrimInteraction()
            },
            onDragEnded: { handle, start, end, completion in
              let token = trimInteractionToken
              finishLiveTrimDrag(handle: handle, start: start, end: end, token: token) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                transaction.animation = nil
                withTransaction(transaction) {
                  hidesSwiftUITrimHandlesDuringLiveDrag = false
                  hidesSwiftUIPlayheadDuringTrimDrag = false
                }
                completion()
              }
            }
          )
          .frame(width: activeWidth, height: EditorLayout.timelineClipLaneHeight)
          .offset(x: EditorLayout.timelineLaneInsetX)
          .zIndex(4)
        }
      }
    }
    .transaction { transaction in
      if isDraggingTrimBoundary {
        transaction.disablesAnimations = true
        transaction.animation = nil
      }
    }
  }

  private func motionEffectsLane(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    let segments = mediaTimelineSegments
      .filter { $0.kind == .zoom || $0.kind == .caption }
    return effectLane(
      segments: segments,
      width: width,
      activeWidth: activeWidth,
      duration: duration,
      laneHeight: EditorLayout.timelineEffectLaneHeight,
      usesZoomPeerIntervals: true
    )
  }

  private func maskEffectsLane(width: CGFloat, activeWidth: CGFloat, duration: Double) -> some View {
    let segments = maskEffectSegments
    let rowAssignments = TimelineEffectRowLayout.assignments(
      for: segments,
      maxRows: EditorLayout.timelineMaskLaneMaxRows
    )
    let rowCount = maskLaneRowCount
    let laneHeight = dynamicMaskLaneHeight
    return effectLane(
      segments: segments,
      width: width,
      activeWidth: activeWidth,
      duration: duration,
      laneHeight: laneHeight,
      usesZoomPeerIntervals: false,
      rowAssignments: rowAssignments,
      rowCount: rowCount
    )
  }

  private func effectLane(
    segments: [EditorTimelineEffectSegment],
    width: CGFloat,
    activeWidth: CGFloat,
    duration: Double,
    laneHeight: CGFloat,
    usesZoomPeerIntervals: Bool,
    rowAssignments: [String: Int]? = nil,
    rowCount: Int = 1
  ) -> some View {
    let displayedSegments = EditorTimelineEffectSegment.displayedSegments(
      segments,
      liveRange: effectRangeEditSession?.live
    )
    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.036))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)

      if !displayedSegments.isEmpty {
        ForEach(displayedSegments) { segment in
          let frame = segment.timelineFrame(duration: duration, activeWidth: activeWidth)
          let displayRange = effectDisplayRange(for: segment)
          let row = rowAssignments?[segment.id] ?? 0
          let segmentHeight = rowAssignments == nil
            ? (segment.kind == .zoom ? EditorLayout.timelineZoomSegmentHeight : EditorLayout.timelineEffectSegmentHeight)
            : EditorLayout.timelineEffectSegmentHeight
          let rowYOffset = rowAssignments == nil
            ? (laneHeight - segmentHeight) / 2
            : EditorLayout.timelineMaskRowYOffset(row: row, rowCount: rowCount, laneHeight: laneHeight)
          effectSegmentBlock(
            segment: segment,
            width: frame.width,
            displayRange: displayRange
          )
            .frame(height: segmentHeight, alignment: .center)
            .offset(x: frame.x, y: rowYOffset)
            .gesture(
              effectSegmentInteractionGesture(
                segment: segment,
                duration: duration,
                activeWidth: activeWidth
              )
            )
            .zIndex(segment.selection == selectedEffect ? 4 : 1)
        }
      }

      if let selectedEffect,
        let segment = displayedSegments.first(where: { $0.selection == selectedEffect }),
        let range = editableEffectRange(for: segment) {
        let liveRange = effectRangeEditSession?.matches(selection: selectedEffect) == true
          ? effectRangeEditSession?.live
          : nil
        let row = rowAssignments?[segment.id] ?? 0
        let interactionHeight = rowAssignments == nil
          ? laneHeight
          : EditorLayout.timelineEffectSegmentHeight
        let rowYOffset = rowAssignments == nil
          ? (laneHeight - interactionHeight) / 2
          : EditorLayout.timelineMaskRowYOffset(row: row, rowCount: rowCount, laneHeight: laneHeight)
        EditorTimelineEffectRangeInteractionSurface(
          range: liveRange ?? range,
          timelineDurationSeconds: duration,
          totalDurationSeconds: sourceDurationSeconds,
          timelineWidth: activeWidth,
          edgeHitWidth: EditorLayout.timelineTrimHandleWidth,
          liveLayerStyle: effectLiveLayerStyle(for: segment.kind),
          peerZoomIntervals: usesZoomPeerIntervals
            ? zoomPeerIntervals(excludingID: range.id)
            : [],
          onDragBegan: { original, mode in
            beginEffectRangeSurfaceDrag(
              selection: selectedEffect,
              original: original,
              mode: mode,
              useAppKitLivePreview: true
            )
          },
          onDragChanged: { live, mode in
            updateEffectRangeSurfaceDrag(selection: selectedEffect, live: live, mode: mode)
          },
          onDragEnded: { live, mode in
            finishEffectRangeSurfaceDrag(selection: selectedEffect, live: live, mode: mode)
          }
        )
        .frame(width: activeWidth, height: interactionHeight)
        .offset(x: EditorLayout.timelineLaneInsetX, y: rowYOffset)
        .zIndex(5)
      }

    }
    .frame(height: laneHeight, alignment: .topLeading)
    .transaction { transaction in
      if effectRangeEditSession != nil {
        transaction.disablesAnimations = true
        transaction.animation = nil
      }
    }
  }

  private func zoomPeerIntervals(excludingID: UUID) -> [TimelineZoomOverlapPolicy.Interval] {
    TimelineZoomOverlapPolicy.peerIntervals(
      excludingID: excludingID,
      segments: project.zoomSegments
    )
  }

  private func resolvedZoomRange(
    _ range: TimelineEditableRange,
    mode: EffectRangeEditMode,
    moveReferenceStart: Double? = nil
  ) -> TimelineEditableRange {
    guard range.kind == .zoom else { return range }
    let reference = moveReferenceStart ?? effectRangeEditSession?.original.startSeconds
    return TimelineZoomOverlapPolicy.resolve(
      range,
      mode: mode,
      peers: zoomPeerIntervals(excludingID: range.id),
      totalDuration: sourceDurationSeconds,
      moveReferenceStart: reference
    )
  }

  private func effectDisplayRange(for segment: EditorTimelineEffectSegment) -> TimelineEditableRange? {
    if let session = effectRangeEditSession,
      let selection = segment.selection,
      session.matches(selection: selection) {
      return session.live
    }
    return editableEffectRange(for: segment)
  }

  private func effectSegmentBlock(
    segment: EditorTimelineEffectSegment,
    width: CGFloat,
    displayRange: TimelineEditableRange?
  ) -> some View {
    let isSelected = segment.selection == selectedEffect
    let segmentHeight = segment.kind == .zoom
      ? EditorLayout.timelineZoomSegmentHeight
      : EditorLayout.timelineEffectSegmentHeight
    let segmentWidth = width
    let color = effectSegmentColor(segment.kind)
    return ZStack {
      if segment.kind == .zoom {
        zoomEffectSegmentContent(
          segment: segment,
          width: segmentWidth,
          height: segmentHeight,
          color: color,
          isSelected: isSelected,
          displayRange: displayRange
        )
      } else if segment.kind == .audio {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.clear)
          .frame(width: segmentWidth, height: segmentHeight)
          .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .stroke(
                color.opacity(isSelected ? 0.72 : 0.28),
                lineWidth: isSelected ? 1.5 : 1
              )
          }
      } else {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(color.opacity(isSelected ? 0.86 : 0.62))
          .frame(width: segmentWidth, height: segmentHeight)
          .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .stroke(
                isSelected ? color.opacity(0.95) : color.opacity(0.30),
                lineWidth: isSelected ? 2 : 1
              )
          }
      }
    }
    .overlay {
      if segment.kind == .zoom, isSelected {
        zoomSegmentEdgeHandles(height: segmentHeight)
        if let displayRange {
          zoomRampHandleOverlay(
            range: displayRange,
            segmentStart: segment.startSeconds,
            segmentEnd: segment.endSeconds,
            width: segmentWidth
          )
        }
      }
    }
    .contentShape(Rectangle())
    .allowsHitTesting(segment.selection != nil)
    .opacity(isSelected && hidesSwiftUIEffectDuringLiveDrag ? 0.02 : 1)
    .accessibilityLabel(effectSegmentKindLabel(segment.kind))
    .accessibilityValue(languageStore.localizedFormat(
      "%@ to %@",
      editorFormatTime(segment.startSeconds, fractional: true),
      editorFormatTime(segment.endSeconds, fractional: true)
    ))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func zoomEffectSegmentContent(
    segment: EditorTimelineEffectSegment,
    width: CGFloat,
    height: CGFloat,
    color: Color,
    isSelected: Bool,
    displayRange: TimelineEditableRange?
  ) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(color.opacity(isSelected ? 0.88 : 0.76))

      if let displayRange, displayRange.kind == .zoom, width > 12 {
        zoomRampZones(
          range: displayRange,
          segmentStart: segment.startSeconds,
          segmentEnd: segment.endSeconds,
          width: width,
          height: height,
          color: color
        )
      }

      clipFrameMarkers()
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(isSelected ? 0.55 : 1)

      if width > 34 {
        HStack(spacing: 5) {
          Image(systemName: "plus.magnifyingglass")
            .font(.system(size: 9, weight: .semibold))
          if width > 72 {
            Text("ズーム")
          }
          Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.black.opacity(0.58))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .padding(.leading, isSelected ? 20 : 8)
        .padding(.trailing, isSelected ? 18 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: width, height: height)
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(isSelected ? EditorPalette.brandStrong : Color.black.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
    }
  }

  private func zoomEdgeTrimHandle(isLeading: Bool) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white.opacity(0.58))
        .frame(width: 6, height: EditorLayout.timelineZoomSegmentHeight + 4)
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.black.opacity(0.16), lineWidth: 1)
        }
        .overlay {
          Rectangle()
            .fill(Color.black.opacity(0.16))
            .frame(width: 1, height: 14)
        }
    }
    .frame(width: 6, alignment: isLeading ? .leading : .trailing)
  }

  private func zoomRampZones(
    range: TimelineEditableRange,
    segmentStart: Double,
    segmentEnd: Double,
    width: CGFloat,
    height: CGFloat,
    color: Color
  ) -> some View {
    let span = max(0.001, segmentEnd - segmentStart)
    let inEnd = min(max(range.inEndSeconds ?? range.startSeconds, segmentStart), segmentEnd)
    let outStart = min(max(range.outStartSeconds ?? range.endSeconds, inEnd), segmentEnd)
    let rampInWidth = width * CGFloat((inEnd - segmentStart) / span)
    let holdWidth = width * CGFloat((outStart - inEnd) / span)
    let rampOutWidth = max(0, width - rampInWidth - holdWidth)

    return HStack(spacing: 0) {
      if rampInWidth > 0.5 {
        Rectangle()
          .fill(color.opacity(0.42))
          .frame(width: rampInWidth)
      }
      if holdWidth > 0.5 {
        Rectangle()
          .fill(color.opacity(0.92))
          .frame(width: holdWidth)
      }
      if rampOutWidth > 0.5 {
        Rectangle()
          .fill(color.opacity(0.42))
          .frame(width: rampOutWidth)
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .allowsHitTesting(false)
  }

  private func zoomRampHandleOverlay(
    range: TimelineEditableRange,
    segmentStart: Double,
    segmentEnd: Double,
    width: CGFloat
  ) -> some View {
    let span = max(0.001, segmentEnd - segmentStart)
    return ZStack(alignment: .leading) {
      if let inEnd = range.inEndSeconds {
        let x = width * CGFloat((min(max(inEnd, segmentStart), segmentEnd) - segmentStart) / span)
        zoomRampHandleMarker()
          .offset(x: x - EditorLayout.timelineTrimHandleWidth / 2)
      }
      if let outStart = range.outStartSeconds {
        let x = width * CGFloat((min(max(outStart, segmentStart), segmentEnd) - segmentStart) / span)
        zoomRampHandleMarker()
          .offset(x: x - EditorLayout.timelineTrimHandleWidth / 2)
      }
    }
    .frame(width: width, alignment: .leading)
    .allowsHitTesting(false)
  }

  private func zoomRampHandleMarker() -> some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(Color.white.opacity(0.95))
      .frame(width: EditorLayout.timelineTrimHandleWidth, height: max(8, EditorLayout.timelineZoomSegmentHeight - 8))
      .overlay {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .stroke(EditorPalette.brandStrong.opacity(0.85), lineWidth: 1)
      }
      .overlay {
        Rectangle()
          .fill(EditorPalette.brandStrong.opacity(0.55))
          .frame(width: 1, height: 10)
      }
      .frame(height: EditorLayout.timelineEffectLaneHeight, alignment: .center)
      .allowsHitTesting(false)
  }

  private func zoomSegmentEdgeHandles(height: CGFloat) -> some View {
    HStack(spacing: 0) {
      zoomEdgeTrimHandle(isLeading: true)
      Spacer(minLength: 0)
      zoomEdgeTrimHandle(isLeading: false)
    }
    .frame(height: height)
    .allowsHitTesting(false)
  }

  private func editableEffectRange(for segment: EditorTimelineEffectSegment) -> TimelineEditableRange? {
    guard canEditMediaEffectRange(segment.kind) else { return nil }
    switch segment.selection {
    case .zoom(let id):
      guard sourceDurationSeconds >= RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds,
        let zoom = project.zoomSegments.first(where: { $0.id == id })
      else { return nil }
      return TimelineEditableRange(
        id: id,
        kind: .zoom,
        startSeconds: zoom.startSeconds,
        inEndSeconds: zoom.inEndSeconds,
        outStartSeconds: zoom.outStartSeconds,
        endSeconds: zoom.endSeconds,
        minDuration: RecordingProject.TimelineKeyframeSanitize.minZoomSpanSeconds,
        canTrim: true,
        canMove: true
      )
      .sanitized(durationSeconds: sourceDurationSeconds)
    case .caption(let id):
      guard sourceDurationSeconds >= 0.05,
        let caption = project.captionTrack.segments.first(where: { $0.id == id })
      else { return nil }
      return TimelineEditableRange(
        id: id,
        kind: .caption,
        startSeconds: caption.startSeconds,
        endSeconds: caption.endSeconds,
        minDuration: 0.05,
        canTrim: true,
        canMove: true
      )
      .sanitized(durationSeconds: sourceDurationSeconds)
    case .mask(let id):
      guard sourceDurationSeconds >= RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds,
        let mask = project.visualMasks.first(where: { $0.id == id })
      else { return nil }
      return TimelineEditableRange(
        id: id,
        kind: .mask,
        startSeconds: mask.startSeconds,
        endSeconds: mask.endSeconds,
        minDuration: RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds,
        canTrim: true,
        canMove: true
      )
      .sanitized(durationSeconds: sourceDurationSeconds)
    case .camera(let id):
      guard sourceDurationSeconds >= RecordingProject.TimelineMediaEditing.minCameraSpanSeconds,
        let camera = project.cameraLayoutSegments.first(where: { $0.id == id })
      else { return nil }
      return TimelineEditableRange(
        id: id,
        kind: .camera,
        startSeconds: camera.startSeconds,
        endSeconds: camera.endSeconds,
        minDuration: RecordingProject.TimelineMediaEditing.minCameraSpanSeconds,
        canTrim: true,
        canMove: false
      )
      .sanitized(durationSeconds: sourceDurationSeconds)
    case .audio(let id):
      guard sourceDurationSeconds >= RecordingProject.TimelineMediaEditing.minAudioSpanSeconds,
        let audio = project.audioTimelineSegments.first(where: { $0.id == id })
      else { return nil }
      return TimelineEditableRange(
        id: id,
        kind: .audio,
        startSeconds: audio.startSeconds,
        endSeconds: audio.endSeconds,
        minDuration: RecordingProject.TimelineMediaEditing.minAudioSpanSeconds,
        canTrim: true,
        canMove: false
      )
      .sanitized(durationSeconds: sourceDurationSeconds)
    case .none:
      return nil
    }
  }

  /// 効果セグメント本体を「掴んだ瞬間に選択し、そのままドラッグで移動」できるようにするジェスチャ。
  /// 選択中はセグメントの上に専用の操作面(NSView)が乗るため、このジェスチャは未選択セグメントの
  /// 掴み開始（選択＋移動）を担う。トリム（端の調整）は選択後の操作面側が担当する。
  private func effectSegmentInteractionGesture(
    segment: EditorTimelineEffectSegment,
    duration: Double,
    activeWidth: CGFloat
  ) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard let selection = segment.selection else { return }
        // 押下で即選択（クリックと同じ挙動 + 即時フィードバック）。
        if selectedEffect != selection {
          onSelectEffect(selection)
        }
        guard canEditMediaEffectRange(segment.kind),
          let range = editableEffectRange(for: segment)
        else { return }
        // 実際に動き始めてから移動セッションを開始する（純粋なクリックでは移動しない）。
        let movedEnough = abs(value.translation.width) > 2
        if effectRangeEditSession?.matches(selection: selection) != true {
          guard movedEnough else { return }
          beginEffectRangeSurfaceDrag(selection: selection, original: range, mode: .move)
        }
        guard let session = effectRangeEditSession,
          session.matches(selection: selection)
        else { return }
        let deltaSeconds = Double(value.translation.width / max(activeWidth, 1)) * max(0, duration)
        let live = resolvedZoomRange(
          session.original.moving(by: deltaSeconds, durationSeconds: sourceDurationSeconds),
          mode: .move
        )
        updateEffectRangeSurfaceDrag(selection: selection, live: live, mode: .move)
      }
      .onEnded { value in
        guard let selection = segment.selection,
          let session = effectRangeEditSession,
          session.matches(selection: selection)
        else { return }
        let deltaSeconds = Double(value.translation.width / max(activeWidth, 1)) * max(0, duration)
        let live = resolvedZoomRange(
          session.original.moving(by: deltaSeconds, durationSeconds: sourceDurationSeconds),
          mode: .move
        )
        finishEffectRangeSurfaceDrag(selection: selection, live: live, mode: .move)
      }
  }

  private func beginEffectRangeSurfaceDrag(
    selection: EditorTimelineEffectSelection,
    original: TimelineEditableRange,
    mode: EffectRangeEditMode,
    useAppKitLivePreview: Bool = false
  ) {
    if selectedEffect != selection {
      onSelectEffect(selection)
    }
    hidesSwiftUIEffectDuringLiveDrag = useAppKitLivePreview
    effectRangeEditSession = TimelineEffectRangeEditSession(
      id: original.id,
      kind: original.kind,
      mode: mode,
      original: original,
      live: original
    )
    onTrimDragBegan()
    if original.kind == .zoom {
      previewZoomRange(original)
      // トリム中はフレーム seek を一切行わず、開始時に一度だけ、操作に対応した安定フレーム
      // （端トリム/移動→ホールド区間、寄り/引きハンドル→そのランプ境界）へ送る。これで
      // プレビューはズーム表示のまま固定され、ドラッグ中の seek 階段とズーム描画
      // (currentSeconds依存)の結合で生じる「びくつき」を避けつつ、ランプ調整の効果も見える。
      let focus = effectRangeFocusSeconds(original, mode: mode)
      seekDisplaySeconds(
        focus,
        duration: max(0.001, durationSeconds),
        activeWidth: activeTimelineWidth(for: timelineScrollState.contentWidth),
        showsSnapFeedback: false
      )
    }
  }

  private func updateEffectRangeSurfaceDrag(
    selection: EditorTimelineEffectSelection,
    live: TimelineEditableRange,
    mode: EffectRangeEditMode
  ) {
    guard var session = effectRangeEditSession,
      session.matches(selection: selection)
    else { return }
    session.mode = mode
    session.live = resolvedZoomRange(live, mode: mode)
    effectRangeEditSession = session
    if live.kind == .zoom {
      // トリム中はフレーム seek を行わない（開始時の一度きり）。ライブのズーム範囲だけを
      // 更新することで、プレビューは固定フレーム上でズーム表示のまま安定する。
      previewZoomRange(live)
    }
  }

  private func finishEffectRangeSurfaceDrag(
    selection: EditorTimelineEffectSelection,
    live: TimelineEditableRange,
    mode: EffectRangeEditMode
  ) {
    guard var session = effectRangeEditSession,
      session.matches(selection: selection)
    else {
      finishEffectRangeEditSession(matching: selection)
      return
    }
    session.mode = mode
    session.live = live
    let hasChanges = session.hasLiveChanges
    let referenceStart = session.original.startSeconds
    finishEffectRangeEditSession(matching: selection)
    guard hasChanges else { return }
    commitEffectRange(
      resolvedZoomRange(live, mode: mode, moveReferenceStart: referenceStart)
    )
  }

  private func finishEffectRangeEditSession(matching selection: EditorTimelineEffectSelection? = nil) {
    guard let session = effectRangeEditSession else { return }
    if let selection {
      guard session.matches(selection: selection) else { return }
    }
    effectRangeEditSession = nil
    hidesSwiftUIEffectDuringLiveDrag = false
    if session.kind == .zoom {
      onEndPreviewZoomEffectRange()
    }
    onTrimDragEnded()
  }

  private func previewZoomRange(_ range: TimelineEditableRange) {
    // 寄り/引き（inEnd/outStart）はユーザー設定値を尊重する。トリム/移動でも上書きしない。
    onPreviewZoomEffectRange(
      range.id,
      range.startSeconds,
      range.inEndSeconds ?? range.startSeconds,
      range.outStartSeconds ?? range.endSeconds,
      range.endSeconds
    )
  }

  private func effectRangeFocusSeconds(_ range: TimelineEditableRange, mode: EffectRangeEditMode) -> Double {
    // ズームは start/end がランプ端（倍率が 1.0 へ急変する区間）。ここへ seek すると
    // プレビュー倍率が「フルズーム↔等倍」を行き来して揺れるため、倍率が一定なホールド区間
    // （寄り終わり〜引き始まり）へ寄せる。ランプ編集時もそのハンドル位置（ホールド境界）を見る。
    if range.kind == .zoom {
      let inEnd = range.inEndSeconds ?? range.startSeconds
      let outStart = range.outStartSeconds ?? range.endSeconds
      switch mode {
      case .leading, .rampIn:
        return inEnd
      case .trailing, .rampOut:
        return outStart
      case .move:
        return (range.startSeconds + range.endSeconds) / 2
      }
    }
    switch mode {
    case .leading:
      return range.startSeconds
    case .trailing:
      return range.endSeconds
    case .move, .rampIn, .rampOut:
      return (range.startSeconds + range.endSeconds) / 2
    }
  }

  private func commitEffectRange(_ range: TimelineEditableRange) {
    switch range.kind {
    case .zoom:
      // 寄り/引き（inEnd/outStart）はユーザー設定値を尊重し、固定ランプで上書きしない。
      onCommitZoomEffectRange(
        range.id,
        range.startSeconds,
        range.inEndSeconds ?? range.startSeconds,
        range.outStartSeconds ?? range.endSeconds,
        range.endSeconds
      )
    case .caption:
      onCommitCaptionEffectRange(range.id, range.startSeconds, range.endSeconds)
    case .mask:
      onCommitMaskEffectRange(range.id, range.startSeconds, range.endSeconds)
    case .camera:
      onCommitCameraEffectRange(range.id, range.startSeconds, range.endSeconds)
    case .audio:
      onCommitAudioEffectRange(range.id, range.startSeconds, range.endSeconds)
    }
  }

  private func clipReorderGesture(
    clip: RecordingProject.TimelineModel.Clip,
    clips: [RecordingProject.TimelineModel.Clip],
    duration: Double,
    activeWidth: CGFloat,
    clipX: CGFloat
  ) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        draggingClipID = clip.id
        timelineScrollState.followPlayhead = false
        let seconds = displaySeconds(forTimelineContentX: clipX + value.location.x, duration: duration, activeWidth: activeWidth)
        pendingClipDropIndex = clipDropIndex(for: seconds, clips: clips)
      }
      .onEnded { value in
        let seconds = displaySeconds(forTimelineContentX: clipX + value.location.x, duration: duration, activeWidth: activeWidth)
        let index = pendingClipDropIndex ?? clipDropIndex(for: seconds, clips: clips)
        draggingClipID = nil
        pendingClipDropIndex = nil
        onMoveClip(clip.id, index)
      }
  }

  private func clipDropIndex(for seconds: Double, clips: [RecordingProject.TimelineModel.Clip]) -> Int {
    let clamped = min(max(seconds, 0), max(0, durationSeconds))
    for (index, clip) in clips.enumerated() {
      let midpoint = clip.timelineStartSeconds + clip.durationSeconds / 2
      if clamped < midpoint {
        return index
      }
    }
    return clips.count
  }

  private func clipDropIndicator(
    index: Int,
    clips: [RecordingProject.TimelineModel.Clip],
    duration: Double,
    activeWidth: CGFloat
  ) -> some View {
    let seconds: Double
    if index <= 0 {
      seconds = 0
    } else if index >= clips.count {
      seconds = clips.map { $0.timelineStartSeconds + $0.durationSeconds }.max() ?? duration
    } else {
      seconds = clips[index].timelineStartSeconds
    }
    let x = timelineContentX(seconds, duration: duration, activeWidth: activeWidth)
    return Rectangle()
      .fill(EditorPalette.brandStrong.opacity(0.85))
      .frame(width: 2, height: EditorLayout.timelineClipLaneHeight)
      .offset(x: x)
      .accessibilityHidden(true)
  }

  private func effectLiveLayerStyle(for kind: EditorTimelineEffectSegment.Kind) -> EffectLiveLayerStyle {
    switch kind {
    case .zoom:
      return EffectLiveLayerStyle(
        barHeight: EditorLayout.timelineZoomSegmentHeight,
        barColor: NSColor(red: 0.34, green: 0.58, blue: 0.76, alpha: 1),
        accentColor: NSColor(red: 0.19, green: 0.70, blue: 0.66, alpha: 1),
        showsZoomRamps: true,
        handleWidth: EditorLayout.timelineTrimHandleWidth
      )
    case .caption:
      return EffectLiveLayerStyle(
        barHeight: EditorLayout.timelineEffectSegmentHeight,
        barColor: NSColor(red: 0.58, green: 0.50, blue: 0.70, alpha: 1),
        accentColor: NSColor(red: 0.19, green: 0.70, blue: 0.66, alpha: 1),
        showsZoomRamps: false,
        handleWidth: EditorLayout.timelineTrimHandleWidth
      )
    case .mask:
      return EffectLiveLayerStyle(
        barHeight: EditorLayout.timelineEffectSegmentHeight,
        barColor: NSColor(red: 0.62, green: 0.56, blue: 0.38, alpha: 1),
        accentColor: NSColor(red: 0.19, green: 0.70, blue: 0.66, alpha: 1),
        showsZoomRamps: false,
        handleWidth: EditorLayout.timelineTrimHandleWidth
      )
    case .camera:
      return EffectLiveLayerStyle(
        barHeight: EditorLayout.timelineClipHeight,
        barColor: NSColor(red: 0.42, green: 0.58, blue: 0.88, alpha: 1),
        accentColor: NSColor(red: 0.19, green: 0.70, blue: 0.66, alpha: 1),
        showsZoomRamps: false,
        handleWidth: EditorLayout.timelineTrimHandleWidth
      )
    case .audio:
      return EffectLiveLayerStyle(
        barHeight: EditorLayout.timelineClipHeight,
        barColor: NSColor(red: 0.35, green: 0.82, blue: 0.78, alpha: 1),
        accentColor: NSColor(red: 0.19, green: 0.70, blue: 0.66, alpha: 1),
        showsZoomRamps: false,
        handleWidth: EditorLayout.timelineTrimHandleWidth
      )
    }
  }

  private func effectSegmentColor(_ kind: EditorTimelineEffectSegment.Kind) -> Color {
    switch kind {
    case .zoom:
      return Color(red: 0.34, green: 0.58, blue: 0.76)
    case .caption:
      return Color(red: 0.58, green: 0.50, blue: 0.70)
    case .mask:
      return Color(red: 0.62, green: 0.56, blue: 0.38)
    case .camera:
      return Color(red: 0.42, green: 0.58, blue: 0.88)
    case .audio:
      return EditorPalette.brand
    }
  }

  private func effectSegmentKindLabel(_ kind: EditorTimelineEffectSegment.Kind) -> String {
    switch kind {
    case .zoom:
      return "Zoom"
    case .caption:
      return "Caption"
    case .mask:
      return "Mask"
    case .camera:
      return languageStore.localized("Camera")
    case .audio:
      return languageStore.localized("Audio")
    }
  }

  private func timelinePlayhead(x: CGFloat, laneHeight: CGFloat, width: CGFloat, duration: Double) -> some View {
    let timeLabel = editorFormatTime(currentTimelineSeconds, fractional: true)
    let labelWidth: CGFloat = EditorLayout.timelinePlayheadLabelWidth
    let playheadCenterX = min(max(0, x), max(0, width))
    let clampedX = min(
      max(0, playheadCenterX - EditorLayout.timelinePlayheadKnobWidth / 2),
      max(0, width - EditorLayout.timelinePlayheadKnobWidth)
    )
    let labelX = min(max(0, playheadCenterX - labelWidth / 2), max(0, width - labelWidth))

    return ZStack(alignment: .topLeading) {
      Text(timeLabel)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(Color.primary.opacity(0.88))
        .frame(width: labelWidth, height: 15, alignment: .center)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .offset(x: labelX, y: -15)

      VStack(spacing: 0) {
        TimelinePlayheadKnob()
          .fill(Color.primary.opacity(0.74))
          .frame(width: EditorLayout.timelinePlayheadKnobWidth, height: EditorLayout.timelinePlayheadKnobHeight)
        Rectangle()
          .fill(Color.primary.opacity(0.72))
          .frame(
            width: EditorLayout.timelinePlayheadLineWidth,
            height: max(0, laneHeight - EditorLayout.timelinePlayheadKnobHeight)
          )
      }
      .frame(width: EditorLayout.timelinePlayheadKnobWidth, height: laneHeight, alignment: .top)
      .offset(x: clampedX)
    }
    .frame(width: width, height: laneHeight, alignment: .topLeading)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("再生位置")
    .accessibilityValue(timeLabel)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        seekPlayheadAccessibility(toDisplaySeconds: currentTimelineSeconds + 1, duration: duration)
      case .decrement:
        seekPlayheadAccessibility(toDisplaySeconds: currentTimelineSeconds - 1, duration: duration)
      @unknown default:
        break
      }
    }
    .accessibilityAction(named: "開始へ移動") {
      seekPlayheadAccessibility(toDisplaySeconds: 0, duration: duration)
    }
    .accessibilityAction(named: "終了へ移動") {
      seekPlayheadAccessibility(toDisplaySeconds: duration, duration: duration)
    }
  }

  private var playPauseButton: some View {
    Button(action: onTogglePlayback) {
      Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: EditorLayout.timelineHeaderControlSize, height: EditorLayout.timelineHeaderControlSize)
        .contentShape(RoundedRectangle(cornerRadius: EditorLayout.timelineRowCornerRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.white.opacity(0.92))
    .background(
      EditorPalette.brandStrong.opacity(0.72),
      in: RoundedRectangle(cornerRadius: EditorLayout.timelineRowCornerRadius, style: .continuous)
    )
    .help(languageStore.localized(isPlaying ? "一時停止" : "再生"))
    .accessibilityLabel(languageStore.localized(isPlaying ? "一時停止" : "再生"))
  }

  private func trimTimeLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold, design: .monospaced))
      .monospacedDigit()
      .foregroundStyle(Color.primary.opacity(0.80))
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .allowsHitTesting(false)
  }

  private func timelineStaticBadge(_ text: String) -> some View {
    Text(languageStore.localized(text))
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(Color.primary.opacity(0.52))
      .lineLimit(1)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .accessibilityLabel(text)
  }

  private func timelineHeaderGroup<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: EditorLayout.timelineHeaderGroupGap) {
      content()
    }
    .frame(height: EditorLayout.timelineHeaderContentHeight, alignment: .center)
  }

  private func timelineHeaderButton(
    _ title: String,
    systemImage: String,
    destructive: Bool = false,
    disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    let role: ButtonRole? = destructive ? .destructive : nil
    return Button(role: role, action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .frame(width: EditorLayout.timelineHeaderControlSize, height: EditorLayout.timelineHeaderControlSize)
        .contentShape(RoundedRectangle(cornerRadius: EditorLayout.timelineRowCornerRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(timelineHeaderButtonColor(destructive: destructive, disabled: disabled))
    .disabled(disabled)
    .help(languageStore.localized(title))
    .accessibilityLabel(languageStore.localized(title))
  }

  private func timelineHeaderButtonColor(destructive: Bool, disabled: Bool) -> Color {
    if destructive {
      return Color.red.opacity(disabled ? 0.30 : 0.82)
    }
    return Color.primary.opacity(disabled ? 0.30 : 0.78)
  }

  private func timelineClipBlock(
    clip: RecordingProject.TimelineModel.Clip,
    duration: Double,
    width: CGFloat
  ) -> some View {
    let displayRange = project.timeline.displayRange(for: clip, mode: .timeline)
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: duration,
      previewDurationSeconds: duration,
      timelineDurationSeconds: duration,
      width: width
    )
    let clipWidth = space.timelineSpanWidth(
      startSeconds: 0,
      endSeconds: displayRange.durationSeconds,
      minimumWidth: EditorLayout.timelineMinimumClipWidth
    )
    let isSelected = selectedClipID == clip.id
    let rate = project.timeline.speedRate(
      forTimelineRangeStart: clip.timelineStartSeconds,
      end: clip.timelineStartSeconds + clip.durationSeconds
    )
    let clipSpeedText = timelineRateText(rate)

    return Button {
      selectedClipID = clip.id
      selectedEffect = nil
      isFullRecordingSelected = false
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(EditorPalette.clip.opacity(isSelected ? 0.90 : 0.80))

        clipFrameMarkers()
          .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

        HStack(spacing: 6) {
          Text(languageStore.localizedFormat("Screen %@", editorFormatTime(clip.durationSeconds, fractional: true)))
          if abs(rate - 1) > 1e-9 {
            Text(timelineRateText(rate, maxFractionDigits: 1))
          }
          Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.black.opacity(0.60))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: clipWidth, height: EditorLayout.timelineClipHeight)
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(isSelected ? EditorPalette.brandStrong : Color.black.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("クリップ")
    .accessibilityValue(languageStore.localizedFormat(
      "%@ to %@, speed %@",
      editorFormatTime(clip.timelineStartSeconds, fractional: true),
      editorFormatTime(clip.timelineStartSeconds + clip.durationSeconds, fractional: true),
      clipSpeedText
    ))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction(named: "前へ移動") {
      if let index = project.timeline.activeClips.firstIndex(where: { $0.id == clip.id }) {
        onMoveClip(clip.id, max(0, index - 1))
      }
    }
    .accessibilityAction(named: "後ろへ移動") {
      if let index = project.timeline.activeClips.firstIndex(where: { $0.id == clip.id }) {
        onMoveClip(clip.id, min(project.timeline.activeClips.count - 1, index + 1))
      }
    }
  }

  private func singleClipBlock(width: CGFloat) -> some View {
    Button {
      selectedClipID = nil
      selectedEffect = nil
      isFullRecordingSelected = true
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(EditorPalette.clip.opacity(isFullRecordingSelected ? 0.88 : 0.80))

        clipFrameMarkers()
          .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

        if width > 52 {
          HStack {
            Text(languageStore.localizedFormat("Full recording %@", editorFormatTime(max(0, durationSeconds), fractional: true)))
            Spacer(minLength: 0)
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Color.black.opacity(0.60))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .padding(.leading, EditorLayout.timelineClipTextLeadingPadding)
          .padding(.trailing, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(width: width, height: EditorLayout.timelineClipHeight)
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(
            isFullRecordingSelected ? EditorPalette.brandStrong : Color.black.opacity(0.10),
            lineWidth: isFullRecordingSelected ? 1.5 : 1
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("フル録画")
    .accessibilityValue(languageStore.localizedFormat(
      "%@ to %@",
      editorFormatTime(displayedTrimStartSeconds, fractional: true),
      editorFormatTime(displayedTrimEndSeconds, fractional: true)
    ))
    .accessibilityAddTraits(isFullRecordingSelected ? .isSelected : [])
  }

  private func clipFrameMarkers() -> some View {
    Canvas { context, size in
      let step = max(32, min(72, size.width / 8))
      var x = step
      while x < size.width {
        let rect = CGRect(x: x, y: 6, width: 1, height: max(1, size.height - 12))
        context.fill(Path(rect), with: .color(Color.black.opacity(0.06)))
        x += step
      }
    }
    .allowsHitTesting(false)
  }

  private func trimHandle(isLeading: Bool) -> some View {
    let isHovering = isLeading ? isHoveringLeadingTrim : isHoveringTrailingTrim
    return ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.white.opacity(isHovering ? 0.74 : 0.56))
        .frame(width: EditorLayout.timelineTrimHandleWidth, height: EditorLayout.timelineTrimHandleHeight)
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(isHovering ? EditorPalette.brandStrong.opacity(0.90) : Color.black.opacity(0.10), lineWidth: isHovering ? 1.5 : 1)
        }
        .overlay {
          HStack(spacing: 2) {
            Rectangle().fill(Color.black.opacity(0.18)).frame(width: 1, height: 14)
            Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1, height: 14)
          }
        }
      }
      .frame(width: EditorLayout.timelineTrimHandleHitWidth, height: EditorLayout.timelineTrimHandleHeight)
      .contentShape(Rectangle())
      .accessibilityLabel(isLeading ? "開始トリムハンドル" : "終了トリムハンドル")
      .accessibilityValue(editorFormatTime(isLeading ? displayedTrimStartSeconds : displayedTrimEndSeconds, fractional: true))
  }

  private func rulerMinorStep(for duration: Double) -> Double {
    if duration <= 3 { return 0.1 }
    if duration <= 8 { return 0.5 }
    if duration <= 15 { return 1 }
    if duration <= 60 { return 5 }
    if duration <= 300 { return 10 }
    if duration <= 1_800 { return 60 }
    return 300
  }

  private func rulerMajorStep(for duration: Double) -> Double {
    if duration <= 3 { return 0.5 }
    if duration <= 8 { return 1 }
    if duration <= 30 { return 5 }
    if duration <= 120 { return 10 }
    if duration <= 600 { return 60 }
    return 300
  }

  private func rulerShowsFraction(for duration: Double) -> Bool {
    duration <= 8
  }
}

private struct GeneratedTimelineThumbnailImage: @unchecked Sendable {
  var seconds: Double
  var image: CGImage
}

struct TimelinePlayheadKnob: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

enum EditorTimelineActiveTrimHandle: Equatable {
  case leading
  case trailing
}

private struct EditorTimelineChromeModifier: ViewModifier {
  var usesStandaloneChrome: Bool

  func body(content: Content) -> some View {
    if usesStandaloneChrome {
      content
        .padding(.horizontal, EditorLayout.timelineCardHorizontalPadding)
        .padding(.top, EditorLayout.timelineCardTopPadding)
        .padding(.bottom, EditorLayout.timelineCardBottomPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: EditorLayout.panelCornerRadius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: EditorLayout.panelCornerRadius, style: .continuous)
            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    } else {
      content
        .padding(.horizontal, EditorLayout.timelineCardHorizontalPadding)
        .padding(.top, EditorLayout.timelineCardTopPadding / 2)
        .padding(.bottom, EditorLayout.timelineCardBottomPadding)
    }
  }
}
