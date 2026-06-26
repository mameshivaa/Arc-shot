import AppKit
import QuartzCore
import SwiftUI

struct EditorTimelinePlayheadGhostSurface: NSViewRepresentable {
  var currentDisplaySeconds: Double
  var durationSeconds: Double
  var contentWidth: CGFloat
  var activeWidth: CGFloat
  var snapEnabled: Bool
  var snapTargets: [TimelineSnapTarget]
  var snapThresholdSeconds: Double
  var topHitInsetY: CGFloat = 0
  /// クリップレーン上端の Y（サーフェス座標）。この帯より下では再生ヘッドの全高さ掴みを無効化し、
  /// トリムハンドルやクリップ操作にマウスイベントを通す。
  var clipLaneMinY: CGFloat = .greatestFiniteMagnitude
  var onInteractionBegan: () -> Void
  var onPreview: (Double) -> Void
  var onCommit: (Double, @escaping @MainActor @Sendable () -> Void) -> Void
  var onInteractionEnded: () -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.currentDisplaySeconds = currentDisplaySeconds
    nsView.durationSeconds = max(durationSeconds, 0.001)
    nsView.contentWidth = max(contentWidth, 1)
    nsView.activeWidth = max(activeWidth, 1)
    nsView.snapEnabled = snapEnabled
    nsView.snapTargets = snapTargets
    nsView.snapThresholdSeconds = max(snapThresholdSeconds, 0)
    nsView.topHitInsetY = max(topHitInsetY, 0)
    nsView.clipLaneMinY = clipLaneMinY
    nsView.onInteractionBegan = onInteractionBegan
    nsView.onPreview = onPreview
    nsView.onCommit = onCommit
    nsView.onInteractionEnded = onInteractionEnded
    nsView.updateHoverCursor(at: nsView.convert(nsView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
  }

  static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
    nsView.cancelInteraction()
  }

  final class TrackingView: NSView {
    var currentDisplaySeconds: Double = 0
    var durationSeconds: Double = 1
    var contentWidth: CGFloat = 1
    var activeWidth: CGFloat = 1
    var snapEnabled = false
    var snapTargets: [TimelineSnapTarget] = []
    var snapThresholdSeconds: Double = 0
    var topHitInsetY: CGFloat = 0
    var clipLaneMinY: CGFloat = .greatestFiniteMagnitude
    var onInteractionBegan: () -> Void = {}
    var onPreview: (Double) -> Void = { _ in }
    var onCommit: (Double, @escaping @MainActor @Sendable () -> Void) -> Void = { _, completion in completion() }
    var onInteractionEnded: () -> Void = {}

    private let ghostLineLayer = CALayer()
    private let ghostLabelBackgroundLayer = CALayer()
    private let ghostLabelLayer = CATextLayer()
    private var trackingArea: NSTrackingArea?
    private var frozenDurationSeconds: Double = 1
    private var frozenActiveWidth: CGFloat = 1
    private var frozenContentWidth: CGFloat = 1
    private var frozenSnapEnabled = false
    private var frozenSnapTargets: [TimelineSnapTarget] = []
    private var frozenSnapThresholdSeconds: Double = 0
    private var liveDisplaySeconds: Double = 0
    private var liveDidSnap = false
    private var isDraggingPlayhead = false
    private var didSetupLayers = false
    private var pendingCompletionFallback: DispatchWorkItem?
    private var autoScrollTimer: Timer?
    private var lastAutoScrollUptime: TimeInterval?

    private static let autoScrollEdgeWidth: CGFloat = 32
    private static let autoScrollMinSpeed: CGFloat = 90
    private static let autoScrollMaxSpeed: CGFloat = 520
    private static let autoScrollTickInterval: TimeInterval = 1.0 / 60.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
      if isDraggingPlayhead || isPointInSeekHitTarget(point) {
        return self
      }
      return nil
    }

