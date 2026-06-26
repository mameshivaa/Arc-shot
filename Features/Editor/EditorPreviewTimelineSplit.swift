import AppKit
import SwiftUI

private enum EditorSplitPaneTransaction {
  static func withoutAnimations(_ updates: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, updates)
  }
}

private struct EditorSplitPaneClip<Content: View>: View {
  let width: CGFloat
  let contentHeight: CGFloat
  let displayHeight: CGFloat
  let allowsInteraction: Bool
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .frame(width: width, height: contentHeight, alignment: .top)
      .frame(width: width, height: displayHeight, alignment: .top)
      .clipped()
      .allowsHitTesting(allowsInteraction)
  }
}

private struct EditorPreviewTimelineResizeSurface: NSViewRepresentable {
  var timelinePaneHeight: CGFloat
  var availableHeight: CGFloat
  var onTimelineHeightChange: (CGFloat) -> Void
  var onResizingChanged: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    context.coordinator.onTimelineHeightChange = onTimelineHeightChange
    context.coordinator.onResizingChanged = onResizingChanged
    nsView.coordinator = context.coordinator
    nsView.timelinePaneHeight = timelinePaneHeight
    nsView.availableHeight = max(1, availableHeight)
    if !nsView.isDragging {
      nsView.syncAppearance()
      nsView.needsLayout = true
    }
  }

  static func dismantleNSView(_ nsView: TrackingView, context: Context) {
    nsView.teardownDragSession()
  }

  final class Coordinator {
    var lastAppliedTimelineHeight: CGFloat?
    var onTimelineHeightChange: (CGFloat) -> Void = { _ in }
    var onResizingChanged: (Bool) -> Void = { _ in }

    func handleTimelineHeightChange(_ height: CGFloat) {
      if let lastAppliedTimelineHeight,
         abs(lastAppliedTimelineHeight - height) < EditorLayout.previewTimelineResizeHeightChangeEpsilon {
        return
      }
      lastAppliedTimelineHeight = height
      onTimelineHeightChange(height)
    }

    func handleResizingChanged(_ resizing: Bool) {
      if resizing {
        lastAppliedTimelineHeight = nil
      }
      onResizingChanged(resizing)
    }
  }

  final class TrackingView: NSView {
    weak var coordinator: Coordinator?
    var timelinePaneHeight: CGFloat = EditorLayout.defaultTimelinePaneHeight
    var availableHeight: CGFloat = 1

    private let gripLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var dragStartWindowY: CGFloat?
    private var dragStartPreviewHeight: CGFloat?
    private(set) var isDragging = false
    private var isHovering = false
    private var mouseUpMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
      true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      if isDragging || bounds.contains(point) {
        return self
      }
      return nil
    }

    func syncAppearance() {
      let alpha: CGFloat
      if isDragging {
        alpha = 0.30
      } else if isHovering {
        alpha = 0.20
      } else {
        alpha = 0.10
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      gripLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
      CATransaction.commit()
    }

    override func layout() {
      super.layout()
      if gripLayer.superlayer == nil {
        setupLayers()
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      gripLayer.frame = CGRect(
        x: max(0, (bounds.width - EditorLayout.previewTimelineResizeGripWidth) / 2),
        y: max(0, (bounds.height - EditorLayout.previewTimelineResizeGripHeight) / 2),
        width: min(EditorLayout.previewTimelineResizeGripWidth, bounds.width),
        height: EditorLayout.previewTimelineResizeGripHeight
      )
      CATransaction.commit()
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea {
        removeTrackingArea(trackingArea)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseEnteredAndExited, .enabledDuringMouseDrag, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      isHovering = true
      syncAppearance()
      NSCursor.resizeUpDown.push()
    }

    override func mouseExited(with event: NSEvent) {
      guard !isDragging else { return }
      isHovering = false
      syncAppearance()
      NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      dragStartWindowY = event.locationInWindow.y
      dragStartPreviewHeight = EditorLayout.previewPaneHeight(
        timelinePaneHeight: timelinePaneHeight,
        availableHeight: availableHeight
      )
      isDragging = true
      syncAppearance()
      coordinator?.handleResizingChanged(true)
      installMouseUpMonitor()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let startWindowY = dragStartWindowY, let startPreview = dragStartPreviewHeight else { return }
      let windowDeltaY = event.locationInWindow.y - startWindowY
      let split = EditorLayout.splitHeights(
        proposedPreviewHeight: startPreview - windowDeltaY,
        availableHeight: availableHeight
      )
      coordinator?.handleTimelineHeightChange(split.timeline)
    }

    override func mouseUp(with event: NSEvent) {
      finishDrag()
    }

    private func installMouseUpMonitor() {
      removeMouseUpMonitor()
      mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
        guard let self, isDragging else { return event }
        finishDrag()
        return event
      }
    }

    private func removeMouseUpMonitor() {
      if let mouseUpMonitor {
        NSEvent.removeMonitor(mouseUpMonitor)
        self.mouseUpMonitor = nil
      }
    }

    private func finishDrag() {
      guard isDragging else { return }
      removeMouseUpMonitor()
      dragStartWindowY = nil
      dragStartPreviewHeight = nil
      isDragging = false
      let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
      isHovering = bounds.contains(point)
      syncAppearance()
      coordinator?.handleResizingChanged(false)
      updateCursorForCurrentMouseLocation()
    }

    func teardownDragSession() {
      removeMouseUpMonitor()
      dragStartWindowY = nil
      dragStartPreviewHeight = nil
      if isDragging {
        isDragging = false
        coordinator?.handleResizingChanged(false)
      }
    }

    private func updateCursorForCurrentMouseLocation() {
      let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
      if bounds.contains(point) {
        NSCursor.resizeUpDown.push()
      } else {
        NSCursor.arrow.set()
      }
    }

    private func setupLayers() {
      guard let root = layer else { return }
      gripLayer.cornerRadius = 1.5
      root.addSublayer(gripLayer)
    }
  }
}

