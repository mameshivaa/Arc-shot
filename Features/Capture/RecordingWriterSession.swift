@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

extension CMSampleBuffer: @retroactive @unchecked Sendable {}

/// Owns `AVAssetWriter` work on a single serial queue to avoid cross-thread races.
final class RecordingWriterSession: @unchecked Sendable {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.arcshot.ArcShot",
    category: "CapturePipeline"
  )

  struct SessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private enum SessionConstants {
    static let audioSampleRate: Double = 48_000
    static let audioChannels: Int = 2
    static let audioBitrate: Int = 192_000
    /// Unity gain disables PCM scaling in `gainAdjustedPCMSampleBuffer`.
    static let microphoneWriterGain = RecordingAudioLevels.microphoneCaptureGain
    static let systemWriterGain = RecordingAudioLevels.systemCaptureGain
  }

  private let ioQueue = DispatchQueue(label: AppIdentifiers.DispatchQueueLabels.recordingWriterIO)

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var microphoneInput: AVAssetWriterInput?
  private var systemAudioInput: AVAssetWriterInput?

  private var hasStartedSession = false
  private var hasLoggedWriterFailure = false
  private var timelineOriginPTS: CMTime?
  /// Camera AVCapture mic PTS uses a different clock than SCStream; retime with a monotonic counter.
  private var usesSyntheticMicrophoneTimeline = false
  private var syntheticMicrophonePTS = CMTime.zero
  private var videoSampleCount = 0
  private var systemAudioSampleCount = 0
  private var microphoneSampleCount = 0
  private var droppedVideoNotReadyCount = 0
  private var droppedSystemAudioNotReadyCount = 0
  private var droppedMicrophoneNotReadyCount = 0
  private var lastVideoPTS: CMTime?
  private var lastSystemAudioPTS: CMTime?
  private var lastMicrophonePTS: CMTime?
  private var expectedVideoWidth = 0
  private var expectedVideoHeight = 0
  private var droppedVideoDimensionMismatchCount = 0
  private var pendingSyntheticMicrophoneBuffers: [CMSampleBuffer] = []
  private var droppedMicPendingCount = 0
  private enum SyntheticMicLimits {
    static let maxPendingBuffers = 256
  }

  enum Configuration {
    case videoOnly(URL, videoSettings: [String: Any])
    case videoPlusMicrophone(URL, videoSettings: [String: Any])
    case videoPlusSystemAudio(URL, videoSettings: [String: Any])
    case videoPlusMicrophoneAndSystemAudio(URL, videoSettings: [String: Any])
  }

  func configureAndStartWriting(
    _ configuration: Configuration,
    syntheticMicrophoneTimeline: Bool = false
  ) throws {
    try ioQueue.sync {
      let url: URL
      let videoSettings: [String: Any]
      let microphone: Bool
      let systemAudio: Bool

      switch configuration {
      case .videoOnly(let recordedURL, let settings):
        url = recordedURL
        videoSettings = settings
        microphone = false
        systemAudio = false
      case .videoPlusMicrophone(let recordedURL, let settings):
        url = recordedURL
        videoSettings = settings
        microphone = true
        systemAudio = false
      case .videoPlusSystemAudio(let recordedURL, let settings):
        url = recordedURL
        videoSettings = settings
        microphone = false
        systemAudio = true
      case .videoPlusMicrophoneAndSystemAudio(let recordedURL, let settings):
        url = recordedURL
        videoSettings = settings
        microphone = true
        systemAudio = true
      }

      guard writer == nil else {
        throw SessionError(message: "書き込みセッションはすでに設定済みです。")
      }

      let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)

      let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      newVideoInput.expectsMediaDataInRealTime = true
      guard newWriter.canAdd(newVideoInput) else {
        throw SessionError(message: "書き込みにビデオ入力を追加できませんでした。")
      }
      newWriter.add(newVideoInput)

      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: newVideoInput,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
      )

      var newMicrophoneInput: AVAssetWriterInput?
      if microphone {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: SessionConstants.audioSampleRate,
          AVNumberOfChannelsKey: SessionConstants.audioChannels,
          AVEncoderBitRateKey: SessionConstants.audioBitrate,
        ])
        input.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(input) else {
          throw SessionError(message: "書き込みにマイク入力を追加できませんでした。")
        }
        newWriter.add(input)
        newMicrophoneInput = input
      }

      var newSystemAudioInput: AVAssetWriterInput?
      if systemAudio {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: SessionConstants.audioSampleRate,
          AVNumberOfChannelsKey: SessionConstants.audioChannels,
          AVEncoderBitRateKey: SessionConstants.audioBitrate,
        ])
        input.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(input) else {
          throw SessionError(message: "書き込みにシステム音声入力を追加できませんでした。")
        }
        newWriter.add(input)
        newSystemAudioInput = input
      }

      self.writer = newWriter
      self.videoInput = newVideoInput
      self.videoAdaptor = adaptor
      self.microphoneInput = newMicrophoneInput
      self.systemAudioInput = newSystemAudioInput
      self.expectedVideoWidth = videoSettings[AVVideoWidthKey] as? Int ?? 0
      self.expectedVideoHeight = videoSettings[AVVideoHeightKey] as? Int ?? 0
      self.hasStartedSession = false
      self.usesSyntheticMicrophoneTimeline = syntheticMicrophoneTimeline
      self.syntheticMicrophonePTS = .zero
      self.resetStats()

      guard newWriter.startWriting() else {
        self.clear()
        throw SessionError(message: newWriter.error?.localizedDescription ?? "書き込みを開始できませんでした。")
      }
    }
  }

  func appendScreenSample(_ sampleBuffer: CMSampleBuffer) {
    ioQueue.async { [weak self] in
      self?.appendVideoSample(sampleBuffer)
    }
  }

  func appendSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
    ioQueue.async { [weak self] in
      self?.appendAudio(sampleBuffer: sampleBuffer, to: self?.systemAudioInput, role: "system")
    }
  }

  func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
    ioQueue.async { [weak self] in
      self?.appendAudio(sampleBuffer: sampleBuffer, to: self?.microphoneInput, role: "microphone")
    }
  }

  private func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard let writer else { return }
    guard let videoInput else { return }
    guard let videoAdaptor else { return }

    if writer.status == .failed || writer.status == .cancelled {
      logWriterFailureOnce(writer)
      return
    }

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    if !hasStartedSession {
      let w = CVPixelBufferGetWidth(pixelBuffer)
      let h = CVPixelBufferGetHeight(pixelBuffer)
      let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
      let fourCC = String(format: "%c%c%c%c",
        (fmt >> 24) & 0xFF, (fmt >> 16) & 0xFF, (fmt >> 8) & 0xFF, fmt & 0xFF)
      Self.logger.info("writerFirstFrame width=\(w, privacy: .public) height=\(h, privacy: .public) pixelFormat=\(fourCC, privacy: .public) pts=\(Self.logDescription(for: rawPTS), privacy: .public)")

      startWriterSession(anchorPTS: rawPTS)
      if writer.status == .failed {
        logWriterFailureOnce(writer)
        return
      }
      flushPendingSyntheticMicrophoneBuffersIfNeeded()
    }

    guard hasStartedSession else { return }
    guard let relativePTS = relativePresentationTime(for: sampleBuffer) else { return }
    let pts = enforceMonotonicPresentationTime(relativePTS, last: lastVideoPTS)

    let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
    let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
    if expectedVideoWidth > 0, expectedVideoHeight > 0,
       bufferWidth != expectedVideoWidth || bufferHeight != expectedVideoHeight {
      droppedVideoDimensionMismatchCount += 1
      return
    }

    guard videoInput.isReadyForMoreMediaData else {
      droppedVideoNotReadyCount += 1
      return
    }

    if !videoAdaptor.append(pixelBuffer, withPresentationTime: pts) {
      logWriterFailureOnce(writer)
    } else {
      videoSampleCount += 1
      lastVideoPTS = pts
    }
  }

  private func appendAudio(sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, role: String) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard let writer else { return }
    guard let input else { return }
    guard writer.status != .failed, writer.status != .cancelled else { return }

    if role == "microphone" {
      if usesSyntheticMicrophoneTimeline {
        appendSyntheticMicrophone(sampleBuffer: sampleBuffer, to: input)
        return
      }
      // AVCapture mic PTS is on a different clock than SCStream; never anchor the writer on it.
      guard hasStartedSession else { return }
    }

    guard hasStartedSession else { return }

    guard let relativePTS = relativePresentationTime(for: sampleBuffer) else { return }
    let pts: CMTime
    switch role {
    case "system":
      pts = enforceMonotonicPresentationTime(relativePTS, last: lastSystemAudioPTS)
    case "microphone":
      pts = enforceMonotonicPresentationTime(relativePTS, last: lastMicrophonePTS)
    default:
      pts = relativePTS
    }
    let sourceBuffer: CMSampleBuffer
    switch role {
    case "microphone":
      sourceBuffer = Self.gainAdjustedPCMSampleBuffer(
        sampleBuffer,
        gain: SessionConstants.microphoneWriterGain
      ) ?? sampleBuffer
    case "system":
      sourceBuffer = Self.gainAdjustedPCMSampleBuffer(
        sampleBuffer,
        gain: SessionConstants.systemWriterGain
      ) ?? sampleBuffer
    default:
      sourceBuffer = sampleBuffer
    }
    guard input.isReadyForMoreMediaData else {
      incrementDroppedAudioNotReadyCount(role: role)
      return
    }
    guard let rebased = Self.retimeSampleBuffer(sourceBuffer, presentationTime: pts) else { return }
    if input.append(rebased) {
      recordAudioSample(rebased, role: role)
    } else {
      logWriterFailureOnce(writer)
    }
  }

  private func appendSyntheticMicrophone(sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
    if !hasStartedSession {
      enqueuePendingSyntheticMicrophone(sampleBuffer)
      return
    }
    appendSyntheticMicrophoneSample(sampleBuffer: sampleBuffer, to: input)
  }

  private func enqueuePendingSyntheticMicrophone(_ sampleBuffer: CMSampleBuffer) {
    guard pendingSyntheticMicrophoneBuffers.count < SyntheticMicLimits.maxPendingBuffers else {
      droppedMicPendingCount += 1
      return
    }
    var copy: CMSampleBuffer?
    guard CMSampleBufferCreateCopy(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleBufferOut: &copy
    ) == noErr, let copy else { return }
    pendingSyntheticMicrophoneBuffers.append(copy)
  }

  private func flushPendingSyntheticMicrophoneBuffersIfNeeded() {
    guard usesSyntheticMicrophoneTimeline, let input = microphoneInput else { return }
    guard !pendingSyntheticMicrophoneBuffers.isEmpty else { return }
    let pending = pendingSyntheticMicrophoneBuffers
    pendingSyntheticMicrophoneBuffers.removeAll(keepingCapacity: true)
    for sample in pending {
      appendSyntheticMicrophoneSample(sampleBuffer: sample, to: input)
    }
  }

  private func appendSyntheticMicrophoneSample(sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
    guard input.isReadyForMoreMediaData else {
      droppedMicrophoneNotReadyCount += 1
      return
    }

    let pts = syntheticMicrophonePTS
    let duration = CMSampleBufferGetDuration(sampleBuffer)
    let advance: CMTime
    if duration.isValid, duration.seconds > 0 {
      advance = duration
    } else {
      let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
      advance = CMTime(value: Int64(sampleCount), timescale: Int32(SessionConstants.audioSampleRate))
    }

    guard let rebased = Self.preparedMicrophoneSampleBuffer(sampleBuffer, presentationTime: pts) else { return }
    guard let writer else { return }
    if input.append(rebased) {
      recordAudioSample(rebased, role: "microphone")
      syntheticMicrophonePTS = CMTimeAdd(syntheticMicrophonePTS, advance)
    } else {
      logWriterFailureOnce(writer)
    }
  }

  private func enforceMonotonicPresentationTime(_ pts: CMTime, last: CMTime?) -> CMTime {
    guard let last, CMTimeCompare(pts, last) <= 0 else { return pts }
    return CMTimeAdd(last, CMTime(value: 1, timescale: 600))
  }

  private func startWriterSession(anchorPTS: CMTime) {
    guard !hasStartedSession, let writer else { return }
    timelineOriginPTS = anchorPTS
    writer.startSession(atSourceTime: .zero)
    hasStartedSession = true
  }

  private func relativePresentationTime(for sampleBuffer: CMSampleBuffer) -> CMTime? {
    guard let origin = timelineOriginPTS else { return nil }
    let relative = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), origin)
    guard relative.isValid, !relative.isIndefinite, relative.seconds >= 0 else { return nil }
    return relative
  }

  private func copySampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
    Self.retimeSampleBuffer(sampleBuffer, presentationTime: presentationTime)
  }

  static func retimeSampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(
      duration: CMSampleBufferGetDuration(sampleBuffer),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var output: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleBufferOut: &output
    ) == noErr else { return nil }
    return output
  }

  private static func preparedMicrophoneSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    presentationTime: CMTime
  ) -> CMSampleBuffer? {
    let gained = gainAdjustedPCMSampleBuffer(sampleBuffer, gain: SessionConstants.microphoneWriterGain)
    return retimeSampleBuffer(gained ?? sampleBuffer, presentationTime: presentationTime)
  }

  static func gainAdjustedPCMSampleBuffer(_ sampleBuffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer? {
    guard gain > 1.001, CMSampleBufferDataIsReady(sampleBuffer) else { return sampleBuffer }
    var copy: CMSampleBuffer?
    guard CMSampleBufferCreateCopy(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleBufferOut: &copy
    ) == noErr,
      let copy,
      let blockBuf = CMSampleBufferGetDataBuffer(copy)
    else { return nil }

    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
      blockBuf,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer
    ) == noErr,
      let dataPointer,
      totalLength > 0
    else { return nil }

    let sampleCount = totalLength / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return nil }
    dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
      for index in 0..<sampleCount {
        let scaled = Float(samples[index]) * gain
        samples[index] = Int16(max(Float(Int16.min), min(Float(Int16.max), scaled.rounded())))
      }
    }
    return copy
  }

  private func logWriterFailureOnce(_ writer: AVAssetWriter) {
    guard !hasLoggedWriterFailure else { return }
    hasLoggedWriterFailure = true
    let ns = (writer.error as? NSError)
    Self.logger.error("writerFailed status=\(writer.status.rawValue, privacy: .public) domain=\(ns?.domain ?? "?", privacy: .public) code=\(ns?.code ?? 0, privacy: .public) description=\(ns?.localizedDescription ?? "nil", privacy: .public)")
  }

  private func incrementDroppedAudioNotReadyCount(role: String) {
    switch role {
    case "system":
      droppedSystemAudioNotReadyCount += 1
    case "microphone":
      droppedMicrophoneNotReadyCount += 1
    default:
      break
    }
  }

  private func recordAudioSample(_ sampleBuffer: CMSampleBuffer, role: String) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    switch role {
    case "system":
      systemAudioSampleCount += 1
      lastSystemAudioPTS = pts
    case "microphone":
      microphoneSampleCount += 1
      lastMicrophonePTS = pts
    default:
      break
    }
  }

  private func logFinishStats(status: AVAssetWriter.Status, success: Bool, error: Error?) {
    let ns = error as NSError?
    Self.logger.info("writerFinishStats success=\(success, privacy: .public) status=\(status.rawValue, privacy: .public) videoSamples=\(self.videoSampleCount, privacy: .public) systemAudioSamples=\(self.systemAudioSampleCount, privacy: .public) microphoneSamples=\(self.microphoneSampleCount, privacy: .public) droppedVideoNotReady=\(self.droppedVideoNotReadyCount, privacy: .public) droppedSystemAudioNotReady=\(self.droppedSystemAudioNotReadyCount, privacy: .public) droppedMicrophoneNotReady=\(self.droppedMicrophoneNotReadyCount, privacy: .public) droppedMicPending=\(self.droppedMicPendingCount, privacy: .public) lastVideoPTS=\(Self.logDescription(for: self.lastVideoPTS), privacy: .public) lastSystemAudioPTS=\(Self.logDescription(for: self.lastSystemAudioPTS), privacy: .public) lastMicrophonePTS=\(Self.logDescription(for: self.lastMicrophonePTS), privacy: .public) errorDomain=\(ns?.domain ?? "none", privacy: .public) errorCode=\(ns?.code ?? 0, privacy: .public)")
  }

  private func resetStats() {
    videoSampleCount = 0
    systemAudioSampleCount = 0
    microphoneSampleCount = 0
    droppedVideoNotReadyCount = 0
    droppedSystemAudioNotReadyCount = 0
    droppedMicrophoneNotReadyCount = 0
    droppedVideoDimensionMismatchCount = 0
    pendingSyntheticMicrophoneBuffers.removeAll(keepingCapacity: false)
    droppedMicPendingCount = 0
    lastVideoPTS = nil
    lastSystemAudioPTS = nil
    lastMicrophonePTS = nil
  }

  private static func logDescription(for time: CMTime?) -> String {
    guard let time, time.isValid, !time.isIndefinite else { return "none" }
    return String(format: "%.3f", CMTimeGetSeconds(time))
  }

  struct FinishResult {
    var success: Bool
    var writerError: Error?
  }

  func finishWriting() async -> FinishResult {
    await withCheckedContinuation { continuation in
      ioQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: FinishResult(success: false, writerError: nil))
          return
        }

        guard let writer = self.writer else {
          continuation.resume(returning: FinishResult(success: false, writerError: nil))
          return
        }

        if writer.status == .completed {
          self.logFinishStats(status: writer.status, success: true, error: nil)
          self.clear()
          continuation.resume(returning: FinishResult(success: true, writerError: nil))
          return
        }

        guard writer.status == .writing else {
          let err = writer.error
          self.logFinishStats(status: writer.status, success: false, error: err)
          self.clear()
          continuation.resume(returning: FinishResult(success: false, writerError: err))
          return
        }

        self.videoInput?.markAsFinished()
        self.microphoneInput?.markAsFinished()
        self.systemAudioInput?.markAsFinished()

        nonisolated(unsafe) let unsafeWriter = writer
        unsafeWriter.finishWriting {
          let ok = unsafeWriter.status == .completed
          let err = unsafeWriter.error
          self.logFinishStats(status: unsafeWriter.status, success: ok, error: err)
          self.clear()
          continuation.resume(returning: FinishResult(success: ok, writerError: err))
        }
      }
    }
  }

  func cancel() {
    ioQueue.async { [weak self] in
      guard let self else { return }
      self.writer?.cancelWriting()
      self.clear()
    }
  }

  func cancelImmediately() {
    ioQueue.sync { [weak self] in
      guard let self else { return }
      self.writer?.cancelWriting()
      self.clear()
    }
  }

  private func clear() {
    writer = nil
    videoInput = nil
    videoAdaptor = nil
    microphoneInput = nil
    systemAudioInput = nil
    hasStartedSession = false
    timelineOriginPTS = nil
    usesSyntheticMicrophoneTimeline = false
    syntheticMicrophonePTS = .zero
    expectedVideoWidth = 0
    expectedVideoHeight = 0
    pendingSyntheticMicrophoneBuffers.removeAll(keepingCapacity: false)
    droppedMicPendingCount = 0
    hasLoggedWriterFailure = false
    resetStats()
  }
}