    override func mouseMoved(with event: NSEvent) {
      updateHoverCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
      stopAutoScroll()
      if !isDraggingPlayhead {
        NSCursor.arrow.set()
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let point = convert(event.locationInWindow, from: nil)
      guard isPointInSeekHitTarget(point) else { return }

      cancelPendingCompletion()
      stopAutoScroll()
      frozenDurationSeconds = max(durationSeconds, 0.001)
      frozenActiveWidth = max(activeWidth, 1)
      frozenContentWidth = max(contentWidth, 1)
      frozenSnapEnabled = snapEnabled
      frozenSnapTargets = snapTargets
      frozenSnapThresholdSeconds = max(snapThresholdSeconds, 0)
      let result = snappedDisplayResult(for: displaySeconds(forContentX: point.x))
      liveDisplaySeconds = result.seconds
      liveDidSnap = result.didSnap
      isDraggingPlayhead = true
      onInteractionBegan()
      setGhostHidden(false)
      updateGhost(displaySeconds: liveDisplaySeconds, didSnap: liveDidSnap)
      onPreview(liveDisplaySeconds)
    }

    override func mouseDragged(with event: NSEvent) {
      guard isDraggingPlayhead else { return }
      let point = convert(event.locationInWindow, from: nil)
      updateLiveDisplaySeconds(forContentPoint: point)
      updateAutoScroll(forContentPoint: point)
    }

    override func mouseUp(with event: NSEvent) {
      guard isDraggingPlayhead else { return }
      stopAutoScroll()
      let finalDisplaySeconds = liveDisplaySeconds
      let fallback = DispatchWorkItem { [weak self] in
        self?.finishInteraction()
      }
      pendingCompletionFallback = fallback
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: fallback)
      onCommit(finalDisplaySeconds) { [weak self] in
        self?.finishInteraction()
      }
    }

    override func layout() {
      super.layout()
      if isDraggingPlayhead {
        updateGhost(displaySeconds: liveDisplaySeconds, didSnap: liveDidSnap)
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stopAutoScroll()
      }
      updateTrackingAreas()
    }

    func updateHoverCursor(at point: CGPoint) {
      guard !isDraggingPlayhead else {
        NSCursor.resizeLeftRight.set()
        return
      }
      if isPointInSeekHitTarget(point) {
        NSCursor.resizeLeftRight.set()
      } else {
        NSCursor.arrow.set()
      }
    }

    func cancelPendingCompletion() {
      pendingCompletionFallback?.cancel()
      pendingCompletionFallback = nil
    }

    func cancelInteraction() {
      cancelPendingCompletion()
      stopAutoScroll()
      if isDraggingPlayhead {
        finishInteraction()
      }
    }

    private func finishInteraction() {
      guard isDraggingPlayhead else { return }
      cancelPendingCompletion()
      stopAutoScroll()
      isDraggingPlayhead = false
      setGhostHidden(true)
      onInteractionEnded()
      updateHoverCursor(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    private func setupLayers() {
      guard !didSetupLayers, let root = layer else { return }
      didSetupLayers = true
      ghostLineLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.82).cgColor
      ghostLineLayer.cornerRadius = EditorLayout.timelinePlayheadLineWidth / 2
      ghostLineLayer.masksToBounds = true

      ghostLabelBackgroundLayer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
      ghostLabelBackgroundLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
      ghostLabelBackgroundLayer.borderWidth = 1
      ghostLabelBackgroundLayer.cornerRadius = 5
      ghostLabelBackgroundLayer.masksToBounds = true

      ghostLabelLayer.alignmentMode = .center
      ghostLabelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
      ghostLabelLayer.fontSize = 10
      ghostLabelLayer.foregroundColor = NSColor.labelColor.cgColor

      root.addSublayer(ghostLineLayer)
      root.addSublayer(ghostLabelBackgroundLayer)
      ghostLabelBackgroundLayer.addSublayer(ghostLabelLayer)
      setGhostHidden(true)
    }

    private func setGhostHidden(_ hidden: Bool) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      ghostLineLayer.isHidden = hidden
      ghostLabelBackgroundLayer.isHidden = hidden
      CATransaction.commit()
    }

    private func isPointInSeekHitTarget(_ point: CGPoint) -> Bool {
      EditorTimelinePlayheadHitTarget.contains(
        point: point,
        bounds: bounds,
        currentDisplaySeconds: currentDisplaySeconds,
        durationSeconds: durationSeconds,
        activeWidth: activeWidth,
        topHitInsetY: topHitInsetY,
        clipLaneMinY: clipLaneMinY
      )
    }

