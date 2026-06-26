import AVFoundation
import CoreMedia
import Foundation

// MARK: - CameraMovieCapture
//
// INVARIANT (docs/INVARIANTS.md §2):
//   commitConfiguration() must complete before startRunning().
//
// Sidecar `.mov` for PiP / future incamera UX — not yet the primary in-app camera preview pipeline.
// Tear-down: prefer stopRecordingAsync() so AVAssetWriter finishes cleanly.
//
// When the mic is also enabled, add it to this session instead of opening a second AVCaptureSession.
// A second session interrupts movie recording on macOS (runtime log: didFinishRecording at +42ms, 0-byte file).
// MovieFileOutput + AudioDataOutput on the same session never sets isRecording=true (post-fix log); use AVAssetWriter.
//
// Preview starts during `.armed`; sidecar file writing begins when the screen stream starts so PiP t=0 matches.

/// Records the default camera device to a `.mov` alongside screen capture.
final class CameraMovieCapture: NSObject, @unchecked Sendable {
  private enum CaptureConstants {
    static let writerVideoBitrate = 4_000_000
  }

  private(set) var session: AVCaptureSession?
  private(set) var movieOutput: AVCaptureMovieFileOutput?
  private(set) var includesMicrophoneInput = false

  struct Configuration {
    var sessionPreset: AVCaptureSession.Preset = .hd1280x720
  }

  private enum SessionPreset {
    /// Match recording preset so live PiP framing does not jump when REC starts.
    static let previewOnly: AVCaptureSession.Preset = .hd1280x720
    static let sharedMicRecording: AVCaptureSession.Preset = .hd1280x720
  }

  private(set) var outputURL: URL?
  private(set) var lastFinishError: Error?

  private var finishContinuation: CheckedContinuation<Void, Never>?
  private var audioDataOutput: AVCaptureAudioDataOutput?
  private let audioSampleQueue = DispatchQueue(label: AppIdentifiers.DispatchQueueLabels.microphone)

  private var usesAssetWriter = false
  private var videoDataOutput: AVCaptureVideoDataOutput?
  private let videoSampleQueue = DispatchQueue(label: "dev.arcshot.camera.video")
  private var assetWriter: AVAssetWriter?
  private var videoWriterInput: AVAssetWriterInput?
  private var writerSessionStarted = false
  private var writerVideoSampleCount = 0
  private var cameraFrameIndex: Int64 = 0
  private let cameraFrameDuration = CMTime(value: 1, timescale: 30)
  private var configuredVideoDevice: AVCaptureDevice?
  private var isSidecarFileRecordingActive = false

  private static let sessionQueueSpecificKey = DispatchSpecificKey<UInt8>()
  private let sessionQueue: DispatchQueue = {
    let queue = DispatchQueue(label: "dev.arcshot.camera.session")
    queue.setSpecific(key: CameraMovieCapture.sessionQueueSpecificKey, value: 1)
    return queue
  }()

  /// Forwards mic samples to the main screen writer when `includesMicrophoneInput` is true.
  var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

  var isActivelyRecording: Bool {
    if usesAssetWriter {
      return isSidecarFileRecordingActive && assetWriter?.status == .writing
    }
    return movieOutput?.isRecording == true
  }

  /// Live preview during `.armed` — session runs but no sidecar file is written yet.
  func startPreviewSession(
    configuration: Configuration = Configuration(),
    includesMicrophone: Bool = false
  ) throws {
    if DispatchQueue.getSpecific(key: Self.sessionQueueSpecificKey) != nil {
      try configureAndStartPreviewSession(
        configuration: configuration,
        includesMicrophone: includesMicrophone
      )
      return
    }
    try sessionQueue.sync {
      try configureAndStartPreviewSession(
        configuration: configuration,
        includesMicrophone: includesMicrophone
      )
    }
  }

