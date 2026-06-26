import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import OSLog
import ScreenCaptureKit

enum RecordingState: String {
  case idle
  case armed
  case recording
  case finished
  case failed
}

final class InputEventRecorder {
  private let captureRect: CGRect
  private let lock = NSLock()
  private var startUptime: TimeInterval = 0
  private var eventMonitor: Any?
  private var events: [RecordingProject.InputEvent] = []

  init(captureRect: CGRect) {
    self.captureRect = captureRect
  }

  func start(startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    stop()
    self.startUptime = startUptime
    eventMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .keyDown,
        .keyUp,
        .flagsChanged,
      ]
    ) { [weak self] event in
      self?.record(event: event)
    }
  }

  func stop() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    eventMonitor = nil
  }

  func takeEvents() -> [RecordingProject.InputEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events.sorted { $0.timeSeconds < $1.timeSeconds }
  }

  private func record(event: NSEvent) {
    guard let kind = kind(for: event.type) else { return }
    let t = max(0, ProcessInfo.processInfo.systemUptime - startUptime)
    let point = isMouseEvent(event.type) ? normalizedPoint(for: NSEvent.mouseLocation) : nil
    let isKeyboard = kind == .keyDown || kind == .keyUp || kind == .flagsChanged
    let keyCode = isKeyboard ? event.keyCode : nil
    let input = RecordingProject.InputEvent(
      timeSeconds: t,
      kind: kind,
      x: point.map { Double($0.x) },
      y: point.map { Double($0.y) },
      keyCode: keyCode,
      characters: keyCode.flatMap(Self.displayString(forKeyCode:)),
      modifierFlagsRaw: UInt64(event.modifierFlags.rawValue)
    )
    lock.lock()
    events.append(input)
    if events.count > 20_000 {
      events.removeFirst(events.count - 20_000)
    }
    lock.unlock()
  }

  private func kind(for type: NSEvent.EventType) -> RecordingProject.InputEvent.Kind? {
    switch type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      return .mouseDown
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      return .mouseUp
    case .keyDown:
      return .keyDown
    case .keyUp:
      return .keyUp
    case .flagsChanged:
      return .flagsChanged
    default:
      return nil
    }
  }

  private func isMouseEvent(_ type: NSEvent.EventType) -> Bool {
    switch type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      return true
    default:
      return false
    }
  }

  private func normalizedPoint(for location: CGPoint) -> CGPoint? {
    guard captureRect.width > 1, captureRect.height > 1 else { return nil }
    let cgGlobal = RecordingCoordinator.cgGlobalMouseLocation(fromAppKitFallback: location)
    guard let normalized = RecordingCoordinator.normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: cgGlobal,
      contentRect: captureRect
    ) else { return nil }
    return CGPoint(x: normalized.x, y: normalized.y)
  }

  private static func displayString(forKeyCode keyCode: UInt16) -> String? {
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 25: return "9"
    case 26: return "7"
    case 28: return "8"
    case 29: return "0"
    case 31: return "O"
    case 32: return "U"
    case 34: return "I"
    case 35: return "P"
    case 37: return "L"
    case 38: return "J"
    case 40: return "K"
    case 45: return "N"
    case 46: return "M"
    case 49: return "Space"
    case 53: return "Esc"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default: return nil
    }
  }
}

extension RecordingState {
  /// 画面表示用（`rawValue` は英語キーのまま保持）。
  var localizedStatusLabel: String {
    switch self {
    case .idle: return "待機中"
    case .armed: return "準備完了"
    case .recording: return "収録中"
    case .finished: return "完了"
    case .failed: return "エラー"
    }
  }
}

private enum RecordingCoordinatorUserCopy {
  static let finalizationWriteFailure =
    "録画ファイルの書き出しに失敗しました。ディスクの空き容量や「画面収録」の許可を確認してください。"
}

@MainActor
@Observable
final class RecordingCoordinator {
  private enum RecordingClock {
    static let tickNanoseconds: UInt64 = 250_000_000
  }