    private func updateGhost(displaySeconds: Double, didSnap: Bool) {
      let seconds = displaySeconds.clamped(to: 0...frozenDurationSeconds)
      let x = contentX(forDisplaySeconds: seconds)
      let labelWidth = EditorLayout.timelinePlayheadLabelWidth
      let labelHeight = EditorLayout.timelinePlayheadGhostLabelHeight
      let labelX = (x - labelWidth / 2).clamped(to: 0...max(0, frozenContentWidth - labelWidth))
      let lineAlpha: CGFloat = didSnap ? 0.98 : 0.82
      let borderAlpha: CGFloat = didSnap ? 0.72 : 0.35

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      ghostLineLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(lineAlpha).cgColor
      ghostLineLayer.frame = CGRect(
        x: x - EditorLayout.timelinePlayheadLineWidth / 2,
        y: 0,
        width: EditorLayout.timelinePlayheadLineWidth,
        height: bounds.height
      )
      ghostLabelBackgroundLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(borderAlpha).cgColor
      ghostLabelBackgroundLayer.borderWidth = didSnap ? 1.5 : 1
      ghostLabelBackgroundLayer.frame = CGRect(x: labelX, y: 0, width: labelWidth, height: labelHeight)
      ghostLabelLayer.frame = CGRect(x: 0, y: 2, width: labelWidth, height: labelHeight - 2)
      ghostLabelLayer.string = editorFormatTime(seconds, fractional: true)
      CATransaction.commit()
    }

    private func snappedDisplayResult(for candidateSeconds: Double) -> TimelineSnapResult {
      let policy = TimelineSnapPolicy(
        enabled: frozenSnapEnabled,
        targets: frozenSnapTargets,
        thresholdSeconds: frozenSnapThresholdSeconds,
        validRange: 0...frozenDurationSeconds
      )
      return policy.snappedResult(for: candidateSeconds)
    }

    private func updateLiveDisplaySeconds(forContentPoint point: CGPoint) {
      let result = snappedDisplayResult(for: displaySeconds(forContentX: point.x))
      liveDisplaySeconds = result.seconds
      liveDidSnap = result.didSnap
      updateGhost(displaySeconds: liveDisplaySeconds, didSnap: liveDidSnap)
      onPreview(liveDisplaySeconds)
    }

    private func updateAutoScroll(forContentPoint point: CGPoint) {
      guard isDraggingPlayhead,
        canAutoScroll,
        autoScrollVelocity(forContentPoint: point) != nil
      else {
        stopAutoScroll()
        return
      }
      startAutoScrollIfNeeded()
    }

    private var canAutoScroll: Bool {
      guard let scrollView = enclosingScrollView else { return false }
      return frozenContentWidth > scrollView.contentSize.width + 0.5
    }

