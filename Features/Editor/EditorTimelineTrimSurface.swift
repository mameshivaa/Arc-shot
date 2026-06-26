import SwiftUI
import AppKit

struct TimelineScrollContainer<Content: View>: NSViewRepresentable {
  @Binding var scrollState: TimelineScrollState
  var targetOffsetX: CGFloat?
  var contentWidth: CGFloat
  var visibleWidth: CGFloat
  var contentHeight: CGFloat
  var content: () -> Content

  func makeCoordinator() -> Coordinator {
    Coordinator(scrollState: $scrollState)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.scrollerStyle = .overlay
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.documentView = context.coordinator.hostingView
    context.coordinator.hostingView.rootView = content().eraseToAnyView()
    context.coordinator.hostingView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    context.coordinator.observe(scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.scrollState = $scrollState
    context.coordinator.hostingView.rootView = content().eraseToAnyView()
    context.coordinator.hostingView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    scrollView.documentView = context.coordinator.hostingView

    let maxOffset = max(0, contentWidth - visibleWidth)
    let currentOffset = scrollView.contentView.bounds.origin.x
    let desiredOffset = (targetOffsetX ?? scrollState.contentOffsetX).clamped(to: 0...maxOffset)
    if abs(currentOffset - desiredOffset) > 0.5 {
      context.coordinator.isProgrammaticScroll = true
      scrollView.contentView.scroll(to: CGPoint(x: desiredOffset, y: 0))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      context.coordinator.isProgrammaticScroll = false
    }

    context.coordinator.publish(
      offsetX: scrollView.contentView.bounds.origin.x,
      visibleWidth: visibleWidth,
      contentWidth: contentWidth,
      isUserScrolling: scrollState.isUserScrolling,
      followPlayhead: scrollState.followPlayhead
    )
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.stopObserving()
  }

  @MainActor
  final class Coordinator: NSObject, @unchecked Sendable {
    var scrollState: Binding<TimelineScrollState>
    let hostingView: NSHostingView<AnyView>
    var isProgrammaticScroll = false
    private var observer: NSObjectProtocol?
    private var userScrollResetWorkItem: DispatchWorkItem?

    init(scrollState: Binding<TimelineScrollState>) {
      self.scrollState = scrollState
      self.hostingView = NSHostingView(rootView: EmptyView().eraseToAnyView())
    }

    func observe(_ scrollView: NSScrollView) {
      stopObserving()
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self, weak scrollView] _ in
        Task { @MainActor in
          guard let self, let scrollView else { return }
          let didUserScroll = !self.isProgrammaticScroll
          self.publish(
            offsetX: scrollView.contentView.bounds.origin.x,
            visibleWidth: scrollView.contentSize.width,
            contentWidth: scrollView.documentView?.bounds.width ?? scrollView.contentSize.width,
            isUserScrolling: didUserScroll || self.scrollState.wrappedValue.isUserScrolling,
            followPlayhead: didUserScroll ? false : self.scrollState.wrappedValue.followPlayhead
          )
          if didUserScroll {
            self.scheduleUserScrollReset()
          }
        }
      }
    }

    func stopObserving() {
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      observer = nil
      userScrollResetWorkItem?.cancel()
      userScrollResetWorkItem = nil
    }

    func publish(
      offsetX: CGFloat,
      visibleWidth: CGFloat,
      contentWidth: CGFloat,
      isUserScrolling: Bool,
      followPlayhead: Bool
    ) {
      let next = TimelineScrollState(
        contentOffsetX: offsetX,
        visibleWidth: visibleWidth,
        contentWidth: contentWidth,
        isUserScrolling: isUserScrolling,
        followPlayhead: followPlayhead
      )
      guard next != scrollState.wrappedValue else { return }
      DispatchQueue.main.async { [weak self] in
        self?.scrollState.wrappedValue = next
      }
    }