  private static let captureLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.arcshot.ArcShot",
    category: "CapturePipeline"
  )

  struct RecordingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private(set) var state: RecordingState = .idle
  private(set) var lastOutputURL: URL?
  private(set) var lastErrorMessage: String?
  private(set) var isBusy: Bool = false
  private(set) var recordingElapsedSeconds: Double = 0

  private(set) var isMicrophoneEnabled: Bool = false
  private(set) var isSystemAudioEnabled: Bool = false
  private(set) var isCursorCaptureEnabled: Bool = true
  private(set) var isCameraEnabled: Bool = false
  /// Whether the current/last recording session started with camera enabled (survives until handoff).
  private(set) var wasCameraEnabledForLastRecording: Bool = false
  /// Active camera capture session while recording (for live PiP preview).
  var activeCameraCaptureSession: AVCaptureSession? { cameraCapture?.session }
  private(set) var isCameraPreviewStarting: Bool = false
  /// フローティング録画ランチャーをユーザーが閉じたとき false。メニューの「新規録画」で再表示する。
  private(set) var isFloatingLauncherVisible: Bool = true

  /// `discardRecording()` が `.finished` を経由するとき、フローティング側の自動エディタ遷移を抑止する。
  private(set) var isSuppressingEditorFinalizeForDiscard: Bool = false

  /// 停止直後の `finalizeAfterUserStoppedRecording` が複数経路から二重起動しないようにする。
  private var postStopFinalizeSlotTaken = false
  private(set) var isFinalizingStoppedRecording: Bool = false

  private var cameraCapture: CameraMovieCapture?
  private var cameraOutputURL: URL?
  private var stagedCameraAttachmentURL: URL?
  /// Survives until finalize takes it; copied to Application Support so temp cleanup cannot drop the sidecar.
  private var pendingCameraAttachmentURL: URL?
  private var lastCompletedRecordingID: String?
  private var cameraAttachmentPersistTask: Task<URL, Error>?
  private var cameraWasEnabledForSession = false
  func setMicrophoneEnabled(_ enabled: Bool) {
    guard enabled else {
      isMicrophoneEnabled = false
      clearLauncherIssue(containing: "マイク")
      if isCameraEnabled, canRunIdleCameraPreview {
        Task { @MainActor in
          await self.ensureCameraPreviewSession()
        }
      }
      return
    }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      isMicrophoneEnabled = true
      clearLauncherIssue(containing: "マイク")
      if isCameraEnabled, canRunIdleCameraPreview {
        Task { @MainActor in
          await self.ensureCameraPreviewSession()
        }
      }
    case .notDetermined:
      // トグル操作の一層だけで扱い、許可後に別の予約状態を持たない。
      Task { @MainActor in
        let granted = await Self.requestMediaAccess(for: .audio)
        self.isMicrophoneEnabled = granted
        if granted {
          self.clearLauncherIssue(containing: "マイク")
          if self.isCameraEnabled, self.canRunIdleCameraPreview {
            await self.ensureCameraPreviewSession()
          }
        } else {
          self.reportLauncherPreflightIssue("マイクへのアクセスが拒否されました。")
        }
      }
    default:
      isMicrophoneEnabled = false
      reportLauncherPreflightIssue("マイクを使えません。「システム設定」→「プライバシーとセキュリティ」→「マイク」で ArcShot を許可してください。")
    }
  }

  func setSystemAudioEnabled(_ enabled: Bool) {
    isSystemAudioEnabled = enabled
  }

  func setCursorCaptureEnabled(_ enabled: Bool) {
    isCursorCaptureEnabled = enabled
  }

  func setCameraEnabled(_ enabled: Bool) {
    guard enabled else {
      isCameraEnabled = false
      isCameraPreviewStarting = false
      clearLauncherIssue(containing: "カメラ")
      Task { @MainActor in
        await self.stopCameraPreviewSessionIfIdle()
      }
      return
    }

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      isCameraEnabled = true
      isCameraPreviewStarting = true
      clearLauncherIssue(containing: "カメラ")
      notifyCameraPresentationChanged()
      Task { @MainActor in
        await self.ensureCameraPreviewSession()
      }
    case .notDetermined:
      Task { @MainActor in
        let granted = await Self.requestMediaAccess(for: .video)
        self.isCameraEnabled = granted
        if granted {
          self.isCameraPreviewStarting = true
          self.clearLauncherIssue(containing: "カメラ")
          await self.ensureCameraPreviewSession()
        } else {
          self.reportLauncherPreflightIssue("カメラへのアクセスが拒否されました。")
        }
      }
    default:
      isCameraEnabled = false
      reportLauncherPreflightIssue("カメラを使えません。「システム設定」→「プライバシーとセキュリティ」→「カメラ」で ArcShot を許可してください。")
    }
  }

  func refreshMediaPermissionState() {
    // カメラ/マイクはトグル操作時と録画開始時の最小確認だけに留める。
  }

  static func prewarmCameraHardwareIfNeeded() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
    DispatchQueue.global(qos: .utility).async {
      _ = AVCaptureDevice.default(for: .video)
    }
  }

  private func notifyCameraPresentationChanged() {
    NotificationCenter.default.post(
      name: AppIdentifiers.CaptureNotifications.cameraPresentationChanged,
      object: self
    )
  }

  private var canRunIdleCameraPreview: Bool {
    switch state {
    case .idle, .finished, .failed:
      return true
    case .armed, .recording:
      return false
    }
  }

  /// Live PiP while the launcher camera toggle is on (before REC).
  private func ensureCameraPreviewSession() async {
    guard isCameraEnabled, canRunIdleCameraPreview else { return }
    if let cameraCapture,
      cameraCapture.session?.isRunning == true,
      cameraCapture.includesMicrophoneInput == isMicrophoneEnabled,
      !cameraCapture.isActivelyRecording {
      return
    }
    if let cameraCapture, !cameraCapture.isActivelyRecording {
      await cameraCapture.stopPreviewSessionAsync()
      self.cameraCapture = nil
    }
    isCameraPreviewStarting = true
    defer { isCameraPreviewStarting = false }
    do {
      notifyCameraPresentationChanged()
      let camCap = CameraMovieCapture()
      try await camCap.startPreviewSessionAsync(includesMicrophone: isMicrophoneEnabled)
      cameraCapture = camCap
      notifyCameraPresentationChanged()
    } catch {
      cameraCapture = nil
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      reportLauncherPreflightIssue("カメラプレビューを開始できませんでした: \(message)")
      Self.captureLogger.error("cameraPreviewStartFailed error=\(message, privacy: .public)")
    }
  }

  private func stopCameraPreviewSessionIfIdle() async {
    guard canRunIdleCameraPreview else { return }
    guard let cameraCapture, !cameraCapture.isActivelyRecording else { return }
    await cameraCapture.stopPreviewSessionAsync()
    self.cameraCapture = nil
  }

  private func prepareCameraForRecording(writerSession: RecordingWriterSession) async throws {
    let camURL = try makeTempRecordingURL(filePrefix: AppIdentifiers.TempFilePrefix.camera)
    cameraOutputURL = camURL

    if let cameraCapture,
      cameraCapture.session?.isRunning == true,
      cameraCapture.includesMicrophoneInput == isMicrophoneEnabled,
      !cameraCapture.isActivelyRecording {
      if isMicrophoneEnabled {
        cameraCapture.onAudioSampleBuffer = { [weak writerSession] sample in
          writerSession?.appendMicrophoneSample(sample)
        }
      } else {
        cameraCapture.onAudioSampleBuffer = nil
      }
      return
    }

    if let cameraCapture {
      await cameraCapture.stopPreviewSessionAsync()
      self.cameraCapture = nil
    }

    let camCap = CameraMovieCapture()
    try await camCap.startPreviewSessionAsync(includesMicrophone: isMicrophoneEnabled)
    if isMicrophoneEnabled {
      camCap.onAudioSampleBuffer = { [weak writerSession] sample in
        writerSession?.appendMicrophoneSample(sample)
      }
    }
    cameraCapture = camCap
  }

  func setFloatingLauncherVisible(_ visible: Bool) {
    isFloatingLauncherVisible = visible
    if visible {
      NSApp.activate(ignoringOtherApps: true)
      if isCameraEnabled {
        Task { @MainActor in
          await self.ensureCameraPreviewSession()
        }
      }
    }
  }

  /// 録画済みクリップをプロジェクトへ引き渡したあと、アイドルへ戻す。
  func resetAfterProjectHandoff() {
    state = .idle
    lastOutputURL = nil
    lastErrorMessage = nil
    terminalStreamError = nil
    currentRecordingID = nil
    recordingElapsedSeconds = 0
    cursorSamples = []
    inputEvents = []
    pendingCameraAttachmentURL = nil
    cameraWasEnabledForSession = false
    wasCameraEnabledForLastRecording = false
    lastCompletedRecordingID = nil
  }

  /// 終了処理に失敗したとき、再試行できるよう出力だけ片付ける。
  func resetCaptureOutputsAfterFailedFinalize() {
    lastOutputURL = nil
    terminalStreamError = nil
    currentRecordingID = nil
    state = .idle
    recordingElapsedSeconds = 0
  }

  /// Temp sidecar URL waiting for project handoff (may still be copying to Application Support).
  var stagedCameraURLForProjectHandoff: URL? {
    pendingCameraAttachmentURL ?? stagedCameraAttachmentURL
  }

  func consumeStagedCameraAttachment() {
    pendingCameraAttachmentURL = nil
    stagedCameraAttachmentURL = nil
    cameraAttachmentPersistTask?.cancel()
    cameraAttachmentPersistTask = nil
  }

  func takeStagedCameraRecordingURL() -> URL? {
    let url = pendingCameraAttachmentURL ?? stagedCameraAttachmentURL
    consumeStagedCameraAttachment()
    return url
  }

  /// Returns a durable camera sidecar URL, awaiting a background copy started at stop when possible.
  func resolvedStagedCameraRecordingURL() async -> URL? {
    guard let sourceURL = pendingCameraAttachmentURL ?? stagedCameraAttachmentURL else { return nil }
    if sourceURL.path.contains("/camera-staging/") {
      consumeStagedCameraAttachment()
      return sourceURL
    }
    if let task = cameraAttachmentPersistTask {
      defer {
        cameraAttachmentPersistTask = nil
        consumeStagedCameraAttachment()
      }
      if let persisted = try? await task.value {
        return persisted
      }
      return sourceURL
    }
    let recordingID = lastCompletedRecordingID ?? UUID().uuidString
    defer { consumeStagedCameraAttachment() }
    return try? await Task.detached(priority: .userInitiated) {
      try Self.persistCameraRecordingDetached(from: sourceURL, recordingID: recordingID)
    }.value
  }

  func persistStagedCameraRecordingIfNeeded(from sourceURL: URL) async -> URL? {
    if sourceURL.path.contains("/camera-staging/") {
      return sourceURL
    }
    if let task = cameraAttachmentPersistTask {
      if let persisted = try? await task.value {
        return persisted
      }
    }
    let recordingID = lastCompletedRecordingID ?? UUID().uuidString
    return try? await Task.detached(priority: .userInitiated) {
      try Self.persistCameraRecordingDetached(from: sourceURL, recordingID: recordingID)
    }.value
  }

  nonisolated private static func persistCameraRecordingDetached(from sourceURL: URL, recordingID: String) throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("ArcShot", isDirectory: true)
      .appendingPathComponent("camera-staging", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let dest = base.appendingPathComponent("\(recordingID)-camera.mov")
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: sourceURL, to: dest)
    return dest
  }

  private let captureQueue = DispatchQueue(label: AppIdentifiers.DispatchQueueLabels.capture)
  private let audioQueue = DispatchQueue(label: AppIdentifiers.DispatchQueueLabels.audio)

  private var stream: SCStream?
  private var streamBridge: SCStreamRecordingBridge?
  private var writerSession: RecordingWriterSession?
  private var terminalStreamError: Error?
  private var currentRecordingID: String?

  private var mic: MicrophoneCapture?

  private var cursorSamplingTask: Task<Void, Never>?
  private var cursorBaselineUptime: TimeInterval?
  private var cursorSamples: [RecordingProject.CursorSample] = []
  private var latestStreamScreenRect: CGRect?
  private var inputEventRecorder: InputEventRecorder?
  private var inputEvents: [RecordingProject.InputEvent] = []
  private var recordingClockTask: Task<Void, Never>?
  private var recordingStartUptime: TimeInterval?
  func takeCursorSamples() -> [RecordingProject.CursorSample] {
    cursorSamples
  }

  func takeInputEvents() -> [RecordingProject.InputEvent] {
    inputEvents
  }

  func makeAudioTrackSettingsForLastRecording() -> RecordingProject.AudioTrackSettings {
    var recordedTrackRoles: [RecordingProject.AudioTrackSettings.Role] = []
    if isMicrophoneEnabled { recordedTrackRoles.append(.microphone) }
    if isSystemAudioEnabled { recordedTrackRoles.append(.system) }
    let systemVolume =
      isMicrophoneEnabled && isSystemAudioEnabled
      ? RecordingAudioLevels.defaultSystemPlaybackVolumeWithMicrophone
      : RecordingAudioLevels.defaultSystemPlaybackVolume
    return RecordingProject.AudioTrackSettings(
      microphone: .init(isEnabled: isMicrophoneEnabled, volume: RecordingAudioLevels.defaultMicrophonePlaybackVolume),
      system: .init(isEnabled: isSystemAudioEnabled, volume: systemVolume),
      recordedTrackRoles: recordedTrackRoles
    )
  }

  var canStopRecording: Bool {
    state == .recording || (state == .armed && stream != nil)
  }

  /// 画面遷移や非同期失敗のあと `isBusy` が true のまま残ると UI が全面グレーアウトするため、収録アイドル系の状態では必ず false に戻す。
  func reconcileInteractionStateForRecordUI() {
    switch state {
    case .idle, .finished, .failed:
      if isBusy { isBusy = false }
    case .armed, .recording:
      break
    }
  }

  func startRecording(source: CaptureSource) async {
    guard state == .idle || state == .finished else { return }

    guard shouldRequireScreenRecordingPreflight(for: source) == false || ScreenCaptureAccess.requestSystemPromptIfNeeded() else {
      lastErrorMessage = ScreenCaptureAccess.screenRecordingDeniedGuide
      state = .failed
      return
    }

    isBusy = true
    // Publish startup state before heavier ScreenCaptureKit setup so the floating HUD does not remain in its local preparing view.
    state = .armed
    let recordingID = UUID().uuidString
    currentRecordingID = recordingID
    lastErrorMessage = nil
    terminalStreamError = nil
    lastOutputURL = nil
    stagedCameraAttachmentURL = nil
    pendingCameraAttachmentURL = nil
    cameraWasEnabledForSession = isCameraEnabled
    wasCameraEnabledForLastRecording = isCameraEnabled

    defer { isBusy = false }

    do {
      let (filter, size, sourceRect) = try await makeFilterAndSize(for: source)
      let url = try makeTempRecordingURL()

      let session = RecordingWriterSession()
      let configuration: RecordingWriterSession.Configuration = {
        if isMicrophoneEnabled && isSystemAudioEnabled {
          return .videoPlusMicrophoneAndSystemAudio(url, videoSettings: makeVideoOutputSettings(size: size))
        }
        if isMicrophoneEnabled {
          return .videoPlusMicrophone(url, videoSettings: makeVideoOutputSettings(size: size))
        }
        if isSystemAudioEnabled {
          return .videoPlusSystemAudio(url, videoSettings: makeVideoOutputSettings(size: size))
        }
        return .videoOnly(url, videoSettings: makeVideoOutputSettings(size: size))
      }()

      try session.configureAndStartWriting(
        configuration,
        syntheticMicrophoneTimeline: isMicrophoneEnabled
      )

      let bridge = SCStreamRecordingBridge(writerSession: session) { [weak self] error in
        Task { @MainActor in
          await self?.handleStreamStopped(error)
        }
      }
      bridge.onScreenFrameMetadata = { [weak self] metadata in
        Task { @MainActor in
          self?.handleStreamFrameMetadata(metadata, source: source)
        }
      }

      let captureWidth = Int(size.width) & ~1
      let captureHeight = Int(size.height) & ~1
      print("[RecordingCoordinator] Display size=\(size), capture=\(captureWidth)x\(captureHeight)")
      Self.captureLogger.info("startRecording id=\(recordingID, privacy: .public) source=\(Self.logDescription(for: source), privacy: .public) capture=\(captureWidth)x\(captureHeight, privacy: .public) systemAudio=\(self.isSystemAudioEnabled, privacy: .public) mic=\(self.isMicrophoneEnabled, privacy: .public) camera=\(self.isCameraEnabled, privacy: .public) cursor=\(self.isCursorCaptureEnabled, privacy: .public)")

      let config = SCStreamConfiguration()
      config.width = captureWidth
      config.height = captureHeight
      config.queueDepth = 6
      config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
      config.pixelFormat = kCVPixelFormatType_32BGRA
      config.showsCursor = false
      config.capturesAudio = isSystemAudioEnabled
      if let sourceRect {
        config.sourceRect = sourceRect
      }
      Self.captureLogger.debug("streamConfig id=\(recordingID, privacy: .public) queueDepth=\(config.queueDepth, privacy: .public) fps=60 pixelFormat=BGRA sourceRect=\(Self.logDescription(for: sourceRect), privacy: .public)")

      let stream = SCStream(filter: filter, configuration: config, delegate: bridge)
      try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: captureQueue)

      if isSystemAudioEnabled {
        try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: audioQueue)
      }

      self.writerSession = session
      self.streamBridge = bridge
      self.stream = stream
      self.lastOutputURL = url

      cursorSamples = []
      latestStreamScreenRect = nil
      inputEvents = []
      cursorSamplingTask?.cancel()
      cursorSamplingTask = nil
      cursorBaselineUptime = nil

      // Camera+mic share one AVCaptureSession (second session kills MovieFileOutput / sidecar).
      // Mic-only uses a separate session after the screen stream so it never contends with camera.
      if isCameraEnabled {
        do {
          try await ensureCameraAccess()
          try await prepareCameraForRecording(writerSession: session)
        } catch {
          cameraCapture = nil
          cameraOutputURL = nil
          let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
          reportLauncherPreflightIssue("カメラを開始できませんでした: \(message)")
          Self.captureLogger.error("cameraStartFailed id=\(recordingID, privacy: .public) error=\(message, privacy: .public)")
        }
      }

      try await stream.startCapture()
      let captureStartUptime = ProcessInfo.processInfo.systemUptime

      if isCameraEnabled, let camCap = cameraCapture, let camURL = cameraOutputURL {
        do {
          try camCap.beginSidecarRecording(to: camURL)
        } catch {
          let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
          Self.captureLogger.error("cameraSidecarStartFailed id=\(recordingID, privacy: .public) error=\(message, privacy: .public)")
        }
      }

      if isMicrophoneEnabled {
        let usesSharedCameraMic = cameraCapture?.includesMicrophoneInput == true
        if usesSharedCameraMic {
          mic = nil
        } else {
          try await ensureMicrophoneAccess()
          let microphone = MicrophoneCapture()
          microphone.onSampleBuffer = { [weak session] sample in
            session?.appendMicrophoneSample(sample)
          }
          try await microphone.start()
          self.mic = microphone
        }
      } else {
        mic = nil
      }

      state = .recording
      Self.captureLogger.info("streamStarted id=\(recordingID, privacy: .public)")
      startRecordingClock()

      if isCursorCaptureEnabled {
        cursorBaselineUptime = captureStartUptime
        startCursorSampling(source: source)
      }
      startInputEventRecording(source: source, startUptime: captureStartUptime)
    } catch {
      state = .failed
      let ns = error as NSError
      print("[RecordingCoordinator] startRecording failed: [\(ns.domain) \(ns.code)] \(ns.localizedDescription) \(ns.userInfo)")
      Self.captureLogger.error("startRecordingFailed id=\(recordingID, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) description=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
      lastErrorMessage = ScreenCaptureAccess.userFacingMessage(for: error)
      await teardownAfterFailure()
    }
  }

  func stopRecording() async {
    guard canStopRecording else { return }
    isBusy = true
    defer { isBusy = false }
    Self.captureLogger.info("stopRecordingRequested id=\(self.currentRecordingID ?? "none", privacy: .public) state=\(self.state.rawValue, privacy: .public)")
    await stopRecordingInternal(streamAlreadyStopped: false)
  }

  /// Stops and discards outputs so the recording does not become a project.
  func discardRecording() async {
    guard canStopRecording else { return }
    isSuppressingEditorFinalizeForDiscard = true
    defer { isSuppressingEditorFinalizeForDiscard = false }
    isBusy = true
    defer { isBusy = false }
    await stopRecordingInternal(streamAlreadyStopped: false)
    discardLastOutputFiles()
    state = .idle
    lastErrorMessage = nil
    terminalStreamError = nil
    currentRecordingID = nil
  }

  /// ランチャー上のエラー帯を閉じて再試行できるようにする。
  func clearLastErrorForLauncher() {
    lastErrorMessage = nil
    terminalStreamError = nil
    if state == .failed {
      state = .idle
    }
    reconcileInteractionStateForRecordUI()
  }

  /// 録画開始前のバリデーション用。`state` は変えず、ランチャー帯にだけ出す。
  func reportLauncherPreflightIssue(_ message: String) {
    lastErrorMessage = message
  }

  private func clearLauncherIssue(containing token: String) {
    guard lastErrorMessage?.contains(token) == true else { return }
    clearLastErrorForLauncher()
  }

  func tryAcquirePostStopFinalizeSlot() -> Bool {
    guard !postStopFinalizeSlotTaken else { return false }
    postStopFinalizeSlotTaken = true
    return true
  }

  func releasePostStopFinalizeSlot() {
    postStopFinalizeSlotTaken = false
  }

  func setFinalizingStoppedRecording(_ value: Bool) {
    isFinalizingStoppedRecording = value
  }

  private func handleStreamStopped(_ error: Error) async {
    guard state == .recording || state == .armed else { return }

    let ns = error as NSError
    print("[RecordingCoordinator] stream stopped unexpectedly: [\(ns.domain) \(ns.code)] \(ns.localizedDescription)\(ns.userInfo.isEmpty ? "" : " \(ns.userInfo)")")
    Self.captureLogger.error("streamStoppedUnexpectedly id=\(self.currentRecordingID ?? "none", privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) description=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
    terminalStreamError = error
    lastErrorMessage = ScreenCaptureAccess.userFacingMessage(for: error)
    await stopRecordingInternal(streamAlreadyStopped: true)
  }

  private func stopRecordingInternal(streamAlreadyStopped: Bool) async {
    let recordingID = currentRecordingID ?? "none"
    let stopStartedAt = CFAbsoluteTimeGetCurrent()
    Self.captureLogger.debug("stopRecordingInternalBegin id=\(recordingID, privacy: .public) streamAlreadyStopped=\(streamAlreadyStopped, privacy: .public) state=\(self.state.rawValue, privacy: .public)")
    stopRecordingClock(resetElapsed: false)
    cursorSamplingTask?.cancel()
    cursorSamplingTask = nil
    cursorBaselineUptime = nil
    stopInputEventRecording()

    mic?.stop()
    mic = nil

    let stream = self.stream
    self.stream = nil

    if let stream, !streamAlreadyStopped {
      do {
        try await stream.stopCapture()
      } catch {
        let ns = error as NSError
        Self.captureLogger.error("streamStopCaptureFailed id=\(recordingID, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) description=\(ns.localizedDescription, privacy: .public)")
        if lastErrorMessage == nil {
          lastErrorMessage = ScreenCaptureAccess.userFacingMessage(for: error)
        }
      }
    }

    streamBridge = nil

    let cameraForStop = cameraCapture
    let recordedURL = cameraForStop?.outputURL ?? cameraOutputURL
    let writerForFinish = writerSession
    cameraCapture = nil
    writerSession = nil
    cameraOutputURL = nil

    async let cameraFinishError: Error? = {
      guard let cameraForStop else { return nil }
      await cameraForStop.stopRecordingAsync()
      return cameraForStop.lastFinishError
    }()

    async let writerResult: RecordingWriterSession.FinishResult? = {
      guard let writerForFinish else { return nil }
      return await writerForFinish.finishWriting()
    }()

    let finishError = await cameraFinishError
    let result = await writerResult

    stageCameraAttachmentIfPossible(
      sourceURL: recordedURL,
      recordingID: recordingID,
      finishError: finishError
    )

    if let result {
      if let writerError = result.writerError {
        let ns = writerError as NSError
        Self.captureLogger.error("writerFinishCompleted id=\(recordingID, privacy: .public) success=\(result.success, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) description=\(ns.localizedDescription, privacy: .public)")
      } else {
        Self.captureLogger.info("writerFinishCompleted id=\(recordingID, privacy: .public) success=\(result.success, privacy: .public)")
      }
      if !result.success {
        if let output = lastOutputURL, FileManager.default.fileExists(atPath: output.path) {
          try? FileManager.default.removeItem(at: output)
        }
        lastOutputURL = nil
        if lastErrorMessage == nil {
          if let writerError = result.writerError {
            let ns = writerError as NSError
            lastErrorMessage = "AVAssetWriter エラー [\(ns.domain) \(ns.code)]: \(ns.localizedDescription)\(ns.userInfo.isEmpty ? "" : " \(ns.userInfo)")"
          } else {
            lastErrorMessage = RecordingCoordinatorUserCopy.finalizationWriteFailure
          }
        }
        state = .failed
      }
    }

    if let terminalStreamError {
      failRecordingAfterTerminalStreamError(terminalStreamError)
      return
    }

    if state != .failed {
      lastCompletedRecordingID = currentRecordingID
      isCameraPreviewStarting = false
      state = .finished
      Self.captureLogger.info("recordingFinished id=\(recordingID, privacy: .public)")
      currentRecordingID = nil
    }

  }

  private func failRecordingAfterTerminalStreamError(_ error: Error) {
    let recordingID = currentRecordingID ?? "none"
    let ns = error as NSError
    Self.captureLogger.error("recordingFailedAfterTerminalStreamError id=\(recordingID, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) description=\(ns.localizedDescription, privacy: .public)")
    if lastErrorMessage == nil {
      lastErrorMessage = ScreenCaptureAccess.userFacingMessage(for: error)
    }
    if let output = lastOutputURL, FileManager.default.fileExists(atPath: output.path) {
      try? FileManager.default.removeItem(at: output)
    }
    lastOutputURL = nil
    if let stagedCameraAttachmentURL, FileManager.default.fileExists(atPath: stagedCameraAttachmentURL.path) {
      try? FileManager.default.removeItem(at: stagedCameraAttachmentURL)
    }
    stagedCameraAttachmentURL = nil
    terminalStreamError = nil
    currentRecordingID = nil
    state = .failed
  }

  private func teardownAfterFailure() async {
    stopRecordingClock(resetElapsed: true)
    cursorSamplingTask?.cancel()
    cursorSamplingTask = nil
    cursorBaselineUptime = nil
    stopInputEventRecording()

    mic?.stop()
    mic = nil

    writerSession?.cancelImmediately()

    let stream = self.stream
    self.stream = nil
    streamBridge = nil

    if let stream {
      try? await stream.stopCapture()
    }

    writerSession = nil
    terminalStreamError = nil
    currentRecordingID = nil

    if let cameraCapture {
      let finishError = cameraCapture.lastFinishError
      let recordedURL = cameraCapture.outputURL ?? cameraOutputURL
      await cameraCapture.stopRecordingAsync()
      stageCameraAttachmentIfPossible(
        sourceURL: recordedURL,
        recordingID: currentRecordingID ?? "teardown",
        finishError: finishError
      )
    }
    cameraCapture = nil
    cameraOutputURL = nil
  }

  private func startRecordingClock() {
    stopRecordingClock(resetElapsed: true)
    recordingStartUptime = ProcessInfo.processInfo.systemUptime
    recordingClockTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let start = self.recordingStartUptime else { return }
        self.recordingElapsedSeconds = max(0, ProcessInfo.processInfo.systemUptime - start)
        try? await Task.sleep(nanoseconds: RecordingClock.tickNanoseconds)
      }
    }
  }

  private func stopRecordingClock(resetElapsed: Bool) {
    recordingClockTask?.cancel()
    recordingClockTask = nil
    recordingStartUptime = nil
    if resetElapsed {
      recordingElapsedSeconds = 0
    }
  }

  private func discardLastOutputFiles() {
    if let output = lastOutputURL, FileManager.default.fileExists(atPath: output.path) {
      try? FileManager.default.removeItem(at: output)
    }
    lastOutputURL = nil

    if let stagedCameraAttachmentURL, FileManager.default.fileExists(atPath: stagedCameraAttachmentURL.path) {
      try? FileManager.default.removeItem(at: stagedCameraAttachmentURL)
    }
    self.stagedCameraAttachmentURL = nil
    cursorSamples = []
    inputEvents = []
    recordingElapsedSeconds = 0
  }

  private func ensureMicrophoneAccess() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: { continuation.resume(returning: $0) })
      }
      guard granted else {
        throw RecordingError(message: "マイクへのアクセスが拒否されました。")
      }
    default:
      throw RecordingError(message: "マイクを使えません。「システム設定」→「プライバシーとセキュリティ」→「マイク」でこのアプリを許可してください。")
    }
  }

  private func ensureCameraAccess() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .video, completionHandler: { continuation.resume(returning: $0) })
      }
      guard granted else {
        throw RecordingError(message: "カメラへのアクセスが拒否されました。")
      }
    default:
      throw RecordingError(message: "カメラを使えません。「システム設定」→「プライバシーとセキュリティ」→「カメラ」でこのアプリを許可してください。")
    }
  }

  private static func requestMediaAccess(for mediaType: AVMediaType) async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: mediaType) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func makeTempRecordingURL(filePrefix: String = AppIdentifiers.TempFilePrefix.recording) throws -> URL {
    let base = FileManager.default.temporaryDirectory
    let file = "\(filePrefix)\(UUID().uuidString).mov"
    return base.appendingPathComponent(file)
  }

  private func stageCameraAttachmentIfPossible(
    sourceURL: URL?,
    recordingID: String,
    finishError: Error?
  ) {
    guard let sourceURL else {
      return
    }
    let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard FileManager.default.fileExists(atPath: sourceURL.path), fileSize > 512 else {
      return
    }
    pendingCameraAttachmentURL = sourceURL
    stagedCameraAttachmentURL = sourceURL
    cameraAttachmentPersistTask?.cancel()
    cameraAttachmentPersistTask = Task.detached(priority: .userInitiated) {
      try Self.persistCameraRecordingDetached(from: sourceURL, recordingID: recordingID)
    }
    _ = finishError
  }

  private enum CaptureVideoEncoding {
    // INVARIANT (docs/INVARIANTS.md §5): Retina window captures (~6MP) need proportionally higher
    // bitrate than flat 10 Mbps. Reference: 1080p @ 22 Mbps, clamp 18–80 Mbps.
    static let referencePixelCount: CGFloat = 1920 * 1080
    static let referenceBitrateMbps = 22
    static let minimumBitrateMbps = 18
    static let maximumBitrateMbps = 80

    static func bitrateMbps(for size: CGSize) -> Int {
      let pixels = max(1, size.width * size.height)
      let ratio = pixels / referencePixelCount
      let scaled = Double(referenceBitrateMbps) * Double(ratio)
      return min(maximumBitrateMbps, max(minimumBitrateMbps, Int(scaled.rounded())))
    }
  }

  private func makeVideoOutputSettings(size: CGSize) -> [String: Any] {
    let bitrateMbps = CaptureVideoEncoding.bitrateMbps(for: size)
    let bitsPerSecond = bitrateMbps * 1_000_000
    let w = Int(size.width) & ~1
    let h = Int(size.height) & ~1
    return [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: w,
      AVVideoHeightKey: h,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitsPerSecond,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
  }

  private func shouldRequireScreenRecordingPreflight(for source: CaptureSource) -> Bool {
    switch source {
    case .systemPickerSelection:
      return false
    }
  }

  private func makeFilterAndSize(for source: CaptureSource) async throws -> (SCContentFilter, CGSize, CGRect?) {
    switch source {
    case .systemPickerSelection(let selection):
      let scale = CGFloat(max(selection.pointPixelScale, 1))
      let rect = selection.contentRect
      let size = CGSize(
        width: max(2, rect.width * scale),
        height: max(2, rect.height * scale)
      )
      return (selection.filter, size, nil)
    }
  }

  private static func logDescription(for source: CaptureSource) -> String {
    switch source {
    case .systemPickerSelection(let selection):
      return "systemPickerSelection style=\(selection.style.rawValue) id=\(selection.id) rect=\(logDescription(for: selection.contentRect)) scale=\(selection.pointPixelScale)"
    }
  }

  private static func logDescription(for rect: CGRect?) -> String {
    guard let rect else { return "none" }
    return logDescription(for: rect)
  }

  private static func logDescription(for rect: CGRect) -> String {
    let x = Int(rect.origin.x.rounded())
    let y = Int(rect.origin.y.rounded())
    let w = Int(rect.width.rounded())
    let h = Int(rect.height.rounded())
    return "x=\(x),y=\(y),w=\(w),h=\(h)"
  }

  private func startCursorSampling(source: CaptureSource) {
    cursorSamplingTask?.cancel()
    cursorSamplingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      guard let baseline = self.cursorBaselineUptime else { return }

      while !Task.isCancelled, self.state == .recording {
        if let sample = self.makeCursorSample(source: source, baselineUptime: baseline) {
          self.cursorSamples.append(sample)
          Self.enforceCursorSampleCap(&self.cursorSamples)
        }
        try? await Task.sleep(nanoseconds: 16_666_667) // ~60 Hz
      }
    }
  }

  private func startInputEventRecording(source: CaptureSource, startUptime: TimeInterval) {
    inputEventRecorder?.stop()
    inputEventRecorder = nil
    guard let rect = Self.captureRect(for: source) else { return }
    let recorder = InputEventRecorder(captureRect: rect)
    recorder.start(startUptime: startUptime)
    inputEventRecorder = recorder
  }

  private func stopInputEventRecording() {
    guard let recorder = inputEventRecorder else { return }
    recorder.stop()
    inputEvents = recorder.takeEvents()
    inputEventRecorder = nil
  }

  private func makeCursorSample(source: CaptureSource, baselineUptime: TimeInterval) -> RecordingProject.CursorSample? {
    let now = ProcessInfo.processInfo.systemUptime
    let t = max(0, now - baselineUptime)

    guard let rect = cursorMappingRect(for: source) else { return nil }
    guard rect.width > 1, rect.height > 1 else { return nil }

    let cgGlobal = Self.cgGlobalMouseLocation()
    guard let normalized = Self.normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: cgGlobal,
      contentRect: rect
    ) else { return nil }

    let shape = Self.classifyCursorShape(NSCursor.currentSystem)

    return RecordingProject.CursorSample(
      timeSeconds: t,
      x: normalized.x,
      y: normalized.y,
      shape: shape
    )
  }

  /// Maps mouse position to normalized video coordinates.
  ///
  /// INVARIANT (docs/INVARIANTS.md §1 — **critical**):
  /// Prefer `SCStreamFrameInfo.screenRect` (global on-screen bounds) over
  /// `SCContentFilter.contentRect` when they differ. Window picks often report filter minY
  /// ~33pt above screenRect (title-bar inset). Using filter rect alone shifts cursor upward
  /// in preview/export. Never use stream buffer-local (0,0,w,h) as mapping rect.
  ///
  /// Unit tests: `RecordingCoordinator.cursorMappingRect(filterContentRect:streamScreenRect:)`
  private func cursorMappingRect(for source: CaptureSource) -> CGRect? {
    switch source {
    case .systemPickerSelection(let selection):
      return latestStreamScreenRect ?? selection.contentRect
    }
  }

  nonisolated static func cursorMappingRect(
    filterContentRect: CGRect,
    streamScreenRect: CGRect?
  ) -> CGRect {
    streamScreenRect ?? filterContentRect
  }

  private func handleStreamFrameMetadata(_ metadata: ScreenStreamFrameMetadata, source _: CaptureSource) {
    latestStreamScreenRect = metadata.screenRect
  }

  nonisolated static func cgDisplayMainHeight(fallback: CGFloat) -> CGFloat {
    let height = CGDisplayBounds(CGMainDisplayID()).height
    return height > 1 ? height : fallback
  }

  nonisolated static func cgGlobalMouseLocation(fromAppKitFallback appKit: CGPoint? = nil) -> CGPoint {
    if let location = CGEvent(source: nil)?.location {
      return location
    }
    let appKitPoint = appKit ?? NSEvent.mouseLocation
    let mainHeight = cgDisplayMainHeight(fallback: appKitPoint.y)
    return CGPoint(x: appKitPoint.x, y: mainHeight - appKitPoint.y)
  }

  nonisolated static func normalizedCursorPositionInContentRect(
    cgGlobalMouseLocation: CGPoint,
    contentRect: CGRect
  ) -> (x: Double, y: Double)? {
    guard contentRect.width > 1, contentRect.height > 1 else { return nil }
    let x = (cgGlobalMouseLocation.x - contentRect.minX) / contentRect.width
    let yFromTop = (cgGlobalMouseLocation.y - contentRect.minY) / contentRect.height
    // 保存 y は下原点（y=1 が上端）＝プレビュー／書き出しの規約。
    let y = 1 - yFromTop
    return (
      max(0, min(1, Double(x))),
      max(0, min(1, Double(y)))
    )
  }

  nonisolated static func primaryScreenHeight(fallback: CGFloat) -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height
      ?? fallback
  }

  nonisolated static func normalizedCursorPositionInContentRect(
    globalMouseLocation: CGPoint,
    contentRect: CGRect,
    primaryScreenHeight: CGFloat
  ) -> (x: Double, y: Double)? {
    let cgMouseY = primaryScreenHeight - globalMouseLocation.y
    return normalizedCursorPositionInContentRect(
      cgGlobalMouseLocation: CGPoint(x: globalMouseLocation.x, y: cgMouseY),
      contentRect: contentRect
    )
  }

  private static func classifyCursorShape(_ cursor: NSCursor?) -> RecordingProject.CursorShape {
    guard let cursor else { return .arrow }
    switch cursor {
    case NSCursor.arrow: return .arrow
    case NSCursor.iBeam: return .iBeam
    case NSCursor.pointingHand: return .pointingHand
    case NSCursor.crosshair: return .crosshair
    case NSCursor.resizeLeftRight: return .resizeLeftRight
    case NSCursor.resizeUpDown: return .resizeUpDown
    case NSCursor.openHand: return .openHand
    case NSCursor.closedHand: return .closedHand
    case NSCursor.operationNotAllowed: return .operationNotAllowed
    default: return .unknown
    }
  }

  private static func captureRect(for source: CaptureSource) -> CGRect? {
    switch source {
    case .systemPickerSelection(let selection):
      return selection.contentRect
    }
  }

  private enum CursorSampleCap {
    /// ~20 minutes at 60 Hz — keeps project JSON reasonable.
    static let maxCount: Int = 72_000
  }

  private static func enforceCursorSampleCap(_ samples: inout [RecordingProject.CursorSample]) {
    guard samples.count > CursorSampleCap.maxCount else { return }
    let step = max(1, (samples.count + CursorSampleCap.maxCount - 1) / CursorSampleCap.maxCount)
    guard step > 1 else { return }
    var thinned: [RecordingProject.CursorSample] = []
    thinned.reserveCapacity(CursorSampleCap.maxCount)
    var i = 0
    while i < samples.count, thinned.count < CursorSampleCap.maxCount {
      thinned.append(samples[i])
      i += step
    }
    if let last = samples.last, thinned.last?.timeSeconds != last.timeSeconds {
      thinned.append(last)
    }
    samples = thinned
  }

}
