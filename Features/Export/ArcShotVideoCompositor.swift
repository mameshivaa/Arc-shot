@preconcurrency import AVFoundation
import AppKit
import CoreImage
import CoreText
import CoreVideo
import Metal
import QuartzCore

final class ArcShotVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

  // MARK: - AVVideoCompositing protocol

  var sourcePixelBufferAttributes: [String: any Sendable]? {
    [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
  }

  var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
    [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
  }

  private let renderQueue = DispatchQueue(
    label: "com.arcshot.compositor",
    qos: .userInitiated
  )
  private var renderContext: AVVideoCompositionRenderContext?
  private let cancellationLock = NSLock()
  private var shouldCancel = false

  private lazy var ciContext: CIContext = {
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
    }
    return CIContext(options: [.workingColorSpace: NSNull()])
  }()

  private var cachedStageBackgroundKey: (settings: RecordingProject.ExportVisualSettings, width: Int, height: Int)?
  private var cachedStageBackgroundImage: CIImage?

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderQueue.sync {
      self.renderContext = newRenderContext
    }
  }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    renderQueue.async { [weak self] in
      guard let self, !self.isCancellationRequested else {
        request.finishCancelledRequest()
        return
      }
      self.processRequest(request)
    }
  }

  func cancelAllPendingVideoCompositionRequests() {
    setCancellationRequested(true)
    renderQueue.async { [weak self] in
      self?.setCancellationRequested(false)
    }
  }

  private var isCancellationRequested: Bool {
    cancellationLock.lock()
    defer { cancellationLock.unlock() }
    return shouldCancel
  }

  private func setCancellationRequested(_ value: Bool) {
    cancellationLock.lock()
    shouldCancel = value
    cancellationLock.unlock()
  }

  // MARK: - Per-frame rendering

  private func processRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    autoreleasepool {
      processRequestBody(request)
    }
  }

  private func processRequestBody(_ request: AVAsynchronousVideoCompositionRequest) {
    guard let instruction = request.videoCompositionInstruction as? ArcShotCompositionInstruction else {
      request.finish(with: NSError(domain: "ArcShotCompositor", code: -1))
      return
    }

    guard let renderContext else {
      request.finish(with: NSError(domain: "ArcShotCompositor", code: -2))
      return
    }

    guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.mainTrackID) else {
      request.finish(with: NSError(domain: "ArcShotCompositor", code: -3))
      return
    }

    guard let outputBuffer = renderContext.newPixelBuffer() else {
      request.finish(with: NSError(domain: "ArcShotCompositor", code: -4))
      return
    }

    let compositionTime = request.compositionTime
    let renderSize = instruction.renderSize
    let timeSeconds = instruction.timedDataSeconds(at: compositionTime)

    var sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
    sourceImage = applyBlurMasks(
      to: sourceImage,
      masks: instruction.visualMasks,
      sourceSize: instruction.mainSourceSize,
      timeSeconds: timeSeconds
    )

    let zoomTransform = instruction.interpolatedZoomTransform(at: compositionTime)
    // INVARIANT §5: highQualityDownsample when shrinking — do not remove without quality review.
    sourceImage = sourceImage.transformed(by: zoomTransform, highQualityDownsample: true)

    let cropRect = CGRect(origin: .zero, size: renderSize)
    sourceImage = sourceImage.cropped(to: cropRect)

    if instruction.stage.useStage {
      sourceImage = applyStageLayout(
        videoImage: sourceImage,
        renderSize: renderSize,
        stage: instruction.stage,
        sourceSize: instruction.mainSourceSize
      )
    }

    if let pipTrackID = instruction.pipTrackID,
       let pipTransform = instruction.pipTransform,
       let pipBuffer = request.sourceFrame(byTrackID: pipTrackID) {
      var pipImage = CIImage(cvPixelBuffer: pipBuffer)
        .transformed(by: pipTransform, highQualityDownsample: true)
        .cropped(to: cropRect)
      if let pipClip = instruction.pipClip {
        pipImage = clippedImage(
          pipImage,
          rect: pipClip.rect,
          renderSize: renderSize,
          radius: pipClip.cornerRadius,
          backgroundImage: sourceImage
        )
      }
      sourceImage = pipImage.composited(over: sourceImage)
    }

    ciContext.render(sourceImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())

    drawCPUOverlays(
      into: outputBuffer,
      instruction: instruction,
      timeSeconds: timeSeconds,
      sourceTransform: sourceToRenderTransform(
        zoomTransform: zoomTransform,
        renderSize: renderSize,
        stage: instruction.stage,
        sourceSize: instruction.mainSourceSize
      ),
      sourceSize: instruction.mainSourceSize
    )

    request.finish(withComposedVideoFrame: outputBuffer)
  }

  // MARK: - Stage layout

  private func applyStageLayout(
    videoImage: CIImage,
    renderSize: CGSize,
    stage: ArcShotCompositionInstruction.StageConfig,
    sourceSize: CGSize
  ) -> CIImage {
    let geometry = stageGeometry(renderSize: renderSize, stage: stage, sourceSize: sourceSize)
    var result = cachedStageBackgroundImage(settings: stage.backgroundSettings, renderSize: renderSize)
    if let shadow = Self.stageCardShadow(stage: stage, geometry: geometry) {
      result = stageShadowImage(
        rect: geometry.cardRect,
        renderSize: renderSize,
        radius: geometry.cardCornerRadius,
        shadow: shadow
      )
      .composited(over: result)
    }

    let clipRect = stage.sourceKind == .window
      ? ArcShotRenderGeometry.windowExportClipRect(geometry.contentRect)
      : geometry.contentRect.pixelAligned
    var sourceImage = videoImage
      .transformed(
        by: geometry.stageVideoTransform(
          canvasSize: renderSize,
          sourceVideoSize: sourceSize,
          sourceKind: stage.sourceKind
        ),
        highQualityDownsample: true
      )
      .cropped(to: clipRect)
    if stage.sourceKind == .window {
      sourceImage = alignWindowStageSourceInClip(
        sourceImage,
        clipRect: clipRect,
        sourceSize: sourceSize
      )
    }
    let clipRadius = stage.sourceKind == .window
      ? (geometry.windowExportClipRadius ?? geometry.sourceCornerRadius)
      : 0
    let clippedSource = clippedImage(
      sourceImage,
      rect: clipRect,
      renderSize: renderSize,
      radius: clipRadius,
      backgroundImage: result,
      continuousCorner: stage.sourceKind == .window
    )
    result = clippedSource
    return result
  }

  /// Re-fit window video into the preview-equivalent aspect-fit rect (centered, uniform scale, no edge trim).
  private func alignWindowStageSourceInClip(
    _ image: CIImage,
    clipRect: CGRect,
    sourceSize: CGSize
  ) -> CIImage {
    let fitInClip = EditorPreviewLayout.aspectFitRect(
      sourceSize: sourceSize,
      in: clipRect.size
    )
    let targetRect = CGRect(
      x: clipRect.minX + fitInClip.minX,
      y: clipRect.minY + fitInClip.minY,
      width: fitInClip.width,
      height: fitInClip.height
    )
    let extent = image.extent
    guard extent.width > 1, extent.height > 1,
          targetRect.width > 1, targetRect.height > 1 else { return image }

    let scale = min(targetRect.width / extent.width, targetRect.height / extent.height)
    let scaledWidth = extent.width * scale
    let scaledHeight = extent.height * scale
    let origin = CGPoint(
      x: targetRect.midX - scaledWidth / 2,
      y: targetRect.midY - scaledHeight / 2
    )
    return image
      .transformed(
        by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
          .scaledBy(x: scale, y: scale)
          .translatedBy(x: origin.x, y: origin.y),
        highQualityDownsample: true
      )
      .cropped(to: clipRect)
  }

  struct StageCardShadow: Equatable {
    var opacity: CGFloat
    var blurRadius: CGFloat
    var offsetY: CGFloat
  }

  static func stageCardShadow(
    stage: ArcShotCompositionInstruction.StageConfig,
    geometry: ArcShotRenderGeometry
  ) -> StageCardShadow? {
    guard stage.useStage,
      stage.sourceKind != .window,
      stage.shadowOpacity > 0,
      stage.shadowRadius > 0
    else { return nil }

    return StageCardShadow(
      opacity: min(1, max(0, stage.shadowOpacity * 0.42)),
      blurRadius: max(0, stage.shadowRadius * geometry.visualScale),
      offsetY: -max(4, abs(stage.shadowYOffset) * geometry.visualScale)
    )
  }

  private func stageShadowImage(
    rect: CGRect,
    renderSize: CGSize,
    radius: CGFloat,
    shadow: StageCardShadow
  ) -> CIImage {
    let renderRect = CGRect(origin: .zero, size: renderSize)
    let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: renderRect)
    let shadowRect = rect.offsetBy(dx: 0, dy: shadow.offsetY)
    let shadowMask = roundedRectangleMask(rect: shadowRect, radius: radius)
      .applyingFilter(
        "CIGaussianBlur",
        parameters: [kCIInputRadiusKey: shadow.blurRadius]
      )
      .cropped(to: renderRect)
    let shadowColor = CIImage(
      color: CIColor(red: 0, green: 0, blue: 0, alpha: shadow.opacity)
    )
    .cropped(to: renderRect)

    return shadowColor
      .applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: transparent,
          kCIInputMaskImageKey: shadowMask,
        ]
      )
      .cropped(to: renderRect)
  }

  private func clippedImage(
    _ image: CIImage,
    rect: CGRect,
    renderSize: CGSize,
    radius: CGFloat,
    backgroundImage: CIImage? = nil,
    continuousCorner: Bool = false
  ) -> CIImage {
    let renderRect = CGRect(origin: .zero, size: renderSize)
    let background = (backgroundImage ?? transparentStageImage(size: renderSize))
      .cropped(to: renderRect)

    guard radius > 0 else {
      return image.composited(over: background).cropped(to: renderRect)
    }

    let aligned = rect.pixelAligned
    let localRect = CGRect(origin: .zero, size: aligned.size)
    let normalize = CGAffineTransform(
      translationX: -aligned.origin.x,
      y: -aligned.origin.y
    )
    let localImage = image
      .transformed(by: normalize)
      .cropped(to: localRect)
    let localBackground = background
      .transformed(by: normalize)
      .cropped(to: localRect)
    let mask = roundedRectangleMask(
      rect: localRect,
      radius: radius,
      continuousCorner: continuousCorner
    )
      .cropped(to: localRect)
    let filledLocal = localImage.composited(over: localBackground)
    let maskedVideo = filledLocal.applyingFilter(
      "CISourceInCompositing",
      parameters: [kCIInputBackgroundImageKey: mask]
    )
    .cropped(to: localRect)
    return maskedVideo
      .transformed(by: CGAffineTransform(translationX: aligned.origin.x, y: aligned.origin.y))
      .composited(over: background)
      .cropped(to: renderRect)
  }

  private func transparentStageImage(size: CGSize) -> CIImage {
    CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: CGRect(origin: .zero, size: size))
  }

  private func stageGeometry(
    renderSize: CGSize,
    stage: ArcShotCompositionInstruction.StageConfig,
    sourceSize: CGSize
  ) -> ArcShotRenderGeometry {
    let contentAspect = EditorPreviewLayout.stageContentAspectRatio(
      outputAspectRatio: max(0.1, renderSize.width / max(1, renderSize.height)),
      sourceKind: stage.sourceKind,
      sourceVideoSize: sourceSize
    )
    return ArcShotRenderGeometry.make(
      stageSize: renderSize,
      contentAspectRatio: contentAspect,
      padding: stage.padding,
      contentInset: stage.contentInset,
      cornerRadius: stage.cornerRadius,
      sourceKind: stage.sourceKind,
      sourceVideoSize: sourceSize
    )
  }

  private func roundedRectangleMask(
    rect: CGRect,
    radius: CGFloat,
    continuousCorner: Bool = false
  ) -> CIImage {
    let clampedRadius = min(max(0, radius), min(rect.width, rect.height) / 2)
    if continuousCorner,
       let mask = continuousRoundedRectangleMask(rect: rect, radius: clampedRadius) {
      return mask
    }

    if let mask = CIFilter(
      name: "CIRoundedRectangleGenerator",
      parameters: [
        "inputExtent": CIVector(cgRect: rect),
        "inputRadius": clampedRadius,
        "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
      ]
    )?.outputImage {
      return mask
    }

    return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
      .cropped(to: rect)
  }

  /// Matches SwiftUI `RoundedRectangle(..., style: .continuous)` used in editor preview.
  private func continuousRoundedRectangleMask(rect: CGRect, radius: CGFloat) -> CIImage? {
    let aligned = rect.pixelAligned
    guard aligned.width >= 1, aligned.height >= 1 else { return nil }

    let layer = CALayer()
    layer.frame = CGRect(origin: .zero, size: aligned.size)
    layer.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous

    let width = Int(aligned.width)
    let height = Int(aligned.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    layer.render(in: context)

    guard let cgImage = context.makeImage() else { return nil }
    return CIImage(cgImage: cgImage)
      .transformed(by: CGAffineTransform(translationX: aligned.origin.x, y: aligned.origin.y))
  }

  private func cachedStageBackgroundImage(
    settings: RecordingProject.ExportVisualSettings,
    renderSize: CGSize
  ) -> CIImage {
    let width = max(1, Int(renderSize.width.rounded()))
    let height = max(1, Int(renderSize.height.rounded()))
    let key = (settings: settings, width: width, height: height)
    if let cachedStageBackgroundKey,
       cachedStageBackgroundKey == key,
       let cachedStageBackgroundImage {
      return cachedStageBackgroundImage
    }
    let image = makeStageBackgroundImage(settings: settings, renderSize: renderSize)
    cachedStageBackgroundKey = key
    cachedStageBackgroundImage = image
    return image
  }

  private func makeStageBackgroundImage(
    settings: RecordingProject.ExportVisualSettings,
    renderSize: CGSize
  ) -> CIImage {
    let extent = CGRect(origin: .zero, size: renderSize)

    switch settings.backgroundKind {
    case .solid:
      return CIImage(color: CIColor(cgColor: Self.parseHexColor(settings.backgroundColorHex)))
        .cropped(to: extent)

    case .linearGradientVertical:
      let startColor = Self.parseHexColor(settings.backgroundColorHex)
      let endColor = Self.parseHexColor(settings.gradientEndColorHex)
      let startPoint: CGPoint
      let endPoint: CGPoint
      if settings.backgroundGradientStyle == .wallpaper {
        startPoint = CGPoint(x: 0, y: renderSize.height)
        endPoint = CGPoint(x: renderSize.width, y: 0)
      } else {
        startPoint = CGPoint(x: renderSize.width / 2, y: renderSize.height)
        endPoint = CGPoint(x: renderSize.width / 2, y: 0)
      }

      guard
        let baseGradient = Self.makeRasterGradientImage(
          size: renderSize,
          startColor: startColor,
          endColor: endColor,
          startPoint: startPoint,
          endPoint: endPoint
        )
      else {
        return CIImage(color: CIColor(cgColor: startColor)).cropped(to: extent)
      }

      var result = baseGradient
      if settings.backgroundGradientStyle == .wallpaper {
        result = applyWallpaperStyleOverlay(to: result, extent: extent)
      }
      if settings.backgroundBlur > 0.5 {
        result = result
          .applyingFilter(
            "CIGaussianBlur",
            parameters: [kCIInputRadiusKey: settings.backgroundBlur]
          )
          .cropped(to: extent)
      }
      return result
    }
  }

  private func applyWallpaperStyleOverlay(to base: CIImage, extent: CGRect) -> CIImage {
    let leftColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.20).cgColor
    let rightColor = NSColor(calibratedRed: 0.35, green: 0.82, blue: 0.78, alpha: 0.18).cgColor
    guard
      let overlay = Self.makeRasterGradientImage(
        size: extent.size,
        startColor: leftColor,
        endColor: rightColor,
        startPoint: CGPoint(x: 0, y: extent.midY),
        endPoint: CGPoint(x: extent.width, y: extent.midY)
      )
    else { return base }

    return overlay.composited(over: base)
  }

  private static func makeRasterGradientImage(
    size: CGSize,
    startColor: CGColor,
    endColor: CGColor,
    startPoint: CGPoint,
    endPoint: CGPoint
  ) -> CIImage? {
    let width = max(1, Int(size.width.rounded()))
    let height = max(1, Int(size.height.rounded()))
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [startColor, endColor] as CFArray,
        locations: [0, 1]
      )
    else { return nil }

    context.drawLinearGradient(
      gradient,
      start: startPoint,
      end: endPoint,
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    guard let cgImage = context.makeImage() else { return nil }
    return CIImage(cgImage: cgImage)
  }

  private static func parseHexColor(_ hex: String) -> CGColor {
    var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if sanitized.hasPrefix("#") { sanitized.removeFirst() }
    guard sanitized.count == 6, let value = UInt64(sanitized, radix: 16) else {
      return NSColor.black.cgColor
    }
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return NSColor(red: r, green: g, blue: b, alpha: 1).cgColor
  }

  private func aspectFitRect(aspectSize: CGSize, inside container: CGRect) -> CGRect {
    guard aspectSize.width > 0, aspectSize.height > 0 else { return container }
    let scale = min(container.width / aspectSize.width, container.height / aspectSize.height)
    let w = aspectSize.width * scale
    let h = aspectSize.height * scale
    return CGRect(
      x: container.midX - w / 2,
      y: container.midY - h / 2,
      width: w,
      height: h
    )
  }

  private enum VisualMaskRender {
    static var blurRadius: CGFloat { VisualMaskStyle.blurRadius }
    static var cornerRadius: CGFloat { VisualMaskStyle.cornerRadius }
    static let minRegionSize: Double = 0.02
  }

  private func applyBlurMasks(
    to image: CIImage,
    masks: [RecordingProject.VisualMask],
    sourceSize: CGSize,
    timeSeconds: Double
  ) -> CIImage {
    let blurMasks = masks.filter { $0.kind == .blur }
    guard !blurMasks.isEmpty else { return image }

    var result = image
    for mask in blurMasks {
      let opacity = VisualMaskStyle.activeOpacity(at: timeSeconds, mask: mask)
      guard opacity > 0.001 else { continue }

      let rect = ExportVideoGeometry.maskBlurSourceRect(
        originXN: mask.originXN,
        originYN: mask.originYN,
        widthN: mask.widthN,
        heightN: mask.heightN,
        sourceSize: sourceSize
      )
      result = applyBlurredRegion(
        to: result,
        rect: rect,
        radius: VisualMaskRender.blurRadius,
        cornerRadius: VisualMaskRender.cornerRadius,
        opacity: CGFloat(opacity)
      )
    }
    return result
  }

  private func applyBlurredRegion(
    to image: CIImage,
    rect: CGRect,
    radius: CGFloat,
    cornerRadius: CGFloat,
    opacity: CGFloat
  ) -> CIImage {
    let cropped = image.cropped(to: rect)
    let blurred = cropped
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: rect)

    let alphaMask = roundedRectangleMask(rect: rect, radius: cornerRadius)
      .cropped(to: image.extent)
    let weightedMask = alphaMask.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
      ]
    )

    return blurred.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: image,
        kCIInputMaskImageKey: weightedMask,
      ]
    )
  }

  // MARK: - CPU overlays

  private struct CursorDrawState {
    var position: CGPoint
    var shape: RecordingProject.CursorShape?
    var clickPulse: CGFloat?
    var ringPhase: CGFloat
    var sizeScale: CGFloat
    var pointerStyle: RecordingProject.CursorVisualSettings.PointerStyle
  }

  private func drawCPUOverlays(
    into pixelBuffer: CVPixelBuffer,
    instruction: ArcShotCompositionInstruction,
    timeSeconds: Double,
    sourceTransform: CGAffineTransform,
    sourceSize: CGSize
  ) {
    let renderSize = instruction.renderSize
    let cursorState = cursorDrawState(
      renderSize: renderSize,
      timeSeconds: timeSeconds,
      sourceTransform: sourceTransform,
      sourceSize: sourceSize,
      cursor: instruction.cursor
    )
    let activeMasks = instruction.visualMasks.filter {
      VisualMaskStyle.activeOpacity(at: timeSeconds, mask: $0) > 0.001
    }
    let activeTextOverlays = instruction.textOverlays.filter {
      overlayOpacity(
        timeSeconds: timeSeconds,
        startSeconds: $0.startSeconds,
        endSeconds: $0.endSeconds,
        fadeSeconds: 0.05
      ) > 0.001
    }
    let fadeOpacity = fadeOpacity(
      timeSeconds: timeSeconds,
      fade: instruction.fade
    )

    guard cursorState != nil || !activeMasks.isEmpty || !activeTextOverlays.isEmpty || fadeOpacity > 0.001 else {
      return
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let cgContext = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }

    for mask in activeMasks where mask.kind == .highlight {
      drawVisualMask(
        mask,
        in: cgContext,
        renderSize: renderSize,
        sourceTransform: sourceTransform,
        sourceSize: sourceSize,
        timeSeconds: timeSeconds
      )
    }

    if let cursorState {
      let renderer = CursorRenderer(
        sizeScale: cursorState.sizeScale,
        pointerStyle: cursorState.pointerStyle
      )
      // カーソル位置は CIImage レンダー空間（下原点）。矢印パスは top-down 前提で描かれている
      // ため、このカーソル描画の間だけコンテキストを上下反転し、矢印の向き・位置を映像に
      // 一致させる（マスク／テキストは反転に弱いので触らない）。
      cgContext.saveGState()
      cgContext.translateBy(x: 0, y: renderSize.height)
      cgContext.scaleBy(x: 1, y: -1)
      renderer.drawCursor(
        in: cgContext,
        at: cursorState.position,
        shape: cursorState.shape,
        clickPulseProgress: cursorState.clickPulse,
        ringPulsePhase: cursorState.ringPhase
      )
      cgContext.restoreGState()
    }

    for overlay in activeTextOverlays {
      drawTextOverlay(
        overlay,
        in: cgContext,
        renderSize: renderSize,
        timeSeconds: timeSeconds
      )
    }

    if fadeOpacity > 0.001 {
      cgContext.setFillColor(NSColor.black.withAlphaComponent(fadeOpacity).cgColor)
      cgContext.fill(CGRect(origin: .zero, size: renderSize))
    }
  }

  private func cursorDrawState(
    renderSize: CGSize,
    timeSeconds: Double,
    sourceTransform: CGAffineTransform,
    sourceSize: CGSize,
    cursor: ArcShotCompositionInstruction.CursorState
  ) -> CursorDrawState? {
    guard cursor.settings.isVisible, !cursor.samples.isEmpty else { return nil }

    let (cx, cy, shape) = CursorRenderer.interpolateCursorPosition(
      at: timeSeconds, samples: cursor.samples
    )

    if cursor.settings.hideWhenIdle {
      let hasRecentActivity = cursor.samples.contains {
        abs($0.timeSeconds - timeSeconds) < 0.18
      }
      guard hasRecentActivity else { return nil }
    }

    let isInHighlight = cursor.highlightRegions.isEmpty ||
      cursor.highlightRegions.contains {
        timeSeconds >= $0.startSeconds && timeSeconds < $0.endSeconds
      }
    guard isInHighlight else { return nil }

    // カーソル座標 (cx, cy) は録画時の画面座標＝下原点（y=1 が上端）。これは CIImage の
    // 下原点と一致するので、映像と同じ sourceTransform（zoom・ステージ配置を含む）に cy を
    // そのまま渡すと、映像（ciContext で描画）と同じ CIImage レンダー空間（下原点）の座標が得られる。
    // この座標のまま、描画側で下原点コンテキストに合わせて矢印を描く（drawCPUOverlays 参照）。
    let cursorPx = ExportVideoGeometry.normalizedSourcePoint(
      x: cx,
      y: cy,
      sourceSize: sourceSize
    )
    let transformed = cursorPx.applying(sourceTransform)
    // transformed は CIImage レンダー空間（下原点）。映像は ciContext が下原点→top-down に
    // 変換して描かれるので、カーソルの表示位置も `renderHeight - y` で top-down に合わせる。
    // 矢印の向きは drawCPUOverlays 側のコンテキスト反転で正す。
    let zoomedCursorPx = CGPoint(x: transformed.x, y: renderSize.height - transformed.y)

    guard zoomedCursorPx.x >= -50 && zoomedCursorPx.x <= renderSize.width + 50 &&
          zoomedCursorPx.y >= -50 && zoomedCursorPx.y <= renderSize.height + 50 else {
      return nil
    }

    return CursorDrawState(
      position: zoomedCursorPx,
      shape: shape,
      clickPulse: CursorRenderer.clickPulseProgress(
        at: timeSeconds,
        clickCues: cursor.clickCues
      ),
      ringPhase: CGFloat(timeSeconds.truncatingRemainder(dividingBy: 0.6) / 0.6),
      sizeScale: CGFloat(cursor.settings.sizeScale),
      pointerStyle: cursor.settings.pointerStyle
    )
  }

  private func sourceToRenderTransform(
    zoomTransform: CGAffineTransform,
    renderSize: CGSize,
    stage: ArcShotCompositionInstruction.StageConfig,
    sourceSize: CGSize
  ) -> CGAffineTransform {
    guard stage.useStage else { return zoomTransform }
    let geometry = stageGeometry(renderSize: renderSize, stage: stage, sourceSize: sourceSize)
    return zoomTransform.concatenating(geometry.contentTransform(from: renderSize))
  }

  private func drawVisualMask(
    _ mask: RecordingProject.VisualMask,
    in context: CGContext,
    renderSize: CGSize,
    sourceTransform: CGAffineTransform,
    sourceSize: CGSize,
    timeSeconds: Double
  ) {
    let opacity = VisualMaskStyle.activeOpacity(at: timeSeconds, mask: mask)
    guard opacity > 0.001 else { return }

    let topDownRect = ExportVideoGeometry.maskRenderRect(
      originXN: mask.originXN,
      originYN: mask.originYN,
      widthN: mask.widthN,
      heightN: mask.heightN,
      sourceSize: sourceSize,
      sourceTransform: sourceTransform,
      renderSize: renderSize
    )
    let rect = topDownRect
    let path = CGPath(
      roundedRect: rect,
      cornerWidth: VisualMaskRender.cornerRadius,
      cornerHeight: VisualMaskRender.cornerRadius,
      transform: nil
    )

    context.saveGState()
    context.setAlpha(CGFloat(opacity))
    context.setFillColor(NSColor.systemYellow.withAlphaComponent(VisualMaskStyle.highlightFillOpacity).cgColor)
    context.addPath(path)
    context.fillPath()
    context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(VisualMaskStyle.highlightStrokeOpacity).cgColor)
    context.setLineWidth(VisualMaskStyle.highlightStrokeWidth)
    context.addPath(path)
    context.strokePath()
    context.restoreGState()
  }

  private func drawTextOverlay(
    _ overlay: RecordingProject.TextOverlayAnnotation,
    in context: CGContext,
    renderSize: CGSize,
    timeSeconds: Double
  ) {
    let opacity = overlayOpacity(
      timeSeconds: timeSeconds,
      startSeconds: overlay.startSeconds,
      endSeconds: overlay.endSeconds,
      fadeSeconds: 0.05
    )
    guard opacity > 0.001, !overlay.text.isEmpty else { return }

    let rect = ExportVideoGeometry.textOverlayRenderRect(
      originXN: overlay.originXN,
      originYN: overlay.originYN,
      widthN: overlay.widthN,
      heightN: overlay.heightN,
      renderSize: renderSize
    )
    let cornerRadius: CGFloat = 6
    let backgroundPath = CGPath(
      roundedRect: rect,
      cornerWidth: cornerRadius,
      cornerHeight: cornerRadius,
      transform: nil
    )

    context.saveGState()
    context.setAlpha(opacity)
    context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(backgroundPath)
    context.fillPath()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(overlay.fontPointSize), nil)
    let attributed = NSAttributedString(
      string: overlay.text,
      attributes: [
        .font: font,
        .foregroundColor: NSColor.white.cgColor,
        .paragraphStyle: paragraph,
      ]
    )

    context.textMatrix = .identity
    let textInset = max(8, CGFloat(overlay.fontPointSize) * 0.35)
    let textRect = rect.insetBy(dx: textInset, dy: textInset * 0.55)
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CTFramesetterCreateFrame(
      framesetter,
      CFRange(location: 0, length: attributed.length),
      CGPath(rect: textRect, transform: nil),
      nil
    )
    CTFrameDraw(frame, context)
    context.restoreGState()
  }

  private func overlayOpacity(
    timeSeconds: Double,
    startSeconds: Double,
    endSeconds: Double,
    fadeSeconds: Double
  ) -> CGFloat {
    let start = max(0, startSeconds)
    let end = max(start, endSeconds)
    let fade = max(1e-3, fadeSeconds)
    guard timeSeconds >= start - fade, timeSeconds <= end + fade else { return 0 }
    if timeSeconds < start + fade {
      return CGFloat(max(0, min(1, (timeSeconds - (start - fade)) / (fade * 2))))
    }
    if timeSeconds > end - fade {
      return CGFloat(max(0, min(1, ((end + fade) - timeSeconds) / (fade * 2))))
    }
    return 1
  }

  private func fadeOpacity(
    timeSeconds: Double,
    fade: ArcShotCompositionInstruction.FadeConfig
  ) -> CGFloat {
    var opacity: CGFloat = 0

    if fade.introFadeSeconds > 1e-3 && timeSeconds < fade.introFadeSeconds {
      opacity = max(opacity, CGFloat(1 - timeSeconds / fade.introFadeSeconds))
    }

    let outroStart = fade.totalDurationSeconds - fade.outroFadeSeconds
    if fade.outroFadeSeconds > 1e-3 && timeSeconds > outroStart {
      let progress = (timeSeconds - outroStart) / fade.outroFadeSeconds
      opacity = max(opacity, CGFloat(min(1, progress)))
    }

    return opacity
  }
}
