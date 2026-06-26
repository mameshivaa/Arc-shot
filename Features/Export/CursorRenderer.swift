import AppKit
import CoreGraphics
import simd

final class CursorRenderer {

  struct Style {
    var dotSize: CGFloat = 14
    var ringSize: CGFloat = 30
    var dotColor: NSColor = .white
    var dotAlpha: CGFloat = 0.82
    var ringStrokeColor: NSColor = NSColor.white.withAlphaComponent(0.32)
    var ringLineWidth: CGFloat = 1.6
    var shadowColor: NSColor = NSColor.black.withAlphaComponent(0.24)
    var shadowRadius: CGFloat = 4
    var shadowOffsetY: CGFloat = -1
  }

  private let style: Style
  private let sizeScale: CGFloat
  private let pointerStyle: RecordingProject.CursorVisualSettings.PointerStyle

  init(
    sizeScale: CGFloat = 1.0,
    pointerStyle: RecordingProject.CursorVisualSettings.PointerStyle = .arrow,
    style: Style = Style()
  ) {
    self.style = style
    self.sizeScale = max(0.5, min(3, sizeScale))
    self.pointerStyle = pointerStyle
  }

  func drawCursor(
    in context: CGContext,
    at position: CGPoint,
    shape: RecordingProject.CursorShape?,
    clickPulseProgress: CGFloat? = nil,
    ringPulsePhase: CGFloat = 0
  ) {
    context.saveGState()

    context.setShadow(
      offset: CGSize(width: 0, height: style.shadowOffsetY),
      blur: style.shadowRadius,
      color: style.shadowColor.cgColor
    )

    switch pointerStyle {
    case .spotlight:
      drawRing(in: context, at: position, phase: ringPulsePhase)
      drawDot(in: context, at: position)
    case .arrow:
      drawShape(shape ?? .arrow, in: context, at: position)
    case .arrowWithRing:
      drawRing(in: context, at: position, phase: ringPulsePhase)
      drawShape(shape ?? .arrow, in: context, at: position)
    case .dot:
      drawDot(in: context, at: position)
    }

    context.setShadow(offset: .zero, blur: 0)

    if let progress = clickPulseProgress, progress >= 0, progress <= 1 {
      drawClickPulse(in: context, at: position, progress: progress)
    }

    context.restoreGState()
  }

  private func drawDot(in context: CGContext, at position: CGPoint) {
    let ds = style.dotSize * sizeScale
    let dotRect = CGRect(
      x: position.x - ds / 2,
      y: position.y - ds / 2,
      width: ds,
      height: ds
    )
    context.setFillColor(style.dotColor.withAlphaComponent(style.dotAlpha).cgColor)
    context.fillEllipse(in: dotRect)
  }

  private func drawRing(in context: CGContext, at position: CGPoint, phase: CGFloat) {
    context.setShadow(offset: .zero, blur: 0)
    let rs = style.ringSize * sizeScale
    let ringScale = 0.96 + 0.04 * (0.5 + 0.5 * sin(phase * .pi * 2))
    let ringAlpha = 0.22 + 0.18 * (0.5 + 0.5 * cos(phase * .pi * 2))
    let scaledRS = rs * ringScale
    let ringRect = CGRect(
      x: position.x - scaledRS / 2,
      y: position.y - scaledRS / 2,
      width: scaledRS,
      height: scaledRS
    ).insetBy(dx: style.ringLineWidth, dy: style.ringLineWidth)

    context.setStrokeColor(style.ringStrokeColor.withAlphaComponent(ringAlpha).cgColor)
    context.setLineWidth(style.ringLineWidth)
    context.strokeEllipse(in: ringRect)
  }

