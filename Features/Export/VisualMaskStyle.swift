import CoreGraphics
import SwiftUI

/// Shared visual-mask timing and style constants for editor preview and export compositor.
enum VisualMaskStyle {
  static let cornerRadius: CGFloat = 12
  static let blurRadius: CGFloat = 28
  static let highlightFillOpacity: Double = 0.12
  static let highlightStrokeOpacity: Double = 0.86
  static let highlightStrokeWidth: CGFloat = 4

  static func fadeSeconds(startSeconds: Double, endSeconds: Double) -> Double {
    min(0.08, max(0.01, (endSeconds - startSeconds) * 0.2))
  }

  static func envelopeOpacity(
    at timeSeconds: Double,
    startSeconds: Double,
    endSeconds: Double
  ) -> Double {
    guard timeSeconds.isFinite else { return 0 }
    let start = max(0, startSeconds)
    let end = max(start, endSeconds)
    let fade = fadeSeconds(startSeconds: startSeconds, endSeconds: endSeconds)
    guard timeSeconds >= start - fade, timeSeconds <= end + fade else { return 0 }

    if timeSeconds < start + fade {
      return max(0, min(1, (timeSeconds - (start - fade)) / (fade * 2)))
    }
    if timeSeconds > end - fade {
      return max(0, min(1, ((end + fade) - timeSeconds) / (fade * 2)))
    }
    return 1
  }

  static func activeOpacity(at timeSeconds: Double, mask: RecordingProject.VisualMask) -> Double {
    max(0, min(1, envelopeOpacity(
      at: timeSeconds,
      startSeconds: mask.startSeconds,
      endSeconds: mask.endSeconds
    ) * mask.opacity))
  }

  static func isActive(at timeSeconds: Double, mask: RecordingProject.VisualMask) -> Bool {
    activeOpacity(at: timeSeconds, mask: mask) > 0.001
  }

  /// Maps export Gaussian radius (source pixels) to SwiftUI blur radius in preview points.
  static func previewBlurRadius(sourceSize: CGSize, videoRect: CGRect) -> CGFloat {
    guard sourceSize.width > 1, videoRect.width > 1 else { return blurRadius }
    return blurRadius * (videoRect.width / sourceSize.width)
  }
}
