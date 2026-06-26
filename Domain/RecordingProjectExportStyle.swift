import Foundation

extension RecordingProject {
  /// User zoom keyframes plus optional **soft zoom base** spanning the export window.
  /// Overlap policy prefers the keyframe with the **latest** `startSeconds`.
  /// Soft-zoom base starts at `exportStartSeconds` (earliest); user clips override overlapping intervals.
  static func effectiveZoomKeyframes(
    stylePreset: StylePresetID,
    userKeyframes: [ZoomKeyframe],
    exportStartSeconds: Double,
    exportEndSeconds: Double,
    softZoomScale: Double
  ) -> [ZoomKeyframe] {
    let start = min(exportStartSeconds, exportEndSeconds)
    let end = max(exportStartSeconds, exportEndSeconds)
    guard end - start > 0.01 else { return userKeyframes }

    guard stylePreset == .softZoom else {
      return userKeyframes
    }

    let scale = StyleSettingsDefaults.clampedSoftZoomScale(softZoomScale)
    guard scale > 1.0001 else { return userKeyframes }

    let base = ZoomKeyframe(
      id: ExportStyleConstants.softZoomSyntheticID,
      startSeconds: start,
      endSeconds: end,
      scale: scale,
      anchorX: 0.5,
      anchorY: 0.5
    )
    return (userKeyframes + [base]).sorted { $0.startSeconds < $1.startSeconds }
  }
}

enum ExportStyleConstants {
  static let softZoomSyntheticID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
}