  private func drawArrow(in context: CGContext, at position: CGPoint) {
    let scale = 0.82 * sizeScale
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: 24 * scale))
    path.addLine(to: CGPoint(x: 6.2 * scale, y: 18.2 * scale))
    path.addLine(to: CGPoint(x: 10.9 * scale, y: 29.3 * scale))
    path.addLine(to: CGPoint(x: 16.4 * scale, y: 26.9 * scale))
    path.addLine(to: CGPoint(x: 11.6 * scale, y: 16.0 * scale))
    path.addLine(to: CGPoint(x: 19.8 * scale, y: 16.0 * scale))
    path.closeSubpath()

    context.saveGState()
    context.translateBy(x: position.x, y: position.y)
    context.addPath(path)
    context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.58).cgColor)
    context.setLineWidth(max(1.1, 1.5 * sizeScale))
    context.strokePath()
    context.restoreGState()
  }

  private func drawShape(
    _ shape: RecordingProject.CursorShape,
    in context: CGContext,
    at position: CGPoint
  ) {
    switch shape {
    case .arrow, .unknown:
      drawArrow(in: context, at: position)
    case .iBeam:
      drawIBeam(in: context, at: position)
    case .pointingHand:
      drawPointingHand(in: context, at: position)
    case .crosshair:
      drawCrosshair(in: context, at: position)
    case .resizeLeftRight:
      drawResizeLeftRight(in: context, at: position)
    case .resizeUpDown:
      drawResizeUpDown(in: context, at: position)
    case .openHand:
      drawHand(in: context, at: position, isClosed: false)
    case .closedHand:
      drawHand(in: context, at: position, isClosed: true)
    case .operationNotAllowed:
      drawOperationNotAllowed(in: context, at: position)
    }
  }

  private func drawIBeam(in context: CGContext, at position: CGPoint) {
    let scale = sizeScale
    let height = 26 * scale
    let serif = 8 * scale
    let lineWidth = max(1.4, 2 * scale)
    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.setLineWidth(lineWidth + 1.8)
    strokeIBeamPath(in: context, at: position, height: height, serif: serif)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.62).cgColor)
    context.setLineWidth(lineWidth)
    strokeIBeamPath(in: context, at: position, height: height, serif: serif)
    context.restoreGState()
  }

  private func strokeIBeamPath(in context: CGContext, at position: CGPoint, height: CGFloat, serif: CGFloat) {
    context.beginPath()
    context.move(to: CGPoint(x: position.x, y: position.y - height / 2))
    context.addLine(to: CGPoint(x: position.x, y: position.y + height / 2))
    context.move(to: CGPoint(x: position.x - serif / 2, y: position.y - height / 2))
    context.addLine(to: CGPoint(x: position.x + serif / 2, y: position.y - height / 2))
    context.move(to: CGPoint(x: position.x - serif / 2, y: position.y + height / 2))
    context.addLine(to: CGPoint(x: position.x + serif / 2, y: position.y + height / 2))
    context.strokePath()
  }

  private func drawCrosshair(in context: CGContext, at position: CGPoint) {
    let scale = sizeScale
    let radius = 11 * scale
    let gap = 3.5 * scale
    context.saveGState()
    context.setLineCap(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.setLineWidth(max(2.6, 3.2 * scale))
    strokeCrosshairPath(in: context, at: position, radius: radius, gap: gap)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.62).cgColor)
    context.setLineWidth(max(1.1, 1.5 * scale))
    strokeCrosshairPath(in: context, at: position, radius: radius, gap: gap)
    context.restoreGState()
  }

  private func strokeCrosshairPath(in context: CGContext, at position: CGPoint, radius: CGFloat, gap: CGFloat) {
    context.beginPath()
    context.move(to: CGPoint(x: position.x - radius, y: position.y))
    context.addLine(to: CGPoint(x: position.x - gap, y: position.y))
    context.move(to: CGPoint(x: position.x + gap, y: position.y))
    context.addLine(to: CGPoint(x: position.x + radius, y: position.y))
    context.move(to: CGPoint(x: position.x, y: position.y - radius))
    context.addLine(to: CGPoint(x: position.x, y: position.y - gap))
    context.move(to: CGPoint(x: position.x, y: position.y + gap))
    context.addLine(to: CGPoint(x: position.x, y: position.y + radius))
    context.strokePath()
  }

  private func drawResizeLeftRight(in context: CGContext, at position: CGPoint) {
    let scale = sizeScale
    let half = 14 * scale
    let head = 5 * scale
    drawResizeAxis(
      in: context,
      points: [
        CGPoint(x: position.x - half, y: position.y),
        CGPoint(x: position.x + half, y: position.y),
      ],
      arrowHeads: [
        [CGPoint(x: position.x - half + head, y: position.y - head), CGPoint(x: position.x - half, y: position.y), CGPoint(x: position.x - half + head, y: position.y + head)],
        [CGPoint(x: position.x + half - head, y: position.y - head), CGPoint(x: position.x + half, y: position.y), CGPoint(x: position.x + half - head, y: position.y + head)],
      ]
    )
  }

  private func drawResizeUpDown(in context: CGContext, at position: CGPoint) {
    let scale = sizeScale
    let half = 14 * scale
    let head = 5 * scale
    drawResizeAxis(
      in: context,
      points: [
        CGPoint(x: position.x, y: position.y - half),
        CGPoint(x: position.x, y: position.y + half),
      ],
      arrowHeads: [
        [CGPoint(x: position.x - head, y: position.y - half + head), CGPoint(x: position.x, y: position.y - half), CGPoint(x: position.x + head, y: position.y - half + head)],
        [CGPoint(x: position.x - head, y: position.y + half - head), CGPoint(x: position.x, y: position.y + half), CGPoint(x: position.x + head, y: position.y + half - head)],
      ]
    )
  }

  private func drawResizeAxis(
    in context: CGContext,
    points: [CGPoint],
    arrowHeads: [[CGPoint]]
  ) {
    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (color, width) in [
      (NSColor.white.withAlphaComponent(0.96), max(3.2, 4 * sizeScale)),
      (NSColor.black.withAlphaComponent(0.62), max(1.2, 1.8 * sizeScale)),
    ] {
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.beginPath()
      context.move(to: points[0])
      context.addLine(to: points[1])
      for head in arrowHeads where head.count == 3 {
        context.move(to: head[0])
        context.addLine(to: head[1])
        context.addLine(to: head[2])
      }
      context.strokePath()
    }
    context.restoreGState()
  }

  private func drawPointingHand(in context: CGContext, at position: CGPoint) {
    let scale = sizeScale
    context.saveGState()
    context.translateBy(x: position.x, y: position.y)
    context.scaleBy(x: scale, y: scale)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: -18))
    path.addQuadCurve(to: CGPoint(x: 5, y: -18), control: CGPoint(x: 2.5, y: -21))
    path.addLine(to: CGPoint(x: 5, y: -6))
    path.addQuadCurve(to: CGPoint(x: 10, y: -5), control: CGPoint(x: 8, y: -8))
    path.addLine(to: CGPoint(x: 15, y: 3))
    path.addQuadCurve(to: CGPoint(x: 11, y: 16), control: CGPoint(x: 17, y: 11))
    path.addLine(to: CGPoint(x: -3, y: 16))
    path.addQuadCurve(to: CGPoint(x: -8, y: 6), control: CGPoint(x: -8, y: 12))
    path.addLine(to: CGPoint(x: -6, y: 0))
    path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -3, y: -2))
    path.closeSubpath()
    fillCursorPath(path, in: context)
    context.restoreGState()
  }

  private func drawHand(in context: CGContext, at position: CGPoint, isClosed: Bool) {
    let scale = sizeScale
    context.saveGState()
    context.translateBy(x: position.x, y: position.y)
    context.scaleBy(x: scale, y: scale)
    let path = CGMutablePath()
    let top: CGFloat = isClosed ? -9 : -13
    path.addRoundedRect(
      in: CGRect(x: -9, y: top, width: 18, height: 23),
      cornerWidth: 7,
      cornerHeight: 7
    )
    if !isClosed {
      for x in [-7, -2, 3, 8] as [CGFloat] {
        path.addRoundedRect(in: CGRect(x: x, y: -18, width: 4, height: 12), cornerWidth: 2, cornerHeight: 2)
      }
    }
    fillCursorPath(path, in: context)
    context.restoreGState()
  }

  private func drawOperationNotAllowed(in context: CGContext, at position: CGPoint) {
    let scale = sizeScale
    let radius = 12 * scale
    context.saveGState()
    context.setLineCap(.round)
    for (color, width) in [
      (NSColor.white.withAlphaComponent(0.96), max(3.4, 4.2 * scale)),
      (NSColor.black.withAlphaComponent(0.68), max(1.4, 1.9 * scale)),
    ] {
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.strokeEllipse(in: CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2))
      context.beginPath()
      context.move(to: CGPoint(x: position.x - radius * 0.62, y: position.y - radius * 0.62))
      context.addLine(to: CGPoint(x: position.x + radius * 0.62, y: position.y + radius * 0.62))
      context.strokePath()
    }
    context.restoreGState()
  }

  private func fillCursorPath(_ path: CGPath, in context: CGContext) {
    context.addPath(path)
    context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.58).cgColor)
    context.setLineWidth(max(1.1, 1.5 * sizeScale))
    context.strokePath()
  }

  private func drawClickPulse(in context: CGContext, at position: CGPoint, progress: CGFloat) {
    let maxRadius = style.ringSize * sizeScale * 1.35
    let radius = maxRadius * progress
    let alpha = 0.32 * (1 - progress)
    let pulseRect = CGRect(
      x: position.x - radius,
      y: position.y - radius,
      width: radius * 2,
      height: radius * 2
    )
    context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    context.setLineWidth(1.6 * sizeScale)
    context.strokeEllipse(in: pulseRect)
  }

  static func interpolateCursorPosition(
    at timeSeconds: Double,
    samples: [RecordingProject.CursorSample]
  ) -> (x: Double, y: Double, shape: RecordingProject.CursorShape?) {
    guard !samples.isEmpty else { return (0.5, 0.5, .arrow) }
    guard samples.count > 1 else {
      return (samples[0].x, samples[0].y, samples[0].shape)
    }
    if timeSeconds <= samples[0].timeSeconds {
      return (samples[0].x, samples[0].y, samples[0].shape)
    }
    if timeSeconds >= samples[samples.count - 1].timeSeconds {
      let last = samples[samples.count - 1]
      return (last.x, last.y, last.shape)
    }

    var lo = 0, hi = samples.count - 1
    while lo < hi - 1 {
      let mid = (lo + hi) / 2
      if samples[mid].timeSeconds <= timeSeconds { lo = mid } else { hi = mid }
    }
    let s0 = samples[lo]
    let s1 = samples[hi]
    let dt = s1.timeSeconds - s0.timeSeconds
    guard dt > 1e-9 else { return (s0.x, s0.y, s0.shape) }
    let u = (timeSeconds - s0.timeSeconds) / dt
    return (
      x: s0.x + (s1.x - s0.x) * u,
      y: s0.y + (s1.y - s0.y) * u,
      shape: u < 0.5 ? s0.shape : s1.shape
    )
  }

  static func clickPulseProgress(
    at timeSeconds: Double,
    clickCues: [RecordingProject.CursorClickCue],
    pulseDuration: Double = 0.22
  ) -> CGFloat? {
    for cue in clickCues {
      let elapsed = timeSeconds - cue.timeSeconds
      if elapsed >= 0, elapsed < pulseDuration {
        return CGFloat(elapsed / pulseDuration)
      }
    }
    return nil
  }
}