    private func scheduleUserScrollReset() {
      userScrollResetWorkItem?.cancel()
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        var state = self.scrollState.wrappedValue
        state.isUserScrolling = false
        self.scrollState.wrappedValue = state
      }
      userScrollResetWorkItem = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }
  }
}

struct EditorTimelineLiveTrimLayerSurface: NSViewRepresentable {
  var startSeconds: Double
  var endSeconds: Double
  var assetDurationSeconds: Double
  var minDurationSeconds: Double
  var timelineWidth: CGFloat
  var barHeight: CGFloat
  var handleWidth: CGFloat
  var hitWidth: CGFloat
  var snapEnabled: Bool
  var snapTargetsSeconds: [Double]
  var snapThresholdSeconds: Double
  var onHoverLeading: (Bool) -> Void
  var onHoverTrailing: (Bool) -> Void
  var onDragBegan: (EditorTimelineActiveTrimHandle, Double, Double) -> Void
  var onDragEnded: (EditorTimelineActiveTrimHandle, Double, Double, @escaping () -> Void) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.onHoverLeading = onHoverLeading
    nsView.onHoverTrailing = onHoverTrailing
    nsView.onDragBegan = onDragBegan
    nsView.onDragEnded = onDragEnded

    guard !nsView.isDraggingTrim else { return }

