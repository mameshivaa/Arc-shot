import AppKit
import AVFoundation
import Observation
import SwiftUI

struct PlaybackPreviewRange: Equatable {
  var sourceStartSeconds: Double
  var sourceEndSeconds: Double
  var playbackRate: Double = 1

  var durationSeconds: Double {
    max(0, sourceEndSeconds - sourceStartSeconds) / normalizedRate
  }

  private var normalizedRate: Double {
    max(playbackRate, 1e-9)
  }

  func sourceSeconds(forPreviewSeconds seconds: Double) -> Double {
    sourceStartSeconds + max(0, min(seconds, durationSeconds)) * normalizedRate
  }

  func previewSeconds(forSourceSeconds seconds: Double) -> Double {
    max(0, min(durationSeconds, (seconds - sourceStartSeconds) / normalizedRate))
  }

  func containsSourceSeconds(_ seconds: Double) -> Bool {
    seconds >= sourceStartSeconds && seconds < sourceEndSeconds
  }
}

@MainActor
@Observable
final class EditorPlaybackController {
  var player: AVPlayer?
  var durationSeconds: Double = 0
  var sourceDurationSeconds: Double = 0
  var sourceVideoSize: CGSize = .zero
  var currentTimeSeconds: Double = 0
  var isPlaying = false

  private var projectID: UUID?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var suppressTimelineTimePublishing = false
  private var playerDurationSeconds: Double = 0
  private var previewRange: PlaybackPreviewRange?

  func load(project: RecordingProject, force: Bool = false, completion: (() -> Void)? = nil) {
    guard force || projectID != project.id else {
      completion?()
      return
    }
    cleanup()
    projectID = project.id

    Task {
      let loadedProjectID = project.id
      let item = await Self.makePlayerItem(project: project)
      let loadedTime = try? await item.asset.load(.duration)
      let loadedDuration = loadedTime?.seconds ?? 0
      let sourceDuration = await Self.loadSourceDurationSeconds(project: project)
      let sourceVideoSize = await Self.loadSourceVideoSize(project: project)
      await MainActor.run {
        guard self.projectID == loadedProjectID else { return }
        self.attachPlayerItem(
          item,
          durationSeconds: max(0, loadedDuration.isFinite ? loadedDuration : 0),
          sourceDurationSeconds: sourceDuration,
          sourceVideoSize: sourceVideoSize
        )
        completion?()
      }
    }
  }