struct EditorPreviewTimelineSplit<Preview: View, Timeline: View>: View {
  @Binding var timelinePaneHeight: CGFloat
  var onTimelinePaneHeightCommitted: (CGFloat) -> Void = { _ in }
  @ViewBuilder var preview: () -> Preview
  @ViewBuilder var timeline: () -> Timeline

  @State private var isResizingSplit = false
  @State private var liveTimelinePaneHeight: CGFloat?
  @State private var frozenPreviewContentHeight: CGFloat?
  @State private var frozenTimelineContentHeight: CGFloat?

  var body: some View {
    GeometryReader { geo in
      let metrics = EditorLayout.previewTimelineSplitMetrics(
        timelinePaneHeight: liveTimelinePaneHeight ?? timelinePaneHeight,
        availableHeight: geo.size.height
      )
      let previewContentHeight = frozenPreviewContentHeight ?? metrics.previewHeight
      let timelineContentHeight = frozenTimelineContentHeight ?? metrics.clampedTimelineHeight

      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          EditorSplitPaneClip(
            width: geo.size.width,
            contentHeight: previewContentHeight,
            displayHeight: metrics.previewHeight,
            allowsInteraction: !isResizingSplit,
            content: preview
          )
          .layoutPriority(0)

          Color.clear
            .frame(height: metrics.handleHeight)
            .allowsHitTesting(false)

          EditorSplitPaneClip(
            width: geo.size.width,
            contentHeight: timelineContentHeight,
            displayHeight: metrics.clampedTimelineHeight,
            allowsInteraction: !isResizingSplit,
            content: timeline
          )
          .layoutPriority(0)
        }

        EditorPreviewTimelineResizeSurface(
          timelinePaneHeight: metrics.clampedTimelineHeight,
          availableHeight: metrics.availableHeight,
          onTimelineHeightChange: { height in
            EditorSplitPaneTransaction.withoutAnimations {
              liveTimelinePaneHeight = height
            }
          },
          onResizingChanged: handleResizingChanged(
            metrics: metrics
          )
        )
        .frame(width: geo.size.width, height: metrics.resizeBandHeight)
        .offset(y: metrics.resizeBandOffsetY)
        .zIndex(10)
        .help("ドラッグしてプレビューとタイムラインの境界を調整")
        .accessibilityLabel("プレビューとタイムラインの境界")
        .accessibilityHint("ドラッグして高さを調整します")
      }
      .transaction { transaction in
        if isResizingSplit {
          transaction.disablesAnimations = true
        }
      }
      .frame(width: geo.size.width, height: metrics.availableHeight, alignment: .topLeading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: EditorLayout.panelCornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: EditorLayout.panelCornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.09), lineWidth: 1)
      }
      .onDisappear(perform: resetResizeSession)
      .onAppear {
        clampTimelinePaneHeightIfNeeded(
          availableHeight: metrics.availableHeight,
          clampedHeight: metrics.clampedTimelineHeight
        )
      }
      .onChange(of: metrics.availableHeight) { _, newValue in
        guard !isResizingSplit else { return }
        let clamped = EditorLayout.resolvedTimelinePaneHeight(
          proposed: timelinePaneHeight,
          availableHeight: newValue
        )
        guard abs(clamped - timelinePaneHeight) > 0.5 else { return }
        timelinePaneHeight = clamped
        onTimelinePaneHeightCommitted(clamped)
      }
    }
  }

  private func handleResizingChanged(
    metrics: EditorLayout.PreviewTimelineSplitMetrics
  ) -> (Bool) -> Void {
    { resizing in
      isResizingSplit = resizing
      if resizing {
        liveTimelinePaneHeight = timelinePaneHeight
        frozenPreviewContentHeight = metrics.previewHeight
        frozenTimelineContentHeight = metrics.clampedTimelineHeight
        return
      }

      if let live = liveTimelinePaneHeight {
        EditorSplitPaneTransaction.withoutAnimations {
          timelinePaneHeight = live
          liveTimelinePaneHeight = nil
          frozenPreviewContentHeight = nil
          frozenTimelineContentHeight = nil
        }
        onTimelinePaneHeightCommitted(live)
      } else {
        frozenPreviewContentHeight = nil
        frozenTimelineContentHeight = nil
      }
    }
  }

  private func clampTimelinePaneHeightIfNeeded(availableHeight: CGFloat, clampedHeight: CGFloat) {
    guard !isResizingSplit else { return }
    guard abs(timelinePaneHeight - clampedHeight) > 0.5 else { return }
    timelinePaneHeight = EditorLayout.resolvedTimelinePaneHeight(
      proposed: timelinePaneHeight,
      availableHeight: availableHeight
    )
  }

  private func resetResizeSession() {
    guard isResizingSplit else { return }
    isResizingSplit = false
    liveTimelinePaneHeight = nil
    frozenPreviewContentHeight = nil
    frozenTimelineContentHeight = nil
  }
}