    nsView.assetDurationSeconds = max(assetDurationSeconds, 0.001)
    nsView.minDurationSeconds = max(minDurationSeconds, 0.001)
    nsView.timelineWidth = max(timelineWidth, 1)
    nsView.barHeight = barHeight
    nsView.handleWidth = handleWidth
    nsView.hitWidth = max(hitWidth, handleWidth)
    nsView.snapEnabled = snapEnabled
    nsView.snapTargetsSeconds = snapTargetsSeconds
    nsView.snapThresholdSeconds = max(0, snapThresholdSeconds)
    nsView.startSeconds = startSeconds
    nsView.endSeconds = endSeconds
    nsView.syncLayersToModel()
  }

  final class TrackingView: NSView {
    var startSeconds: Double = 0
    var endSeconds: Double = 0
    var assetDurationSeconds: Double = 1
    var minDurationSeconds: Double = 0.1
    var timelineWidth: CGFloat = 1
    var barHeight: CGFloat = 32
    var handleWidth: CGFloat = 12
    var hitWidth: CGFloat = 32
    var snapEnabled = false
    var snapTargetsSeconds: [Double] = []
    var snapThresholdSeconds: Double = 0
    var onHoverLeading: (Bool) -> Void = { _ in }
    var onHoverTrailing: (Bool) -> Void = { _ in }
    var onDragBegan: (EditorTimelineActiveTrimHandle, Double, Double) -> Void = { _, _, _ in }
    var onDragEnded: (EditorTimelineActiveTrimHandle, Double, Double, @escaping () -> Void) -> Void = { _, _, _, completion in
      completion()
    }

    private let clipCoverLayer = CALayer()
    private let clipLayer = CALayer()
    private let livePlayheadLayer = CALayer()
    private let leadingLayer = CALayer()
    private let trailingLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var activeHandle: EditorTimelineActiveTrimHandle?
    private var dragStartSeconds: Double = 0
    private var dragEndSeconds: Double = 0
    private var liveStartSeconds: Double = 0
    private var liveEndSeconds: Double = 0
    private var dragGrabOffsetX: CGFloat = 0
    private var frozenDragWidth: CGFloat = 1
    private var frozenDragDurationSeconds: Double = 1
    private var didSetupLayers = false

    var isDraggingTrim: Bool {
      activeHandle != nil
    }

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      setupLayers()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      wantsLayer = true
      setupLayers()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
      true
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea {
        removeTrackingArea(trackingArea)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      trackingArea = area
      addTrackingArea(area)
    }

    override func resetCursorRects() {
      super.resetCursorRects()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      if activeHandle != nil || handle(at: point) != nil {
        return self
      }
      return nil
    }

    override func mouseMoved(with event: NSEvent) {
      updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
      if activeHandle == nil {
        onHoverLeading(false)
        onHoverTrailing(false)
        NSCursor.arrow.set()
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      guard let handle = handle(at: convert(event.locationInWindow, from: nil)) else { return }
      activeHandle = handle
      dragStartSeconds = startSeconds
      dragEndSeconds = endSeconds
      liveStartSeconds = startSeconds
      liveEndSeconds = endSeconds
      frozenDragWidth = effectiveTimelineWidth
      frozenDragDurationSeconds = max(assetDurationSeconds, 0.001)
      let grabbedBoundaryX: CGFloat
      switch handle {
      case .leading:
        grabbedBoundaryX = x(for: startSeconds)
      case .trailing:
        grabbedBoundaryX = x(for: endSeconds)
      }
      dragGrabOffsetX = convert(event.locationInWindow, from: nil).x - grabbedBoundaryX
      NSCursor.resizeLeftRight.set()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      setLiveLayersHidden(false)
      applyLayerFrames(start: startSeconds, end: endSeconds)
      CATransaction.commit()
      onDragBegan(handle, startSeconds, endSeconds)
    }

    override func mouseDragged(with event: NSEvent) {
      guard let activeHandle else { return }
      let point = convert(event.locationInWindow, from: nil)
      let boundaryX = min(max(0, point.x - dragGrabOffsetX), frozenDragWidth)
      let boundarySeconds = coordinateSpace(
        width: frozenDragWidth,
        durationSeconds: frozenDragDurationSeconds
      )
      .sourceSeconds(forX: boundaryX)
      let nextStart: Double
      let nextEnd: Double

      switch activeHandle {
      case .leading:
        let validRange = 0...max(0, dragEndSeconds - minDurationSeconds)
        nextStart = adjustedBoundarySeconds(boundarySeconds, validRange: validRange)
        nextEnd = dragEndSeconds
      case .trailing:
        nextStart = dragStartSeconds
        let validRange = min(frozenDragDurationSeconds, dragStartSeconds + minDurationSeconds)...frozenDragDurationSeconds
        nextEnd = adjustedBoundarySeconds(boundarySeconds, validRange: validRange)
      }

      liveStartSeconds = nextStart
      liveEndSeconds = nextEnd
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyLayerFrames(start: nextStart, end: nextEnd)
      CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
      guard let activeHandle else { return }
      let finalStart = liveStartSeconds
      let finalEnd = liveEndSeconds
      let mouseUpLocation = event.locationInWindow
      onDragEnded(activeHandle, finalStart, finalEnd) { [weak self] in
        guard let self else { return }
        self.activeHandle = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.setLiveLayersHidden(true)
        CATransaction.commit()
        self.updateHover(at: self.convert(mouseUpLocation, from: nil))
      }
    }

    override func layout() {
      super.layout()
      let frameStart = isDraggingTrim ? liveStartSeconds : startSeconds
      let frameEnd = isDraggingTrim ? liveEndSeconds : endSeconds
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyLayerFrames(start: frameStart, end: frameEnd)
      CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateTrackingAreas()
    }

    func syncLayersToModel() {
      guard activeHandle == nil else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyLayerFrames(start: startSeconds, end: endSeconds)
      CATransaction.commit()
      setLiveLayersHidden(true)
    }

    private func setupLayers() {
      guard !didSetupLayers, let root = layer else { return }
      didSetupLayers = true
      root.backgroundColor = NSColor.clear.cgColor

      clipCoverLayer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
      clipCoverLayer.cornerRadius = 8
      clipCoverLayer.masksToBounds = true

      clipLayer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.78).cgColor
      clipLayer.cornerRadius = 7
      clipLayer.masksToBounds = true

      livePlayheadLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
      livePlayheadLayer.cornerRadius = 1
      livePlayheadLayer.masksToBounds = true

      [leadingLayer, trailingLayer].forEach { layer in
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        layer.borderColor = NSColor.systemTeal.cgColor
        layer.borderWidth = 1.5
        layer.cornerRadius = 4
        layer.masksToBounds = true
      }

      root.addSublayer(clipCoverLayer)
      root.addSublayer(clipLayer)
      root.addSublayer(livePlayheadLayer)
      root.addSublayer(leadingLayer)
      root.addSublayer(trailingLayer)
      setLiveLayersHidden(true)
    }

    private func setLiveLayersHidden(_ isHidden: Bool) {
      clipCoverLayer.isHidden = isHidden
      clipLayer.isHidden = isHidden
      livePlayheadLayer.isHidden = isHidden
      leadingLayer.isHidden = isHidden
      trailingLayer.isHidden = isHidden
    }

    private func handle(at point: CGPoint) -> EditorTimelineActiveTrimHandle? {
      let currentStart = isDraggingTrim ? liveStartSeconds : startSeconds
      let currentEnd = isDraggingTrim ? liveEndSeconds : endSeconds
      let leadingDistance = abs(point.x - x(for: currentStart))
      let trailingDistance = abs(point.x - x(for: currentEnd))
      let threshold = hitWidth / 2
      if leadingDistance <= threshold, leadingDistance <= trailingDistance {
        return .leading
      }
      if trailingDistance <= threshold {
        return .trailing
      }
      return nil
    }

    private func updateHover(at point: CGPoint) {
      let hoveringLeading = handle(at: point) == .leading
      let hoveringTrailing = handle(at: point) == .trailing
      onHoverLeading(hoveringLeading)
      onHoverTrailing(hoveringTrailing)
      if hoveringLeading || hoveringTrailing {
        NSCursor.resizeLeftRight.set()
      } else {
        NSCursor.arrow.set()
      }
    }

    private func x(for seconds: Double) -> CGFloat {
      let width = isDraggingTrim ? max(frozenDragWidth, 1) : effectiveTimelineWidth
      let duration = isDraggingTrim ? max(frozenDragDurationSeconds, 0.001) : max(assetDurationSeconds, 0.001)
      return coordinateSpace(width: width, durationSeconds: duration).sourceX(for: seconds)
    }

    private var effectiveTimelineWidth: CGFloat {
      max(bounds.width, timelineWidth, 1)
    }

    private func coordinateSpace(width: CGFloat, durationSeconds: Double) -> TimelineCoordinateSpace {
      let duration = max(durationSeconds, 0.001)
      return TimelineCoordinateSpace(
        sourceDurationSeconds: duration,
        previewDurationSeconds: duration,
        timelineDurationSeconds: duration,
        width: max(width, 1)
      )
    }

    private func adjustedBoundarySeconds(_ seconds: Double, validRange: ClosedRange<Double>) -> Double {
      let clamped = seconds.clamped(to: validRange)
      let policy = TimelineSnapPolicy(
        enabled: snapEnabled,
        targets: snapTargetsSeconds.map { TimelineSnapTarget(seconds: $0) },
        thresholdSeconds: snapThresholdSeconds,
        validRange: validRange
      )
      return policy.snappedSeconds(for: clamped).clamped(to: validRange)
    }

    private func applyLayerFrames(start: Double, end: Double) {
      let startX = x(for: start)
      let endX = x(for: end)
      let y = max(0, (bounds.height - barHeight) / 2)
      let clipWidth = max(1, endX - startX)
      clipCoverLayer.frame = CGRect(
        x: 0,
        y: y - 3,
        width: effectiveTimelineWidth,
        height: barHeight + 6
      )
      clipLayer.frame = CGRect(
        x: startX,
        y: y,
        width: clipWidth,
        height: barHeight
      )
      leadingLayer.frame = CGRect(
        x: startX - handleWidth / 2,
        y: y - 2,
        width: handleWidth,
        height: barHeight + 4
      )
      trailingLayer.frame = CGRect(
        x: endX - handleWidth / 2,
        y: y - 2,
        width: handleWidth,
        height: barHeight + 4
      )
      let playheadX: CGFloat
      switch activeHandle {
      case .leading:
        playheadX = startX
      case .trailing:
        playheadX = endX
      case nil:
        playheadX = startX
      }
      livePlayheadLayer.frame = CGRect(
        x: playheadX - EditorLayout.timelinePlayheadLineWidth / 2,
        y: 0,
        width: EditorLayout.timelinePlayheadLineWidth,
        height: bounds.height
      )
    }
  }
}