  /// Runs configure + `startRunning()` atomically on the session queue (preview layer must not attach mid-flight).
  func startPreviewSessionAsync(
    configuration: Configuration = Configuration(),
    includesMicrophone: Bool = false
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async { [self] in
        do {
          try self.configureAndStartPreviewSession(
            configuration: configuration,
            includesMicrophone: includesMicrophone
          )
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func configureAndStartPreviewSession(
    configuration: Configuration,
    includesMicrophone: Bool
  ) throws {
    try configurePreviewSessionOnQueue(configuration: configuration, includesMicrophone: includesMicrophone)
    session?.startRunning()
  }

  private func configurePreviewSessionOnQueue(
    configuration: Configuration,
    includesMicrophone: Bool
  ) throws {
    tearDownPreviewOnSessionQueue()

    let session = AVCaptureSession()
    session.beginConfiguration()
    let preset = includesMicrophone ? SessionPreset.sharedMicRecording : SessionPreset.previewOnly
    if session.canSetSessionPreset(preset) {
      session.sessionPreset = preset
    } else {
      session.sessionPreset = configuration.sessionPreset
    }

    guard let device = AVCaptureDevice.default(for: .video),
      let videoInput = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(videoInput)
    else {
      session.commitConfiguration()
      throw RecordingFailure(message: "カメラ入力がありません。")
    }
    session.addInput(videoInput)
    configuredVideoDevice = device

    outputURL = nil
    finishContinuation = nil
    lastFinishError = nil
    writerSessionStarted = false
    cameraFrameIndex = 0
    writerVideoSampleCount = 0
    isSidecarFileRecordingActive = false

    if includesMicrophone {
      try configureSharedMicrophoneOutputs(session: session, videoDevice: device)
    } else {
      try configureMovieFileCapture(session: session)
    }

    self.session = session
  }

  /// Begin writing the sidecar `.mov` when the screen stream starts (timeline-aligned t=0).
  func beginSidecarRecording(to url: URL) throws {
    guard session != nil else {
      throw RecordingFailure(message: "カメラセッションが開始されていません。")
    }
    guard !isSidecarFileRecordingActive else { return }

    outputURL = url
    finishContinuation = nil
    lastFinishError = nil
    writerSessionStarted = false
    cameraFrameIndex = 0
    writerVideoSampleCount = 0

    if usesAssetWriter {
      guard let device = configuredVideoDevice else {
        throw RecordingFailure(message: "カメラデバイスが見つかりません。")
      }
      try setupAssetWriter(outputURL: url, videoDevice: device)
      guard assetWriter?.startWriting() == true else {
        let message = assetWriter?.error?.localizedDescription ?? "カメラライター開始に失敗しました。"
        throw RecordingFailure(message: message)
      }
      isSidecarFileRecordingActive = true
    } else if let movieOutput {
      movieOutput.startRecording(to: url, recordingDelegate: self)
      guard movieOutput.isRecording else {
        throw RecordingFailure(message: "カメラムービー録画を開始できませんでした。")
      }
      isSidecarFileRecordingActive = true
    }
  }

  func startRecording(
    to url: URL,
    configuration: Configuration = Configuration(),
    includesMicrophone: Bool = false
  ) throws {
    try startPreviewSession(configuration: configuration, includesMicrophone: includesMicrophone)
    try beginSidecarRecording(to: url)
  }

  private func configureMovieFileCapture(session: AVCaptureSession) throws {
    usesAssetWriter = false
    audioDataOutput = nil
    includesMicrophoneInput = false
    videoDataOutput = nil
    assetWriter = nil
    videoWriterInput = nil

    let output = AVCaptureMovieFileOutput()
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw RecordingFailure(message: "カメラセッションへムービー出力を接続できませんでした。")
    }
    session.addOutput(output)
    session.commitConfiguration()
    movieOutput = output
  }

  private func configureSharedMicrophoneOutputs(
    session: AVCaptureSession,
    videoDevice: AVCaptureDevice
  ) throws {
    usesAssetWriter = true
    movieOutput = nil
    includesMicrophoneInput = true
    assetWriter = nil
    videoWriterInput = nil

    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
      session.commitConfiguration()
      throw RecordingFailure(message: "マイク機器が見つかりません。")
    }
    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
    guard session.canAddInput(audioInput) else {
      session.commitConfiguration()
      throw RecordingFailure(message: "カメラセッションへマイク入力を接続できませんでした。")
    }
    session.addInput(audioInput)

    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    guard session.canAddOutput(videoOutput) else {
      session.commitConfiguration()
      throw RecordingFailure(message: "カメラセッションへビデオ出力を接続できませんでした。")
    }
    session.addOutput(videoOutput)
    videoOutput.setSampleBufferDelegate(self, queue: videoSampleQueue)
    videoDataOutput = videoOutput

    let audioOutput = AVCaptureAudioDataOutput()
    guard session.canAddOutput(audioOutput) else {
      session.commitConfiguration()
      throw RecordingFailure(message: "カメラセッションへマイク出力を接続できませんでした。")
    }
    session.addOutput(audioOutput)
    audioOutput.setSampleBufferDelegate(self, queue: audioSampleQueue)
    audioDataOutput = audioOutput

    session.commitConfiguration()
  }

  private func setupAssetWriter(outputURL: URL, videoDevice: AVCaptureDevice) throws {
    let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
    let width = max(2, Int(dimensions.width))
    let height = max(2, Int(dimensions.height))
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: CaptureConstants.writerVideoBitrate,
      ],
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    writerInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(writerInput) else {
      throw RecordingFailure(message: "カメラライターへビデオ入力を接続できませんでした。")
    }
    writer.add(writerInput)
    assetWriter = writer
    videoWriterInput = writerInput
  }