    private func startAutoScrollIfNeeded() {
      guard autoScrollTimer == nil else { return }
      lastAutoScrollUptime = ProcessInfo.processInfo.systemUptime
      let timer = Timer(timeInterval: Self.autoScrollTickInterval, repeats: true) { [weak self] _ in
        Task { @MainActor in
          self?.performAutoScrollTick()
        }
      }
      autoScrollTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAutoScroll() {
      autoScrollTimer?.invalidate()
      autoScrollTimer = nil
      lastAutoScrollUptime = nil
    }

    private func performAutoScrollTick() {
      guard isDraggingPlayhead,
        let scrollView = enclosingScrollView,
        let window
      else {
        stopAutoScroll()
        return
      }

      let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      guard let velocity = autoScrollVelocity(forContentPoint: mousePoint) else {
        stopAutoScroll()
        return
      }

      let maxOffset = max(0, frozenContentWidth - scrollView.contentSize.width)
      guard maxOffset > 0 else {
        stopAutoScroll()
        return
      }

      let now = ProcessInfo.processInfo.systemUptime
      let dt = min(max(now - (lastAutoScrollUptime ?? now), 0), 0.05)
      lastAutoScrollUptime = now

      let currentOffset = scrollView.contentView.bounds.origin.x
      let nextOffset = (currentOffset + velocity * CGFloat(dt)).clamped(to: 0...maxOffset)
      guard abs(nextOffset - currentOffset) > 0.01 else {
        stopAutoScroll()
        return
      }

      scrollView.contentView.scroll(to: CGPoint(x: nextOffset, y: 0))
      scrollView.reflectScrolledClipView(scrollView.contentView)

      let updatedMousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      updateLiveDisplaySeconds(forContentPoint: updatedMousePoint)

      if (nextOffset <= 0.5 && velocity < 0) || (nextOffset >= maxOffset - 0.5 && velocity > 0) {
        stopAutoScroll()
      }
    }

    private func autoScrollVelocity(forContentPoint point: CGPoint) -> CGFloat? {
      guard isDraggingPlayhead,
        let scrollView = enclosingScrollView
      else {
        return nil
      }

      let visibleRect = scrollView.contentView.bounds
      guard frozenContentWidth > visibleRect.width + 0.5 else { return nil }

      let edgeWidth = Self.autoScrollEdgeWidth
      let leftDistance = point.x - visibleRect.minX
      let rightDistance = visibleRect.maxX - point.x

      if leftDistance <= edgeWidth {
        let intensity = ((edgeWidth - max(leftDistance, 0)) / edgeWidth).clamped(to: 0...1)
        return -autoScrollSpeed(forIntensity: intensity)
      }
      if rightDistance <= edgeWidth {
        let intensity = ((edgeWidth - max(rightDistance, 0)) / edgeWidth).clamped(to: 0...1)
        return autoScrollSpeed(forIntensity: intensity)
      }
      return nil
    }

    private func autoScrollSpeed(forIntensity intensity: CGFloat) -> CGFloat {
      Self.autoScrollMinSpeed + (Self.autoScrollMaxSpeed - Self.autoScrollMinSpeed) * intensity
    }

    private func contentX(forDisplaySeconds seconds: Double) -> CGFloat {
      EditorTimelinePlayheadHitTarget.contentX(
        forDisplaySeconds: seconds,
        durationSeconds: frozenDurationSeconds,
        activeWidth: frozenActiveWidth
      )
    }

    private func displaySeconds(forContentX x: CGFloat) -> Double {
      let space = TimelineCoordinateSpace(
        sourceDurationSeconds: frozenDurationSeconds,
        previewDurationSeconds: frozenDurationSeconds,
        timelineDurationSeconds: frozenDurationSeconds,
        width: frozenActiveWidth
      )
      let localX = (x - EditorLayout.timelineLaneInsetX).clamped(to: 0...frozenActiveWidth)
      return space.timelineSeconds(forX: localX)
    }
  }
}

enum EditorTimelinePlayheadHitTarget {
  static func contains(
    point: CGPoint,
    bounds: CGRect,
    currentDisplaySeconds: Double,
    durationSeconds: Double,
    activeWidth: CGFloat,
    topHitInsetY: CGFloat = 0,
    clipLaneMinY: CGFloat = .greatestFiniteMagnitude
  ) -> Bool {
    guard bounds.contains(point) else { return false }
    let playheadX = contentX(
      forDisplaySeconds: currentDisplaySeconds,
      durationSeconds: durationSeconds,
      activeWidth: activeWidth
    )
    // 再生ヘッド近傍の「全高さ掴み」は、エフェクトレーンとクリップレーン（トリムハンドルが乗る帯）を除外する。
    // これにより、再生位置とトリムハンドルが重なってもハンドル側がマウスイベントを受け取れる。
    let effectLaneMinY = max(
      0,
      bounds.height
        - EditorLayout.timelineEffectLaneHeight
        - EditorLayout.timelineLaneGap
        - EditorLayout.timelineMaskLaneMinHeight
    )
    let fullHeightGrabMaxY = min(effectLaneMinY, clipLaneMinY)
    if point.y < fullHeightGrabMaxY,
      abs(point.x - playheadX) <= EditorLayout.timelinePlayheadGhostHitWidth / 2 {
      return true
    }

    guard point.y <= max(0, topHitInsetY) + EditorLayout.timelinePlayheadGhostTopHitHeight else { return false }
    let minX = EditorLayout.timelineLaneInsetX - EditorLayout.timelinePlayheadGhostHitWidth / 2
    let maxX = EditorLayout.timelineLaneInsetX + activeWidth + EditorLayout.timelinePlayheadGhostHitWidth / 2
    return point.x >= minX && point.x <= maxX
  }

  static func contentX(
    forDisplaySeconds seconds: Double,
    durationSeconds: Double,
    activeWidth: CGFloat
  ) -> CGFloat {
    let duration = max(durationSeconds, 0.001)
    let width = max(activeWidth, 1)
    let space = TimelineCoordinateSpace(
      sourceDurationSeconds: duration,
      previewDurationSeconds: duration,
      timelineDurationSeconds: duration,
      width: width
    )
    return EditorLayout.timelineLaneInsetX + space.timelineX(for: seconds.clamped(to: 0...duration))
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
