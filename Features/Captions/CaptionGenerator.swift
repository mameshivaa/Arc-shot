@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

struct CaptionGenerationResult: Sendable {
  var overlays: [RecordingProject.TextOverlayAnnotation]
  var transcript: String
}

protocol CaptionEngine: Sendable {
  func generate(url: URL, localeIdentifier: String) async throws -> CaptionGenerationResult
}

@MainActor
@Observable
final class CaptionGenerator {
  typealias CaptionResult = CaptionGenerationResult

  enum State: Equatable {
    case idle
    case generating
    case finished
    case failed(String)
  }

  private enum CaptionDefaults {
    static let minCaptionDurationSeconds: Double = 0.25
    static let maxTranscriptLength = 20_000

    @MainActor
    static var defaultLocaleIdentifier: String {
      ArcShotRuntime.shared.languageStore.language == .japanese ? "ja-JP" : "en-US"
    }
  }

  private(set) var state: State = .idle
  var transcript: String = ""

  private let engine: CaptionEngine

  init(engine: CaptionEngine = AppleSpeechCaptionEngine()) {
    self.engine = engine
  }

  func generateFromMedia(url: URL) async -> CaptionResult? {
    state = .generating
    transcript = ""

    do {
      let result = try await engine.generate(url: url, localeIdentifier: CaptionDefaults.defaultLocaleIdentifier)
      self.transcript = String(result.transcript.prefix(CaptionDefaults.maxTranscriptLength))
      state = .finished
      return CaptionResult(
        overlays: RecordingProject.TextOverlaySanitizeDefaults.sanitized(result.overlays, durationSeconds: .greatestFiniteMagnitude),
        transcript: self.transcript
      )
    } catch {
      let message = ArcShotRuntime.shared.languageStore.localizedFormat(
        "Caption generation failed: %@",
        error.localizedDescription
      )
      state = .failed(message)
      return nil
    }
  }
}

struct AppleSpeechCaptionEngine: CaptionEngine {
  private enum Defaults {
    static let minCaptionDurationSeconds: Double = 0.25
    static let maxTranscriptLength = 20_000
  }

  func generate(url: URL, localeIdentifier: String) async throws -> CaptionGenerationResult {
    guard await hasAudioTrack(url: url) else {
      throw CaptionEngineError.noAudioTrack
    }

    let speechStatus = await requestSpeechAuthorizationIfNeeded()
    guard speechStatus == .authorized else {
      throw CaptionEngineError.notAuthorized
    }

    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
      ?? SFSpeechRecognizer() else {
      throw CaptionEngineError.recognizerUnavailable
    }

    let result = try await recognize(url: url, recognizer: recognizer)
    let transcript = String(result.bestTranscription.formattedString.prefix(Defaults.maxTranscriptLength))
    let overlays = result.bestTranscription.segments.map { segment in
      let start = max(0, segment.timestamp)
      let end = max(start + Defaults.minCaptionDurationSeconds, start + segment.duration)
      return RecordingProject.TextOverlayAnnotation(
        startSeconds: start,
        endSeconds: end,
        text: segment.substring
      )
    }
    return CaptionGenerationResult(overlays: overlays, transcript: transcript)
  }

  private func hasAudioTrack(url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    do {
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      return !tracks.isEmpty
    } catch {
      return false
    }
  }

  private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = SFSpeechRecognizer.authorizationStatus()
    if current != .notDetermined { return current }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }

  private func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> SFSpeechRecognitionResult {
    try await withCheckedThrowingContinuation { continuation in
      let request = SFSpeechURLRecognitionRequest(url: url)
      request.shouldReportPartialResults = false
      request.requiresOnDeviceRecognition = true
      request.addsPunctuation = true

      var task: SFSpeechRecognitionTask?
      task = recognizer.recognitionTask(with: request) { result, error in
        if let error {
          task?.cancel()
          continuation.resume(throwing: error)
          return
        }
        guard let result, result.isFinal else { return }
        task?.cancel()
        continuation.resume(returning: result)
      }
    }
  }
}

enum CaptionEngineError: LocalizedError {
  case noAudioTrack
  case notAuthorized
  case recognizerUnavailable

  var errorDescription: String? {
    switch self {
    case .noAudioTrack:
      return "音声トラックが見つからないため字幕を生成できません。"
    case .notAuthorized:
      return "音声認識の権限が許可されていません。システム設定で許可してください。"
    case .recognizerUnavailable:
      return "音声認識エンジンを初期化できませんでした。"
    }
  }
}