  /// Stops preview-only capture (no sidecar file was being written).
  func stopPreviewSessionAsync() async {
    guard !isSidecarFileRecordingActive else {
      await stopRecordingAsync()
      return
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sessionQueue.async { [self] in
        self.tearDownPreviewOnSessionQueue()
        continuation.resume()
      }
    }
  }

  /// Finishes `.mov` writing and tears down inputs/outputs (`outputURL` remains for the caller).
  func stopRecordingAsync() async {
    if usesAssetWriter {
      await stopAssetWriterCaptureAsync()
      return
    }

    guard let mo = movieOutput else {
      stopSynchronouslyIgnoringDelegate()
      return
    }
    if mo.isRecording {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        finishContinuation = cont
        mo.stopRecording()
      }
      finishContinuation = nil
    }
    if let session, session.isRunning {
      session.stopRunning()
    }
    session = nil
    movieOutput = nil
    audioDataOutput = nil
    includesMicrophoneInput = false
    onAudioSampleBuffer = nil
    configuredVideoDevice = nil
    isSidecarFileRecordingActive = false
  }

  private func stopAssetWriterCaptureAsync() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      videoSampleQueue.async { [self] in
        videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoWriterInput?.markAsFinished()
        self.assetWriter?.finishWriting { [self] in
          if let writerError = self.assetWriter?.error {
            self.lastFinishError = writerError
          }
          cont.resume()
        }
      }
    }

    if let session, session.isRunning {
      session.stopRunning()
    }
    session = nil
    videoDataOutput = nil
    audioDataOutput = nil
    assetWriter = nil
    videoWriterInput = nil
    usesAssetWriter = false
    includesMicrophoneInput = false
    onAudioSampleBuffer = nil
    writerSessionStarted = false
    cameraFrameIndex = 0
    configuredVideoDevice = nil
    isSidecarFileRecordingActive = false
  }

  func stopSynchronouslyIgnoringDelegate() {
    if DispatchQueue.getSpecific(key: Self.sessionQueueSpecificKey) != nil {
      tearDownPreviewOnSessionQueue()
      return
    }
    sessionQueue.sync {
      tearDownPreviewOnSessionQueue()
    }
  }

  private func tearDownPreviewOnSessionQueue() {
    movieOutput?.stopRecording()
    videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
    videoWriterInput?.markAsFinished()
    assetWriter?.cancelWriting()
    if let session, session.isRunning {
      session.stopRunning()
    }
    session = nil
    movieOutput = nil
    videoDataOutput = nil
    audioDataOutput = nil
    assetWriter = nil
    videoWriterInput = nil
    usesAssetWriter = false
    includesMicrophoneInput = false
    onAudioSampleBuffer = nil
    configuredVideoDevice = nil
    writerSessionStarted = false
    cameraFrameIndex = 0
    writerVideoSampleCount = 0
    isSidecarFileRecordingActive = false
    finishContinuation = nil
  }

  struct RecordingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
}

extension CameraMovieCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output is AVCaptureAudioDataOutput {
      onAudioSampleBuffer?(sampleBuffer)
      return
    }

    guard isSidecarFileRecordingActive,
      usesAssetWriter,
      let writer = assetWriter,
      let input = videoWriterInput,
      writer.status == .writing,
      input.isReadyForMoreMediaData
    else { return }

    let pts = CMTimeMultiply(cameraFrameDuration, multiplier: Int32(cameraFrameIndex))
    cameraFrameIndex += 1
    if !writerSessionStarted {
      writer.startSession(atSourceTime: .zero)
      writerSessionStarted = true
    }
    guard let timedBuffer = Self.copySampleBuffer(sampleBuffer, presentationTime: pts) else { return }
    if input.append(timedBuffer) {
      writerVideoSampleCount += 1
    }
  }

  private static func copySampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
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
}

extension CameraMovieCapture: AVCaptureFileOutputRecordingDelegate {
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
  }

  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    lastFinishError = error
    finishContinuation?.resume()
    finishContinuation = nil
  }
}
