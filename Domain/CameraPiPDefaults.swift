import CoreGraphics

enum CameraPiPDefaults {
  /// PiP edge length as a fraction of the **output frame height** (square in pixel space).
  static let pipSizeN = 0.22
  static let marginN = 0.02
  static let cornerRadiusPts = 16.0

  /// Live preview panel on screen during recording (square face-cam; matches export PiP shape).
  static let previewPanelWidth: CGFloat = 200
  static let previewPanelHeight: CGFloat = 200
  static let previewScreenMargin: CGFloat = 20

  struct NormalizedGeometry: Equatable {
    var originXN: Double
    var originYN: Double
    var widthN: Double
    var heightN: Double

    func pixelSize(for renderSize: CGSize) -> CGSize {
      CGSize(
        width: widthN * renderSize.width,
        height: heightN * renderSize.height
      )
    }
  }

  /// Width/height normalized fractions that form a square in pixel space for the given output frame.
  static func normalizedSquareSize(videoWidth: Double, videoHeight: Double) -> (widthN: Double, heightN: Double) {
    guard videoWidth > 1, videoHeight > 1 else {
      return (pipSizeN, pipSizeN)
    }
    let heightN = pipSizeN
    let widthN = pipSizeN * (videoHeight / videoWidth)
    return (widthN, heightN)
  }

  static func bottomTrailingOrigin(widthN: Double, heightN: Double) -> (originXN: Double, originYN: Double) {
    (
      max(0, 1 - marginN - widthN),
      max(0, 1 - marginN - heightN)
    )
  }

  static func bottomTrailingSquarePiP(videoWidth: Double, videoHeight: Double) -> NormalizedGeometry {
    let (widthN, heightN) = normalizedSquareSize(videoWidth: videoWidth, videoHeight: videoHeight)
    let origin = bottomTrailingOrigin(widthN: widthN, heightN: heightN)
    return NormalizedGeometry(
      originXN: origin.originXN,
      originYN: origin.originYN,
      widthN: widthN,
      heightN: heightN
    )
  }

  /// Legacy accessors — prefer `bottomTrailingSquarePiP(videoWidth:videoHeight:)`.
  static var widthN: Double { pipSizeN }
  static var heightN: Double { pipSizeN }
  static var bottomTrailingOrigin: (originXN: Double, originYN: Double) {
    bottomTrailingOrigin(widthN: pipSizeN, heightN: pipSizeN)
  }
}