  private func attachPlayerItem(
    _ item: AVPlayerItem,
    durationSeconds: Double,
    sourceDurationSeconds: Double,
    sourceVideoSize: CGSize
  ) {
    cleanupPlayerOnly()
    let avPlayer = AVPlayer(playerItem: item)
    player = avPlayer
    playerDurationSeconds = durationSeconds
    self.sourceDurationSeconds = sourceDurationSeconds
    self.sourceVideoSize = sourceVideoSize
    publishDurationForCurrentRange()

    timeObserver = avPlayer.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        if !self.suppressTimelineTimePublishing {
          self.publishCurrentTimeFromSourceSeconds(time.seconds)
        }
        let nextIsPlaying = avPlayer.rate > 1e-9
        if self.isPlaying != nextIsPlaying {
          self.isPlaying = nextIsPlaying
        }
      }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isPlaying = false
        if self.previewRange != nil {
          self.currentTimeSeconds = self.durationSeconds
        } else {
          self.seek(to: 0)
        }
      }
    }

    if previewRange != nil {
      seek(to: currentTimeSeconds)
    }
  }

  private static func makePlayerItem(project: RecordingProject) async -> AVPlayerItem {
    if project.timeline.singleEditableClip != nil {
      let asset = AVURLAsset(url: project.mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      if let composition = try? await makeSingleAssetPreviewComposition(project: project) {
        return await playerItem(asset: composition, project: project)
      }
      return await playerItem(asset: asset, project: project)
    }
    guard project.timeline.hasActiveClips,
      let composition = try? await makeTimelinePreviewComposition(project: project)
    else {
      let asset = AVURLAsset(url: project.mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      if let composition = try? await makeSingleAssetPreviewComposition(project: project) {
        return await playerItem(asset: composition, project: project)
      }
      return await playerItem(asset: asset, project: project)
    }
    return await playerItem(asset: composition, project: project)
  }

  private static func loadSourceDurationSeconds(project: RecordingProject) async -> Double {
    let asset = AVURLAsset(url: project.mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let duration = try? await asset.load(.duration),
      duration.isNumeric,
      duration.seconds.isFinite
    else { return 0 }
    return max(0, duration.seconds)
  }

  private static func loadSourceVideoSize(project: RecordingProject) async -> CGSize {
    let asset = AVURLAsset(url: project.mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
      let naturalSize = try? await track.load(.naturalSize)
    else { return .zero }

    let transform = (try? await track.load(.preferredTransform)) ?? .identity
    let oriented = naturalSize.applying(transform)
    return CGSize(width: abs(oriented.width), height: abs(oriented.height))
  }

  static func makeTimelinePreviewComposition(project: RecordingProject) async throws -> AVMutableComposition? {
    let clips = project.timeline.activeClips
    guard !clips.isEmpty else { return nil }

    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      return nil
    }
    var audioTracksByIndex: [Int: AVMutableCompositionTrack] = [:]
    var hasVideo = false
    var previewDurationSeconds = 0.0

    for clip in clips {
      let asset = AVURLAsset(url: clip.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let sourceVideo = videoTracks.first else { continue }
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      let assetDuration = try await asset.load(.duration)
      let assetDurationSeconds = assetDuration.isNumeric ? max(0, assetDuration.seconds) : clip.durationSeconds
      let rate = project.timeline.speedRate(
        forTimelineRangeStart: clip.timelineStartSeconds,
        end: clip.timelineStartSeconds + clip.durationSeconds
      )
      let sourceStart = max(0, min(clip.sourceStartSeconds, assetDurationSeconds))
      let sourceDuration = min(max(0.001, clip.durationSeconds * rate), max(0, assetDurationSeconds - sourceStart))
      guard sourceDuration > RecordingProject.TimelineEditing.minClipDurationSeconds else { continue }

      let sourceRange = CMTimeRange(
        start: CMTime(seconds: sourceStart, preferredTimescale: 600),
        duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)
      )
      let insertAt = CMTime(seconds: clip.timelineStartSeconds, preferredTimescale: 600)
      try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: insertAt)
      if abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 {
        videoTrack.scaleTimeRange(
          CMTimeRange(start: insertAt, duration: sourceRange.duration),
          toDuration: CMTime(seconds: clip.durationSeconds, preferredTimescale: 600)
        )
      }
      hasVideo = true
      previewDurationSeconds = max(previewDurationSeconds, clip.timelineStartSeconds + clip.durationSeconds)

      let clipTimelineDuration = CMTime(seconds: clip.durationSeconds, preferredTimescale: 600)
      let clipTimelineRange = CMTimeRange(start: insertAt, duration: clipTimelineDuration)
      for (audioIndex, audioTrack) in audioTracks.enumerated() {
        if audioTracksByIndex[audioIndex] == nil {
          guard let newTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          ) else { continue }
          if insertAt > .zero {
            newTrack.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: insertAt))
          }
          audioTracksByIndex[audioIndex] = newTrack
        }
        guard let compAudio = audioTracksByIndex[audioIndex] else { continue }
        try compAudio.insertTimeRange(sourceRange, of: audioTrack, at: insertAt)
        if abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 {
          compAudio.scaleTimeRange(
            CMTimeRange(start: insertAt, duration: sourceRange.duration),
            toDuration: clipTimelineDuration
          )
        }
      }
      for (existingIndex, existingTrack) in audioTracksByIndex where existingIndex >= audioTracks.count {
        existingTrack.insertEmptyTimeRange(clipTimelineRange)
      }
    }

    if hasVideo {
      try await addBackgroundMusicIfNeeded(
        to: composition,
        duration: CMTime(seconds: previewDurationSeconds, preferredTimescale: 600),
        project: project
      )
    }
    return hasVideo ? composition : nil
  }

  static func makeSingleAssetPreviewComposition(project: RecordingProject) async throws -> AVMutableComposition? {
    guard shouldAddBackgroundMusic(project: project) else { return nil }

    let asset = AVURLAsset(url: project.mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard let sourceVideo = videoTracks.first else { return nil }
    let loadedDuration = try await asset.load(.duration)
    guard loadedDuration.isNumeric, loadedDuration > .zero else { return nil }

    let sourceRange = CMTimeRange(start: .zero, duration: loadedDuration)
    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      return nil
    }
    try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: .zero)
    if let transform = try? await sourceVideo.load(.preferredTransform) {
      videoTrack.preferredTransform = transform
    }

    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    for audioTrack in audioTracks {
      guard let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        continue
      }
      try compositionAudio.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
    }

    try await addBackgroundMusicIfNeeded(to: composition, duration: loadedDuration, project: project)
    return composition
  }

  private static func playerItem(
    asset: AVAsset,
    project: RecordingProject
  ) async -> AVPlayerItem {
    let item = AVPlayerItem(asset: asset)
    guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio) else {
      return item
    }
    let loadedDuration = try? await asset.load(.duration)
    let durationSeconds = loadedDuration?.isNumeric == true ? max(0, loadedDuration!.seconds) : 0
    guard let mix = previewAudioMix(
      for: audioTracks,
      settings: project.audioTrackSettings,
      audioSegments: project.audioTimelineSegments,
      compositionDurationSeconds: durationSeconds
    ) else {
      return item
    }
    item.audioMix = mix
    return item
  }

  static func previewAudioMix(
    for tracks: [AVAssetTrack],
    settings: RecordingProject.AudioTrackSettings,
    audioSegments: [RecordingProject.AudioTimelineSegment],
    compositionDurationSeconds: Double
  ) -> AVAudioMix? {
    guard !tracks.isEmpty else { return nil }
    let hasExplicitSettings =
      settings.microphone.isEnabled
      || settings.system.isEnabled
      || settings.backgroundMusic.isEnabled
      || settings.recordedTrackRoles != nil
      || !audioSegments.isEmpty
    guard hasExplicitSettings else { return nil }

    let mix = AVMutableAudioMix()
    mix.inputParameters = RecordingProjectAudioMix.makeInputParameters(
      for: tracks,
      settings: settings,
      audioSegments: audioSegments,
      compositionDurationSeconds: compositionDurationSeconds
    )
    return mix
  }

  private static func shouldAddBackgroundMusic(project: RecordingProject) -> Bool {
    guard project.audioTrackSettings.backgroundMusic.isEnabled,
      let url = project.audioTrackSettings.backgroundMusicURL
    else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  private static func addBackgroundMusicIfNeeded(
    to composition: AVMutableComposition,
    duration: CMTime,
    project: RecordingProject
  ) async throws {
    guard shouldAddBackgroundMusic(project: project),
      let musicURL = project.audioTrackSettings.backgroundMusicURL,
      duration > .zero
    else { return }

    let musicAsset = AVURLAsset(url: musicURL)
    let tracks = try await musicAsset.loadTracks(withMediaType: .audio)
    guard let musicTrack = tracks.first else { return }
    let loadedDuration = try await musicAsset.load(.duration)
    let musicDuration = loadedDuration.isNumeric ? loadedDuration : duration
    guard musicDuration > .zero,
      let compositionMusic = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { return }

    var cursor = CMTime.zero
    while cursor < duration {
      let remaining = CMTimeSubtract(duration, cursor)
      let sliceDuration = min(remaining, musicDuration)
      let range = CMTimeRange(start: .zero, duration: sliceDuration)
      try compositionMusic.insertTimeRange(range, of: musicTrack, at: cursor)
      cursor = CMTimeAdd(cursor, sliceDuration)
    }
  }

  func updatePreviewRange(
    sourceStartSeconds: Double,
    sourceEndSeconds: Double,
    playbackRate: Double = 1
  ) {
    let start = max(0, sourceStartSeconds)
    let end = max(start, sourceEndSeconds)
    guard end > start else {
      clearPreviewRange()
      return
    }
    previewRange = PlaybackPreviewRange(
      sourceStartSeconds: start,
      sourceEndSeconds: end,
      playbackRate: playbackRate
    )
    publishDurationForCurrentRange()
    currentTimeSeconds = max(0, min(currentTimeSeconds, durationSeconds))
  }

  func clearPreviewRange() {
    previewRange = nil
    publishDurationForCurrentRange()
    currentTimeSeconds = max(0, min(currentTimeSeconds, durationSeconds))
  }

  func togglePlayback() {
    guard let player else { return }
    if player.rate > 1e-9 {
      pause()
    } else {
      playWithinPreviewRange(player)
    }
  }

  func pause() {
    player?.pause()
    isPlaying = false
  }

  func applyAudioSettings(project: RecordingProject) {
    guard let item = player?.currentItem else { return }
    Task {
      let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
      let loadedDuration = try? await item.asset.load(.duration)
      let durationSeconds = loadedDuration?.isNumeric == true ? max(0, loadedDuration!.seconds) : 0
      let mix = Self.previewAudioMix(
        for: tracks,
        settings: project.audioTrackSettings,
        audioSegments: project.audioTimelineSegments,
        compositionDurationSeconds: durationSeconds
      )
      await MainActor.run {
        guard self.player?.currentItem === item else { return }
        item.audioMix = mix
      }
    }
  }

  func beginTimelineInteraction() {
    suppressTimelineTimePublishing = true
    pause()
  }

  func endTimelineInteraction() {
    suppressTimelineTimePublishing = false
  }

  func seek(by delta: Double) {
    seek(to: currentTimeSeconds + delta)
  }

  func seek(to seconds: Double, completion: (@MainActor @Sendable () -> Void)? = nil) {
    let capped = max(0, min(seconds, max(0, durationSeconds)))
    let sourceSeconds = previewRange?.sourceSeconds(forPreviewSeconds: capped) ?? capped
    if suppressTimelineTimePublishing {
      currentTimeSeconds = capped
    }
    guard let player else {
      currentTimeSeconds = capped
      completion?()
      return
    }
    player.seek(to: CMTime(seconds: sourceSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      guard finished else { return }
      Task { @MainActor in
        self?.currentTimeSeconds = capped
        completion?()
      }
    }
  }

  private func publishDurationForCurrentRange() {
    durationSeconds = previewRange?.durationSeconds ?? playerDurationSeconds
  }

  private func publishCurrentTimeFromSourceSeconds(_ sourceSeconds: Double) {
    if let range = previewRange {
      if sourceSeconds >= range.sourceEndSeconds {
        pause()
        currentTimeSeconds = range.durationSeconds
        return
      }
      if sourceSeconds < range.sourceStartSeconds {
        currentTimeSeconds = 0
        return
      }
      let nextSeconds = range.previewSeconds(forSourceSeconds: sourceSeconds)
      if abs(nextSeconds - currentTimeSeconds) >= 1.0 / 120.0 {
        currentTimeSeconds = nextSeconds
      }
      return
    }

    let nextSeconds = max(0, min(sourceSeconds, max(durationSeconds, 0)))
    if abs(nextSeconds - currentTimeSeconds) >= 1.0 / 120.0 {
      currentTimeSeconds = nextSeconds
    }
  }

  private func playWithinPreviewRange(_ player: AVPlayer) {
    guard let range = previewRange else {
      player.play()
      isPlaying = true
      return
    }

    let sourceSeconds = player.currentTime().seconds
    let rate = Float(max(range.playbackRate, 1e-9))
    if !range.containsSourceSeconds(sourceSeconds) {
      let restartSeconds = sourceSeconds >= range.sourceEndSeconds ? 0 : currentTimeSeconds
      seek(to: restartSeconds) { [weak self] in
        guard let self, self.player === player else { return }
        player.playImmediately(atRate: rate)
        self.isPlaying = true
      }
    } else {
      player.playImmediately(atRate: rate)
      isPlaying = true
    }
  }

  private func cleanup() {
    cleanupPlayerOnly()
    projectID = nil
  }

  private func cleanupPlayerOnly() {
    if let player, let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    player?.pause()
    player = nil
    timeObserver = nil
    endObserver = nil
    playerDurationSeconds = 0
    durationSeconds = 0
    sourceDurationSeconds = 0
    sourceVideoSize = .zero
    currentTimeSeconds = 0
    isPlaying = false
  }
}

struct EditorPlayerLayer: NSViewRepresentable {
  var player: AVPlayer?

  func makeNSView(context: Context) -> PlayerHostView {
    let view = PlayerHostView()
    view.playerLayer.videoGravity = .resizeAspect
    view.playerLayer.backgroundColor = NSColor.clear.cgColor
    view.playerLayer.isOpaque = false
    view.playerLayer.player = player
    return view
  }

  func updateNSView(_ view: PlayerHostView, context: Context) {
    view.playerLayer.videoGravity = .resizeAspect
    view.playerLayer.isOpaque = false
    view.playerLayer.player = player
  }

  final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer = CALayer()
      layer?.backgroundColor = NSColor.clear.cgColor
      layer?.isOpaque = false
      layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
      super.layout()
      playerLayer.frame = bounds
    }
  }
}

enum EditorHexColor {
  static func nsColor(rgbHex raw: String) -> NSColor {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard body.count == 6, body.allSatisfy(\.isHexDigit), let value = UInt64(body, radix: 16) else {
      let fallback = RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageBackgroundFallbackHex
      return nsColor(rgbHex: fallback)
    }
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
  }

  static func rgbHexString(from color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}
