import AVFoundation
import CoreMedia
import Foundation

/// Builds a trivial two-track `AVMutableComposition` — main full-bleed timeline + optional PiP inset — for export.
enum ExportMixedCompositionBuilder {
  enum BuilderError: LocalizedError {
    case noMainVideo
    case noPipVideo

    var errorDescription: String? {
      switch self {
      case .noMainVideo: return "Main asset has no video track."
      case .noPipVideo: return "PiP asset has no video track."
      }
    }
  }

  struct MixResult: @unchecked Sendable {
    var composition: AVMutableComposition
    var mainVideoTrack: AVAssetTrack
    var pipVideoTrack: AVAssetTrack
    /// Timeline into the composition (`start` is `.zero` after insert).
    var compositionVideoTimeRange: CMTimeRange
    var includesMainAudioTrack: Bool
  }

  /// Aligns PiP from absolute t=0 over the same trimmed window as the primary movie.
  static func build(
    mainAsset: AVURLAsset,
    pipAsset: AVURLAsset,
    mainTrim: CMTimeRange?
  ) async throws -> MixResult {
    let srcMainCandidates = try await mainAsset.loadTracks(withMediaType: .video)
    let srcPipCandidates = try await pipAsset.loadTracks(withMediaType: .video)
    guard let srcMain = srcMainCandidates.first else { throw BuilderError.noMainVideo }
    guard let srcPip = srcPipCandidates.first else { throw BuilderError.noPipVideo }

    let assetMainDuration = try await mainAsset.load(.duration)

    let mainRange: CMTimeRange = {
      guard let mainTrim, mainTrim.duration > .zero else {
        return CMTimeRange(start: .zero, duration: assetMainDuration.isNumeric ? assetMainDuration : .positiveInfinity)
      }
      return mainTrim
    }()

    let comp = AVMutableComposition()
    guard let vMain = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw BuilderError.noMainVideo
    }
    guard let vPip = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw BuilderError.noPipVideo
    }

    try vMain.insertTimeRange(mainRange, of: srcMain, at: .zero)

    let pipDurFull = try await pipAsset.load(.duration)
    let pipDur = pipDurFull.isNumeric ? pipDurFull : .zero
    let pipAvailable = pipDur > mainRange.start ? pipDur - mainRange.start : .zero
    let pipUse = CMTimeCompare(pipAvailable, mainRange.duration) >= 0 ? mainRange.duration : pipAvailable
    if pipUse > .zero {
      let pipSlice = CMTimeRange(start: mainRange.start, duration: pipUse)
      try vPip.insertTimeRange(pipSlice, of: srcPip, at: .zero)
    }

    var includesAudio = false
    let audioTracks = try await mainAsset.loadTracks(withMediaType: .audio)
    for srcAudio in audioTracks {
      guard let aMut = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        continue
      }
      try aMut.insertTimeRange(mainRange, of: srcAudio, at: .zero)
      includesAudio = true
    }

    return MixResult(
      composition: comp,
      mainVideoTrack: vMain,
      pipVideoTrack: vPip,
      compositionVideoTimeRange: CMTimeRange(start: .zero, duration: mainRange.duration),
      includesMainAudioTrack: includesAudio
    )
  }
}
