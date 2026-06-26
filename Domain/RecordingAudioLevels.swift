import Foundation

/// Named capture / playback levels for screen recordings (avoid magic numbers in writer + mix).
///
/// Target effective gain ≈ 1.25–1.30 (between the too-quiet 1.15 stack and the too-loud ~1.5 stack).
enum RecordingAudioLevels {
  static let microphoneCaptureGain: Float = 1.0
  static let systemCaptureGain: Float = 1.2
  static let defaultMicrophonePlaybackVolume: Double = 1.30
  static let defaultSystemPlaybackVolume: Double = 1.18
  static let defaultSystemPlaybackVolumeWithMicrophone: Double = 0.92
}