struct ScreenStreamFrameMetadata: Sendable {
  var contentRect: CGRect
  /// Global on-screen bounds from `SCStreamFrameInfo.screenRect`. Fed to
  /// `RecordingCoordinator.latestStreamScreenRect` for cursor mapping (INVARIANTS §1).
  var screenRect: CGRect?
  var boundingRect: CGRect?
  var contentScale: CGFloat?
  var scaleFactor: CGFloat?
}

/// `SCStream` callbacks arrive on queues managed by ScreenCaptureKit; delegate work out of `@MainActor` types.
final class SCStreamRecordingBridge: NSObject, SCStreamOutput, SCStreamDelegate {
  private let writerSession: RecordingWriterSession
  private let onStopped: (Error) -> Void
  var onScreenFrameMetadata: ((ScreenStreamFrameMetadata) -> Void)?

  init(writerSession: RecordingWriterSession, onStopped: @escaping (Error) -> Void) {
    self.writerSession = writerSession
    self.onStopped = onStopped
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    onStopped(error)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    switch type {
    case .screen:
      if let metadata = Self.frameMetadata(from: sampleBuffer) {
        onScreenFrameMetadata?(metadata)
      }
      writerSession.appendScreenSample(sampleBuffer)
    case .audio:
      writerSession.appendSystemAudioSample(sampleBuffer)
    default:
      break
    }
  }

  private static func frameMetadata(from sampleBuffer: CMSampleBuffer) -> ScreenStreamFrameMetadata? {
    guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false
    ) as? [[SCStreamFrameInfo: Any]],
      let attachments = attachmentsArray.first,
      let contentRect = rect(from: attachments, key: .contentRect)
    else { return nil }

    return ScreenStreamFrameMetadata(
      contentRect: contentRect,
      screenRect: rect(from: attachments, key: .screenRect),
      boundingRect: rect(from: attachments, key: .boundingRect),
      contentScale: attachments[.contentScale] as? CGFloat,
      scaleFactor: attachments[.scaleFactor] as? CGFloat
    )
  }

  private static func rect(from attachments: [SCStreamFrameInfo: Any], key: SCStreamFrameInfo) -> CGRect? {
    if let rect = attachments[key] as? CGRect {
      return rect
    }
    if let dict = attachments[key] as? [String: Any] {
      return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }
    return nil
  }
}