struct EffectLiveLayerStyle: Equatable {
  var barHeight: CGFloat
  var barColor: NSColor
  var accentColor: NSColor
  var showsZoomRamps: Bool
  var handleWidth: CGFloat
}

struct EditorTimelineEffectRangeInteractionSurface: NSViewRepresentable {
  var range: TimelineEditableRange
  var timelineDurationSeconds: Double
  var totalDurationSeconds: Double
  var timelineWidth: CGFloat
  var edgeHitWidth: CGFloat
  var liveLayerStyle: EffectLiveLayerStyle
  var peerZoomIntervals: [TimelineZoomOverlapPolicy.Interval]
  var onDragBegan: (TimelineEditableRange, EffectRangeEditMode) -> Void
  var onDragChanged: (TimelineEditableRange, EffectRangeEditMode) -> Void
  var onDragEnded: (TimelineEditableRange, EffectRangeEditMode) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.onDragBegan = onDragBegan
    nsView.onDragChanged = onDragChanged
    nsView.onDragEnded = onDragEnded
    guard !nsView.isDraggingEffectRange else { return }
    nsView.range = range
    nsView.timelineDurationSeconds = max(timelineDurationSeconds, 0.001)
    nsView.totalDurationSeconds = max(totalDurationSeconds, 0.001)
    nsView.timelineWidth = max(timelineWidth, 1)
    nsView.edgeHitWidth = max(edgeHitWidth, 1)
    nsView.liveLayerStyle = liveLayerStyle
    nsView.peerZoomIntervals = peerZoomIntervals
    nsView.syncLayersToModel()
  }

  final class TrackingView: NSView {
    var range = TimelineEditableRange(
      id: UUID(),
      kind: .zoom,
      startSeconds: 0,
      endSeconds: 1,
      minDuration: 0.1,
      canTrim: true,
      canMove: true
    )
    var timelineDurationSeconds: Double = 1
    var totalDurationSeconds: Double = 1
    var timelineWidth: CGFloat = 1
    var edgeHitWidth: CGFloat = 24
    var liveLayerStyle = EffectLiveLayerStyle(
      barHeight: 24,
      barColor: .systemBlue,
      accentColor: .systemTeal,
      showsZoomRamps: false,
      handleWidth: 12
    )
    var peerZoomIntervals: [TimelineZoomOverlapPolicy.Interval] = []
    var onDragBegan: (TimelineEditableRange, EffectRangeEditMode) -> Void = { _, _ in }
    var onDragChanged: (TimelineEditableRange, EffectRangeEditMode) -> Void = { _, _ in }
    var onDragEnded: (TimelineEditableRange, EffectRangeEditMode) -> Void = { _, _ in }

    private let barContainerLayer = CALayer()
    private let rampInLayer = CALayer()
    private let holdLayer = CALayer()
    private let rampOutLayer = CALayer()
    private let borderLayer = CALayer()
    private let leadingHandleLayer = CALayer()
    private let trailingHandleLayer = CALayer()
    private let rampInHandleLayer = CALayer()
    private let rampOutHandleLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var activeMode: EffectRangeEditMode?
    private var dragStartRange: TimelineEditableRange?
    private var dragStartX: CGFloat = 0
    private var dragGrabOffsetX: CGFloat = 0
    private var liveRange: TimelineEditableRange?
    private var frozenDragWidth: CGFloat = 1
    private var frozenDragDurationSeconds: Double = 1
    private var didSetupLayers = false

    var isDraggingEffectRange: Bool {
      activeMode != nil
    }

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      wantsLayer = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
      true
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea {
        removeTrackingArea(trackingArea)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      trackingArea = area
      addTrackingArea(area)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      if activeMode != nil || mode(at: point) != nil {
        return self
      }
      return nil
    }

    override func mouseMoved(with event: NSEvent) {
      updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
      if activeMode == nil {
        NSCursor.arrow.set()
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let point = convert(event.locationInWindow, from: nil)
      guard let mode = mode(at: point) else { return }
      let currentRange = range.sanitized(durationSeconds: totalDurationSeconds)
      activeMode = mode
      dragStartRange = currentRange
      dragStartX = point.x
      liveRange = currentRange
      frozenDragWidth = effectiveTimelineWidth
      frozenDragDurationSeconds = max(timelineDurationSeconds, 0.001)
      switch mode {
      case .leading:
        dragGrabOffsetX = point.x - x(for: currentRange.startSeconds)
      case .trailing:
        dragGrabOffsetX = point.x - x(for: currentRange.endSeconds)
      case .rampIn:
        dragGrabOffsetX = point.x - x(for: currentRange.inEndSeconds ?? currentRange.startSeconds)
      case .rampOut:
        dragGrabOffsetX = point.x - x(for: currentRange.outStartSeconds ?? currentRange.endSeconds)
      case .move:
        dragGrabOffsetX = 0
      }
      updateCursor(for: mode)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      setLiveLayersHidden(false)
      applyLayerFrames(range: currentRange)
      CATransaction.commit()
      onDragBegan(currentRange, mode)
    }

    override func mouseDragged(with event: NSEvent) {
      guard let mode = activeMode,
        let dragStartRange
      else { return }
      let point = convert(event.locationInWindow, from: nil)
      var nextRange: TimelineEditableRange
      switch mode {
      case .leading:
        nextRange = dragStartRange.trimmingLeading(
          to: seconds(forX: point.x - dragGrabOffsetX),
          durationSeconds: totalDurationSeconds
        )
      case .trailing:
        nextRange = dragStartRange.trimmingTrailing(
          to: seconds(forX: point.x - dragGrabOffsetX),
          durationSeconds: totalDurationSeconds
        )
      case .move:
        let deltaSeconds = Double((point.x - dragStartX) / frozenDragWidth) * frozenDragDurationSeconds
        nextRange = dragStartRange.moving(by: deltaSeconds, durationSeconds: totalDurationSeconds)
      case .rampIn:
        nextRange = dragStartRange.movingInEnd(
          to: seconds(forX: point.x - dragGrabOffsetX),
          durationSeconds: totalDurationSeconds
        )
      case .rampOut:
        nextRange = dragStartRange.movingOutStart(
          to: seconds(forX: point.x - dragGrabOffsetX),
          durationSeconds: totalDurationSeconds
        )
      }
      liveRange = nextRange
      if nextRange.kind == .zoom {
        nextRange = TimelineZoomOverlapPolicy.resolve(
          nextRange,
          mode: mode,
          peers: peerZoomIntervals,
          totalDuration: totalDurationSeconds,
          moveReferenceStart: dragStartRange.startSeconds
        )
        liveRange = nextRange
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyLayerFrames(range: nextRange)
      CATransaction.commit()
      onDragChanged(nextRange, mode)
    }

    override func mouseUp(with event: NSEvent) {
      guard let mode = activeMode else { return }
      let finalRange = liveRange ?? dragStartRange ?? range
      activeMode = nil
      dragStartRange = nil
      liveRange = nil
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      setLiveLayersHidden(true)
      CATransaction.commit()
      onDragEnded(finalRange, mode)
      updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func layout() {
      super.layout()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyLayerFrames(range: (liveRange ?? range).sanitized(durationSeconds: totalDurationSeconds))
      CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateTrackingAreas()
    }

    func syncLayersToModel() {
      guard !isDraggingEffectRange else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyLayerFrames(range: range.sanitized(durationSeconds: totalDurationSeconds))
      CATransaction.commit()
    }

    private func setupLayersIfNeeded() {
      guard !didSetupLayers, let root = layer else { return }
      didSetupLayers = true
      root.backgroundColor = NSColor.clear.cgColor

      barContainerLayer.cornerRadius = 7
      barContainerLayer.masksToBounds = true

      borderLayer.borderWidth = 1.5
      borderLayer.cornerRadius = 7
      borderLayer.masksToBounds = true

      [leadingHandleLayer, trailingHandleLayer, rampInHandleLayer, rampOutHandleLayer].forEach { layer in
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer.borderColor = liveLayerStyle.accentColor.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 3
        layer.masksToBounds = true
      }

      root.addSublayer(barContainerLayer)
      barContainerLayer.addSublayer(rampInLayer)
      barContainerLayer.addSublayer(holdLayer)
      barContainerLayer.addSublayer(rampOutLayer)
      root.addSublayer(borderLayer)
      root.addSublayer(leadingHandleLayer)
      root.addSublayer(trailingHandleLayer)
      root.addSublayer(rampInHandleLayer)
      root.addSublayer(rampOutHandleLayer)
      setLiveLayersHidden(true)
    }

    private func setLiveLayersHidden(_ isHidden: Bool) {
      setupLayersIfNeeded()
      [barContainerLayer, borderLayer, leadingHandleLayer, trailingHandleLayer, rampInHandleLayer, rampOutHandleLayer]
        .forEach { $0.isHidden = isHidden }
    }

    private func applyLayerFrames(range: TimelineEditableRange) {
      setupLayersIfNeeded()
      let startX = x(for: range.startSeconds)
      let endX = x(for: range.endSeconds)
      let y = max(0, (bounds.height - liveLayerStyle.barHeight) / 2)
      let barWidth = max(1, endX - startX)
      let barRect = CGRect(x: startX, y: y, width: barWidth, height: liveLayerStyle.barHeight)

      barContainerLayer.frame = barRect
      borderLayer.frame = barRect
      borderLayer.backgroundColor = NSColor.clear.cgColor
      borderLayer.borderColor = liveLayerStyle.accentColor.cgColor

      if liveLayerStyle.showsZoomRamps {
        let inEnd = min(max(range.inEndSeconds ?? range.startSeconds, range.startSeconds), range.endSeconds)
        let outStart = min(max(range.outStartSeconds ?? range.endSeconds, inEnd), range.endSeconds)
        let inEndX = x(for: inEnd)
        let outStartX = x(for: outStart)
        rampInLayer.frame = CGRect(x: 0, y: 0, width: max(0, inEndX - startX), height: liveLayerStyle.barHeight)
        rampInLayer.backgroundColor = liveLayerStyle.barColor.withAlphaComponent(0.42).cgColor
        holdLayer.frame = CGRect(
          x: max(0, inEndX - startX),
          y: 0,
          width: max(0, outStartX - inEndX),
          height: liveLayerStyle.barHeight
        )
        holdLayer.backgroundColor = liveLayerStyle.barColor.withAlphaComponent(0.92).cgColor
        rampOutLayer.frame = CGRect(
          x: max(0, outStartX - startX),
          y: 0,
          width: max(0, endX - outStartX),
          height: liveLayerStyle.barHeight
        )
        rampOutLayer.backgroundColor = liveLayerStyle.barColor.withAlphaComponent(0.42).cgColor
        rampInHandleLayer.isHidden = barContainerLayer.isHidden
        rampOutHandleLayer.isHidden = barContainerLayer.isHidden
        placeHandle(rampInHandleLayer, at: inEndX, y: y)
        placeHandle(rampOutHandleLayer, at: outStartX, y: y)
      } else {
        rampInLayer.frame = CGRect(x: 0, y: 0, width: barWidth, height: liveLayerStyle.barHeight)
        rampInLayer.backgroundColor = liveLayerStyle.barColor.withAlphaComponent(0.82).cgColor
        holdLayer.frame = .zero
        rampOutLayer.frame = .zero
        rampInHandleLayer.isHidden = true
        rampOutHandleLayer.isHidden = true
      }

      leadingHandleLayer.isHidden = barContainerLayer.isHidden
      trailingHandleLayer.isHidden = barContainerLayer.isHidden
      placeHandle(leadingHandleLayer, at: startX, y: y)
      placeHandle(trailingHandleLayer, at: endX, y: y)
    }

    private func placeHandle(_ layer: CALayer, at centerX: CGFloat, y: CGFloat) {
      let handleWidth = liveLayerStyle.handleWidth
      let handleHeight = max(8, liveLayerStyle.barHeight - 8)
      layer.frame = CGRect(
        x: centerX - handleWidth / 2,
        y: y + (liveLayerStyle.barHeight - handleHeight) / 2,
        width: handleWidth,
        height: handleHeight
      )
    }

    private func mode(at point: CGPoint) -> EffectRangeEditMode? {
      let currentRange = (liveRange ?? range).sanitized(durationSeconds: totalDurationSeconds)
      let startX = x(for: currentRange.startSeconds)
      let endX = x(for: currentRange.endSeconds)
      let leadingDistance = abs(point.x - startX)
      let trailingDistance = abs(point.x - endX)
      let threshold = edgeHitWidth / 2
      if leadingDistance <= threshold, leadingDistance <= trailingDistance {
        return .leading
      }
      if trailingDistance <= threshold {
        return .trailing
      }
      if let inEnd = currentRange.inEndSeconds {
        let inEndX = x(for: inEnd)
        if abs(point.x - inEndX) <= threshold {
          return .rampIn
        }
      }
      if let outStart = currentRange.outStartSeconds {
        let outStartX = x(for: outStart)
        if abs(point.x - outStartX) <= threshold {
          return .rampOut
        }
      }
      if point.x >= min(startX, endX), point.x <= max(startX, endX) {
        return .move
      }
      return nil
    }

    private func updateCursor(at point: CGPoint) {
      guard let mode = mode(at: point) else {
        NSCursor.arrow.set()
        return
      }
      updateCursor(for: mode)
    }

    private func updateCursor(for mode: EffectRangeEditMode) {
      switch mode {
      case .leading, .trailing, .rampIn, .rampOut:
        NSCursor.resizeLeftRight.set()
      case .move:
        NSCursor.openHand.set()
      }
    }

    private func x(for seconds: Double) -> CGFloat {
      let width = isDraggingEffectRange ? frozenDragWidth : effectiveTimelineWidth
      let duration = isDraggingEffectRange ? frozenDragDurationSeconds : timelineDurationSeconds
      return coordinateSpace(width: width, durationSeconds: duration).timelineX(for: seconds)
    }

    private func seconds(forX x: CGFloat) -> Double {
      let width = isDraggingEffectRange ? frozenDragWidth : effectiveTimelineWidth
      let duration = isDraggingEffectRange ? frozenDragDurationSeconds : timelineDurationSeconds
      return coordinateSpace(width: width, durationSeconds: duration)
        .timelineSeconds(forX: x.clamped(to: 0...max(width, 1)))
    }

    private var effectiveTimelineWidth: CGFloat {
      max(bounds.width, timelineWidth, 1)
    }

    private func coordinateSpace(width: CGFloat, durationSeconds: Double) -> TimelineCoordinateSpace {
      let duration = max(durationSeconds, 0.001)
      return TimelineCoordinateSpace(
        sourceDurationSeconds: duration,
        previewDurationSeconds: duration,
        timelineDurationSeconds: duration,
        width: max(width, 1)
      )
    }
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

private extension View {
  func eraseToAnyView() -> AnyView {
    AnyView(self)
  }
}
